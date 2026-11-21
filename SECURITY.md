# Security Policy

## Supported versions

Only the latest release receives security fixes. Pre-1.0 versions are supported on a best-effort basis.

| Version | Supported |
|---|---|
| 0.1.x (latest) | ✅ |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private reporting channel: **Security** tab → **Report a vulnerability**
(<https://github.com/OWNER/REPO/security/advisories/new>).

If that is unavailable, email **MAINTAINER_EMAIL** with:

- a description of the issue and its impact,
- steps to reproduce (version, OS, config),
- any proof-of-concept, ideally without real audio or personal data.

You can expect an initial reply within **7 days**. Once the issue is confirmed we will publish a patched release and credit you in the advisory, unless you prefer to stay anonymous.

## Scope

Areas we care about most:

- **API key storage** — keys are stored in the local SQLite database / config file and must never be transmitted anywhere except the endpoint you configured.
- **LAN sync** — device discovery, pairing codes, and the transfer endpoint (an unpaired or spoofed peer must not be able to read or overwrite data).
- **File import** — path traversal or code execution via crafted audio/video file names or metadata.
- **A2A client** — handling of responses from a malicious local agent (no arbitrary command execution, no SSRF to arbitrary hosts).
- **Model serving** — unsafe deserialization of model files or engine binaries.

## Out of scope

- Attacks that require an already-compromised machine or physical access.
- The user pointing the app at a malicious LLM endpoint on purpose.
- Third-party models' accuracy or content (transcripts are not security-relevant).
- Missing code signing on development builds.

## Our commitments

- No telemetry, no analytics, no remote logging — this is a design constraint, not a setting.
- Dependency updates for security fixes are released as patch versions.
