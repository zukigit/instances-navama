# instances-navama

Terraform for cloud instances. This repo is pushed to GitHub (`zukigit/instances-navama`), so treat everything committed as public.

## Rule: no private data in git

Before every `git commit` and `git push`, check the staged changes (`git diff --cached`) and the files being added for private data. If you find any, stop and tell the user instead of committing.

Never commit:

- **GCP identifiers:** real project IDs, project numbers, service account emails (`<number>-compute@developer.gserviceaccount.com`), instance IPs. Use variables with no default, set in `terraform.tfvars`, and placeholders in `terraform.tfvars.example`.
- **Credentials:** service account JSON keys, API keys, tokens, passwords, SSH private keys, `.pem`/`.key` files. SSH public keys stay out too; reference them by path (`ssh_public_key_path`), never inline.
- **Outline secrets:** `apiUrl`, `certSha256`, `access.txt`, access keys (`ss://...`). Anyone with the `apiUrl` controls the server.
- **Terraform local files:** `terraform.tfvars`, `*.auto.tfvars`, `*.tfstate*`, saved plans (`tfplan`), apply logs (`*.log`). State and logs contain IPs and variable values.
- **Personal data:** email addresses, real names, home paths (`/home/<user>`).

Quick scan before committing:

```bash
git diff --cached | grep -nE 'project-[a-z0-9]{6,}|[0-9]{12}-compute|@[a-z0-9.-]+\.(com|me|net|org)|BEGIN [A-Z ]*PRIVATE KEY|ssh-(ed25519|rsa) AAAA|AIza[0-9A-Za-z_-]{20,}|"private_key"|apiUrl.*https|certSha256:[0-9A-F]|ss://'
git diff --cached --name-only | grep -E 'tfstate|\.tfvars$|tfplan|\.log$|\.pem$|\.key$|id_|credentials|access\.txt'
```

Both should print nothing (mentions of the words `apiUrl`/`certSha256` in docs are fine; real values are not).

When adding a new local-only file type (keys, logs, generated configs), add it to `outline/.gitignore` in the same change.

If private data was already pushed, removing it from the files is not enough: tell the user it is in the history and needs a history rewrite and force-push, which they must approve.
