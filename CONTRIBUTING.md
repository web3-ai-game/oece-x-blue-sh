# Contributing

Issues and pull requests are welcome. Write explanations in Traditional Chinese or English. Keep code comments in the language already used next to the change.

## Before you open a PR

```bash
bash -n oece-x-blue.sh
shellcheck -S warning oece-x-blue.sh
```

Both must pass with zero warnings.

## Out of scope

Pull requests that add telemetry, sample upload, proxy features, or network-circumvention features will be closed.

Do not commit hostnames, public IPs, cloud resource IDs, real account names, private email addresses, or deployment paths. Use `deploy` for example accounts and RFC 5737 ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) for example addresses.

## Design constraints

- Stay a single Bash file. The short-link install path ships one file.
- SSH and firewall changes go through preflight and an auto-rollback timer.
- `SKIP` checks stay out of the score denominator.
- CrowdSec community sharing stays off unless the operator opts in.
