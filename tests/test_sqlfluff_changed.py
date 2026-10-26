import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("sqlfluff_changed", Path(__file__).resolve().parents[1] / "lib/sqlfluff_changed.py")
m = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = m
SPEC.loader.exec_module(m)

SCRIPT = """CREATE TABLE `T` (
  `Id` INT
);

DELIMITER ;;
DROP PROCEDURE IF EXISTS `P`;;
CREATE PROCEDURE `P`()
BEGIN
  SELECT 1;
  SELECT 2;
END;;
DELIMITER ;

-- trailing comment;
INSERT INTO `T` VALUES (1);
"""


class SplitTests(unittest.TestCase):
    def test_units_follow_delimiters_and_keep_original_lines(self):
        units = m.split_units(SCRIPT)
        self.assertEqual([(u.start, u.end) for u in units], [(1, 3), (6, 6), (7, 11), (14, 15)])
        self.assertEqual(units[1].lines, ["DROP PROCEDURE IF EXISTS `P`;"])
        self.assertEqual(units[2].lines[-1], "END;")
        self.assertIn("  SELECT 1;", units[2].lines)

    def test_comment_ending_with_delimiter_does_not_close_a_statement(self):
        unit = m.split_units(SCRIPT)[3]
        self.assertEqual(unit.lines, ["-- trailing comment;", "INSERT INTO `T` VALUES (1);"])

    def test_comment_before_delimiter_does_not_hide_the_delimiter_change(self):
        units = m.split_units("-- routines\nDELIMITER ;;\nCREATE PROCEDURE `Q`()\nBEGIN\n  SELECT 1;\nEND;;\n")
        self.assertEqual([(u.start, u.end) for u in units], [(3, 6)])
        self.assertEqual(units[0].lines[-1], "END;")

    def test_touched_units_select_statements_with_added_lines(self):
        units = m.split_units(SCRIPT)
        self.assertEqual([u.start for u in m.touched_units(units, {9, 15})], [7, 14])
        self.assertEqual(m.touched_units(units, {4, 12}), [])


class DiffTests(unittest.TestCase):
    def test_added_lines_from_zero_context_hunks(self):
        diff = "\n".join([
            "diff --git a/x.sql b/x.sql",
            "@@ -3 +3 @@",
            "@@ -10,0 +11,2 @@",
            "@@ -20,4 +23,0 @@",
            "@@ -30,2 +30,3 @@",
        ])
        self.assertEqual(m.added_lines(diff), {3, 11, 12, 30, 31, 32})


class LintTests(unittest.TestCase):
    def fake_sqlfluff(self, directory: str, violations: dict) -> str:
        """An executable that prints a SQLFluff JSON report for each unit file it is given."""
        path = os.path.join(directory, "sqlfluff")
        Path(path).write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            f"violations = {json.dumps(violations)!r}\n"
            "violations = json.loads(violations)\n"
            "target = sys.argv[-1]\n"
            "assert target == '.' and os.path.isfile('.sqlfluff')\n"
            "out = [{'filepath': name, 'violations': violations.get(name, [])}\n"
            "       for name in sorted(os.listdir(target)) if name.endswith('.sql')]\n"
            "print(json.dumps(out))\n"
            "sys.exit(1 if any(o['violations'] for o in out) else 0)\n",
            encoding="utf-8",
        )
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        return path

    def test_only_added_lines_report_rules_and_parse_errors_cover_the_statement(self):
        units = m.touched_units(m.split_units(SCRIPT), {9})
        with tempfile.TemporaryDirectory() as tmp:
            fake = self.fake_sqlfluff(tmp, {"unit_00000.sql": [
                {"start_line_no": 3, "code": "LT01", "description": "added line"},
                {"start_line_no": 4, "code": "CP01", "description": "untouched line"},
                {"start_line_no": 1, "code": "PRS", "description": "unparsable"},
            ]})
            findings, skipped = m.lint_units(fake, "mariadb", None, "x.sql", units, {9})
        self.assertEqual(skipped, 0)
        self.assertEqual([(f.line, f.code, f.blocking) for f in findings], [(9, "LT01", True), (7, "PRS", False)])

    def test_annotation_level_follows_blocking_and_parse_errors_stay_warnings(self):
        rule = m.Finding("x.sql", 9, "LT01", "bad\nspacing")
        parse = m.Finding("x.sql", 7, "PRS", "unparsable")
        self.assertEqual(m.annotate(rule, True), "::error file=x.sql,line=9,title=SQLFluff LT01::bad%0Aspacing")
        self.assertTrue(m.annotate(rule, False).startswith("::warning "))
        self.assertTrue(m.annotate(parse, True).startswith("::warning "))

    def test_oversized_statement_is_skipped(self):
        unit = m.Unit(1, ["SELECT '" + "x" * m.MAX_UNIT_BYTES + "';"])
        with tempfile.TemporaryDirectory() as tmp:
            fake = self.fake_sqlfluff(tmp, {})
            findings, skipped = m.lint_units(fake, "mariadb", None, "x.sql", [unit], {1})
        self.assertEqual((findings, skipped), ([], 1))


if __name__ == "__main__":
    unittest.main()
