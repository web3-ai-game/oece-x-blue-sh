# Security policy

## Supported versions

| Version | Supported |
|:--------|:----------|
| 2.0.x   | yes       |
| < 2.0   | no        |

## Reporting a vulnerability

Use [GitHub Security Advisories](https://github.com/web3-ai-game/oece-x-blue-sh/security/advisories/new).

Do not open a public issue with logs, hostnames, IP addresses, tokens, or `blue.env` contents. Redact those before you write anything down.

## What this tool is

`oece-x-blue.sh` runs as root. It can change sshd, the firewall, fail2ban, PAM, and cron. A mistaken run on a production host can interrupt SSH or published services inside the rollback window. Preflight and the auto-rollback timer reduce that risk. They do not remove it.

## What this tool is not

- It does not upload honeypot captures.
- It does not enable CrowdSec community sharing unless the operator types yes.
- It does not look up login geography unless `LOGIN_GEO_LOOKUP=1`.
- It does not include proxy or network-circumvention features.
- It does not store alert credentials in git. Those stay in `/etc/oece-x/blue.env` with mode 0600.

## Install trust

The `curl | bash` one-liner is a convenience entry. It is not checksum-verified. For a host you care about, download the file, check a SHA256 you trust, then run it.
