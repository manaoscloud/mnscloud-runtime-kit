#!/usr/bin/env python3
"""Lint only the SQL a pull request adds, with SQLFluff.

Used by .github/workflows/security-scan.yml. A canonical schema file can be several megabytes,
far beyond what SQLFluff parses in reasonable time, and most of it predates any lint rule. So:

1. find the lines each changed .sql file adds against the base commit (git diff -U0);
2. split the file into statements, honouring DELIMITER changes (stored routines use `;;`);
3. lint only the statements that contain an added line, each as its own small file;
4. report violations on added lines only, mapped back to the original file and line.

Lint violations fail the gate when --blocking is set. A statement SQLFluff cannot parse is reported
as a warning and never fails: the MariaDB dialect has gaps, and the repository's own tests apply the
schema to a real server, which is the authority on syntax.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass

DELIMITER_RE = re.compile(r"^\s*DELIMITER\s+(\S+)\s*$", re.IGNORECASE)
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
PARSE_CODES = {"PRS", "TMP"}
COMMIT_RE = re.compile(r"^[0-9a-f]{7,64}$")
CONFIG_NAME = ".sqlfluff"
# A single statement larger than this is reported as skipped instead of risking a parser lock.
MAX_UNIT_BYTES = 200_000


@dataclass
class Unit:
    start: int  # first line (1-based) of the statement in the original file
    lines: list[str]

    @property
    def end(self) -> int:
        return self.start + len(self.lines) - 1


@dataclass
class Finding:
    path: str
    line: int
    code: str
    message: str

    @property
    def blocking(self) -> bool:
        return self.code not in PARSE_CODES


def commit(value: str) -> str:
    """The base commit as a full or abbreviated SHA, so it can never be read as a git option."""
    if not COMMIT_RE.match(value):
        raise argparse.ArgumentTypeError(f"not a commit SHA: {value!r}")
    return value


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def changed_files(base: str) -> list[str]:
    out = git("diff", "--name-only", "--diff-filter=ACMR", commit(base), "HEAD", "--", "*.sql")
    return [line for line in out.splitlines() if line]


def added_lines(diff: str) -> set[int]:
    """Line numbers (new side) added by a unified diff produced with -U0."""
    lines: set[int] = set()
    for row in diff.splitlines():
        match = HUNK_RE.match(row)
        if match:
            start = int(match.group(1))
            count = int(match.group(2)) if match.group(2) is not None else 1
            lines.update(range(start, start + count))
    return lines


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("--")


def closes(line: str, delimiter: str) -> bool:
    stripped = line.rstrip()
    return stripped.endswith(delimiter) and not is_comment(stripped)


def statement(start: int, lines: list[str], delimiter: str) -> Unit:
    """A finished statement whose closing delimiter is rewritten to `;`."""
    if delimiter != ";":
        lines[-1] = lines[-1].rstrip()[: -len(delimiter)] + ";"
    return Unit(start, lines)


def split_units(text: str) -> list[Unit]:
    """Statements of a SQL script, each ending with its delimiter, rewritten to end with `;`."""
    units: list[Unit] = []
    delimiter = ";"
    current: list[str] = []
    start = 0
    for number, line in enumerate(text.splitlines(), start=1):
        match = DELIMITER_RE.match(line)
        if match:
            # Only comments can precede a DELIMITER line; they belong to no statement.
            if any(row.strip() and not is_comment(row) for row in current):
                units.append(Unit(start, current))
            current, delimiter = [], match.group(1)
        elif current or line.strip():
            if not current:
                start = number
            current.append(line)
            if closes(line, delimiter):
                units.append(statement(start, current, delimiter))
                current = []
    if current:
        units.append(Unit(start, current))
    return units


def touched_units(units: list[Unit], added: set[int]) -> list[Unit]:
    return [unit for unit in units if any(unit.start <= line <= unit.end for line in added)]


def write_units(directory: str, path: str, units: list[Unit]) -> tuple[dict[str, Unit], int]:
    """Write each statement to its own file; statements over the size cap are skipped."""
    index: dict[str, Unit] = {}
    skipped = 0
    for number, unit in enumerate(units):
        body = "\n".join(unit.lines) + "\n"
        if len(body.encode()) > MAX_UNIT_BYTES:
            skipped += 1
            print(f"::warning file={path},line={unit.start}::SQLFluff skipped a statement over "
                  f"{MAX_UNIT_BYTES} bytes")
            continue
        name = f"unit_{number:05d}.sql"
        Path(directory, name).write_text(body, encoding="utf-8")
        index[name] = unit
    # SQLFluff reads the config of the directory it runs in; the caller's config is layered on top.
    Path(directory, CONFIG_NAME).write_text(
        f"[sqlfluff]\nlarge_file_skip_byte_limit = {MAX_UNIT_BYTES}\n", encoding="utf-8")
    return index, skipped


def run_sqlfluff(sqlfluff: str, dialect: str, config: str | None, directory: str) -> list[dict]:
    command = [sqlfluff, "lint", "--dialect", dialect, "--format", "json", "--nofail",
               "--disable-progress-bar", "--processes", "-1"]
    if config:
        command += ["--config", os.path.abspath(config)]
    result = subprocess.run([*command, "."], capture_output=True, text=True, cwd=directory)
    if result.returncode not in (0, 1):
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"sqlfluff exited with {result.returncode}")
    return json.loads(result.stdout or "[]")


def lint_units(sqlfluff: str, dialect: str, config: str | None, path: str, units: list[Unit],
               added: set[int]) -> tuple[list[Finding], int]:
    findings: list[Finding] = []
    with tempfile.TemporaryDirectory(prefix="sqlfluff-units-") as tmp:
        index, skipped = write_units(tmp, path, units)
        reports = run_sqlfluff(sqlfluff, dialect, config, tmp) if index else []
    for report in reports:
        unit = index.get(os.path.basename(report["filepath"]))
        for violation in report.get("violations", []) if unit else []:
            line = unit.start + int(violation.get("start_line_no", 1)) - 1
            code = violation.get("code", "")
            # A parse error belongs to the whole statement; a lint rule only to its own line.
            if code in PARSE_CODES or line in added:
                findings.append(Finding(path, line, code, violation.get("description", "")))
    return findings, skipped


def annotate(finding: Finding, blocking: bool) -> str:
    level = "error" if blocking and finding.blocking else "warning"
    message = finding.message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return f"::{level} file={finding.path},line={finding.line},title=SQLFluff {finding.code}::{message}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, type=commit, help="base commit SHA of the pull request")
    parser.add_argument("--dialect", required=True)
    parser.add_argument("--sqlfluff", default="sqlfluff", help="sqlfluff executable")
    parser.add_argument("--config", help=f"SQLFluff config file (default: {CONFIG_NAME} when present)")
    parser.add_argument("--blocking", action="store_true", help="exit 1 on lint violations")
    args = parser.parse_args(argv)

    config = args.config or (CONFIG_NAME if Path(CONFIG_NAME).is_file() else None)
    files = changed_files(args.base)
    if not files:
        print("No SQL file changed.")
        return 0
    findings: list[Finding] = []
    statements = 0
    for path in files:
        added = added_lines(git("diff", "-U0", commit(args.base), "HEAD", "--", path))
        if not added:
            continue
        units = touched_units(split_units(Path(path).read_text(encoding="utf-8")), added)
        statements += len(units)
        file_findings, _ = lint_units(args.sqlfluff, args.dialect, config, path, units, added)
        findings += file_findings
    for finding in sorted(findings, key=lambda f: (f.path, f.line, f.code)):
        print(annotate(finding, args.blocking))
    lint = sum(1 for f in findings if f.blocking)
    parse = len(findings) - lint
    print(f"SQLFluff: {statements} changed statement(s) in {len(files)} file(s); "
          f"{lint} violation(s) on added lines, {parse} unparsable statement report(s)")
    if lint and args.blocking:
        return 1
    if lint:
        print("::warning::SQLFluff reported findings (not blocking for this repository)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
