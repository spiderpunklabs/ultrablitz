# Secrets Runbook

What to do when gitleaks (or any other scanner) detects a credential in this repo.

## Triage (under 5 minutes)

1. **Confirm it's a real secret** (not a placeholder or example). If unsure, treat as real.
2. **Identify the credential type** from the matched pattern.
3. **Estimate exposure window**: when did the commit land vs when was the leak detected?

## Rotate

| Credential type | Rotation steps |
|---|---|
| GitHub PAT / fine-grained token | https://github.com/settings/tokens → revoke → generate new → update Keychain entry |
| GitHub App private key | App settings → Private keys → regenerate → distribute |
| SSH private key | Generate a new ed25519 key → update `~/.ssh/config` + GitHub/GitLab/etc → delete old |
| AWS access key | IAM console → deactivate exposed key → create replacement → update `~/.aws/credentials` → delete after grace |
| GCP service account key | gcloud iam service-accounts keys delete → create new → distribute |
| Anthropic API key | https://console.anthropic.com/settings/keys → revoke → create new |
| OpenAI API key | https://platform.openai.com/api-keys → revoke → create new |
| Generic bearer tokens | Vendor console; treat as compromised once committed |

## Purge

> **Default is rotate, not rewrite.** History rewrites break clones and can cause more damage than the leak itself.

Full playbook in [`spiderpunklabs/workstation/ci-templates/SECRETS_RUNBOOK.md`](https://github.com/spiderpunklabs/workstation/blob/main/ci-templates/SECRETS_RUNBOOK.md).

## Document

After resolution, add an entry to `.gitleaks.toml` allowlist if the finding will recur as a known false positive. Each entry MUST include a `description`.

## Don't

- Don't bypass gitleaks failures without rotating first.
- Don't delete and re-commit the file as a "fix" — the secret is in the history.
- Don't assume short exposure = safe; bots scrape new public commits within seconds.
