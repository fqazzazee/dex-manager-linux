# Security policy — dex-manager-linux

## Supported versions

Only the current `main` branch gets security fixes.

## Reporting a vulnerability

Do not open a public issue.

Use [private vulnerability reporting](https://github.com/fqazzazee/dex-manager-linux/security/advisories/new),
or email fadi.qazzazee@gmail.com with the details and, if you have one, a proof of
concept.

Expect an acknowledgment within 72 hours and an assessment within a week. If a fix is
warranted, you will get the timeline and credit in the release notes unless you would
rather not be named.

## Scope

**In scope:** the scripts in this repository and their default configuration. Command
injection, unsafe temporary files, and, where a script runs anything as root, a way for
an unprivileged user to influence what runs are worth reporting.

**Out of scope:** vulnerabilities in the upstream tools these scripts install or call,
and anything that requires an attacker to already have the privileges the issue would
grant.
