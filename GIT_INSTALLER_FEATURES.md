# Git Installer: Add-ons and Possible Future Features

## Recommended safe routes included now
- Restricts installer execution to a configurable root directory (`ALLOWED_ROOT`) with an explicit override token.
- Scans `install.sh` for risky patterns and requires a second explicit confirmation token before execution.
- Previews the beginning of each installer script before prompting to run.
- Creates preflight backups of shell profiles and `.env` files before any installation.
- Supports dry-run mode for previewing actions safely.

## Add-ons you can add next
- **Repo allowlist/denylist file** (e.g., `allowed_repos.txt`) to auto-approve known sources.
- **Signature verification** (GPG or Sigstore/cosign) before cloning or running installers.
- **Installer sandboxing** with Docker/Podman for untrusted repos.
- **Per-repo policy file** (`.installer-policy.yml`) for required checks and approved commands.
- **Automatic rollback hooks** that snapshot directories and restore on failure.
- **Parallel processing** for dependency installation with controlled concurrency.
- **SBOM generation** (Syft) and vulnerability scanning (Grype/Trivy) before and after install.
- **Secret scanning** (Gitleaks/TruffleHog) on cloned repos before execution.
- **Structured audit logging** to JSON Lines and optional SIEM forwarding.
- **Notification hooks** (Slack/Discord/email) on success/failure.

## Quality-of-life enhancements
- Add `--non-interactive` mode for CI pipelines with strict defaults.
- Add `--update-existing` / `--skip-existing` behaviors as flags.
- Add automatic support for `pnpm`, `yarn`, `uv`, `poetry`, and `pip-tools`.
- Add repository install matrix config via YAML/JSON input.
- Add timeout and retry controls per stage (clone, deps, installer run).

## Hardening recommendations
- Run with a dedicated low-privilege user account.
- Keep `sudo` disabled by policy unless explicitly whitelisted.
- Require lockfiles (`package-lock.json`, `poetry.lock`, etc.) for reproducible installs.
- Pin dependency indexes/mirrors to trusted registries.
- Preserve immutable logs and checksums for incident review.
