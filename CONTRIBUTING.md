# Contributing

Thank you for helping improve MNSCloud runtime automation.

## Flow

- Work through Pull Requests.
- Keep changes focused and documented.
- Include validation output in the Pull Request.
- Maintainer review is required before merge.

## Security Boundary

Do not add permanent secrets, customer data, production domains, private IP topology, provider
credentials, database credentials, or product business rules.

This repository installs common runtimes only. Service configuration belongs in the consuming module.

## Validation

```bash
bash -n scripts/*.sh lib/*.sh installers/*.sh
```

## Paid Work

Opening a Pull Request does not create a payment obligation. Paid work requires explicit written
agreement before it is considered billable.

