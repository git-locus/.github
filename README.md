# Locus `.github`: build, run and deploy

This repository is the **life cycle hub** of [Locus](https://locus.now). It holds:

- the **fullstack Dockerfile** that packages Django and Next.js in a single image,
- the **nginx configuration**, with automatic HTTPS through Let's Encrypt,
- the **`docker-compose.yml`** for local development,
- the **GitHub Actions workflows** that build the image and hand it to the Azure deploy,
- the organization-wide community files (`CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, the pull request template and the issue forms), which GitHub applies as defaults to every repository of the organization that has none of its own.

If you want to contribute, start from [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Layout

```
.github/
├── Dockerfile              # Multi-stage build of the fullstack image
├── supervisord.conf        # Supervisord: runs the API, the daily digest scheduler, the client, oauth2-proxy, nginx and certbot renewal
├── app.env.example         # Template of the production environment variables
├── docker-compose.yml      # Local development environment
├── nginx/
│   ├── nginx.conf              # nginx config for the local docker compose
│   ├── nginx.fullstack.conf    # nginx template for the production container
│   ├── security-headers.conf   # Shared security headers, included by both the HTTPS
│   │                           # server block and `location /static/` of nginx.fullstack.conf
│   └── nginx-acme.conf         # Temporary nginx config for the ACME challenge
├── scripts/
│   ├── init-https.sh       # Entrypoint: generates nginx.conf, gets the TLS certificate, starts supervisord
│   ├── send-digest-loop.sh # Daily digest scheduler (supervisord program `digest`)
│   └── test-send-digest-loop.sh  # Tests of the scheduler, run by the Scripts workflow
├── CONTRIBUTING.md         # How to contribute (organization default)
├── SECURITY.md             # How to report a vulnerability (organization default)
├── CODE_OF_CONDUCT.md      # Code of conduct (organization default)
├── agents/
│   └── locus-platform-guardian.agent.md   # Development and review agent for the whole workspace
├── profile/
│   └── README.md           # Public page of the GitHub organization
└── .github/
    ├── CODEOWNERS
    ├── dependabot.yml      # Automatic dependency updates
    ├── PULL_REQUEST_TEMPLATE.md   # Pull request template (organization default)
    ├── ISSUE_TEMPLATE/     # Issue forms (organization default)
    └── workflows/
        ├── deploy.yml      # Build and sync towards the Azure infrastructure
        ├── security.yml    # Security checks on this repository
        ├── scripts.yml     # Tests and lints the shell scripts of the image
        ├── dast-zap.yml    # DAST scan (ZAP) of the compose stack
        └── site-health.yml # Periodic check of the site and its certificate in production
```

---

## Docker image

The `Dockerfile` is a **multi-stage** build:

| Stage | Base | Purpose |
|---|---|---|
| `client-deps` | `node:20-alpine` | Installs the npm dependencies with `npm ci`, from the lockfile of the client |
| `client-builder` | `node:20-alpine` | Builds Next.js in `standalone` mode |
| `api-builder` | `python:3.12-alpine` | Installs the Python dependencies with `uv` |
| `final` | `python:3.12-alpine` | Runtime image with nginx and supervisord |

The image builds with Node 20 (`NODE_VERSION` in the Dockerfile). The local compose and CI use Node 26, because the client's test suite needs it.

The final image runs six programs under supervisord:

- `gunicorn`: the Django API on `127.0.0.1:8000` (loopback only, nginx talks to it that way),
- `digest`: the daily digest and weekly discovery scheduler (see below),
- `node server.js`: standalone Next.js on `127.0.0.1:3000`,
- `oauth2-proxy`: the single sign-on gate in front of `/admin/`, on `127.0.0.1:4180`,
- `nginx`: the public reverse proxy, exposing `:8080` (HTTP to HTTPS redirect) and `:8081` (HTTPS),
- `certbot-renew`: a loop that renews the TLS certificate.

### Daily digest and weekly discovery

The digest e-mail needs no external scheduler: the `digest` program runs `scripts/send-digest-loop.sh`, which sleeps until `DIGEST_RUN_AT_UTC` (default `06:30`, that is 07:30 in winter and 08:30 in summer in Europe/Rome) and then runs `python manage.py send_digest` as the `django` user. The command sends at most one digest per person per calendar day, so a second run is harmless. A failed run is logged and the loop carries on with the next day.

Right after the digest the same program runs `python manage.py send_weekly` (the weekly discovery e-mail, overridable with `DIGEST_WEEKLY_COMMAND`). That command sends at most one e-mail per person per calendar week in Europe/Rome, so the first run of a week sends it and the other days do nothing; a failing digest does not stop it. Both are switched on by the same `DIGEST_ENABLED=1`.

It is **off unless `DIGEST_ENABLED=1`** is in the container environment (`app-env-base`, see below): without it the program only sleeps and sends nothing. The time is plain UTC arithmetic, so the image needs no time zone database. A container that restarts across the run time skips that day, and the next digest covers it (the window reaches back to the previous digest, 48 hours at most). Output goes to the container logs.

To check the scheduler without waiting for the time of day, run `sh scripts/test-send-digest-loop.sh`. To try the real commands on one account, `python manage.py send_digest --dry-run --username <name>` and `python manage.py send_weekly --dry-run --username <name>` inside the container count what they would send and send nothing.

### Exposed ports

| Container port | Protocol | Destination |
|---|---|---|
| `8080` | HTTP | 301 redirect to HTTPS (and the ACME challenge) |
| `8081` | HTTPS | Application traffic (Next.js, and `/api/*` to Django) |

---

## TLS and HTTPS

On first start, the entrypoint `scripts/init-https.sh`:

1. generates `nginx.conf` from the template, substituting `${DOMAIN}`,
2. starts nginx in HTTP-only mode to answer the Let's Encrypt **ACME challenge**,
3. runs `certbot certonly --webroot` to get the certificate,
4. if certbot fails (for example the domain is unreachable), generates a **self-signed certificate** as a fallback,
5. starts `supervisord` with all the programs.

Automatic renewal is handled by a supervisord program (`certbot-renew`) that runs `certbot renew` every 12 hours and, after a renewal, reloads nginx without downtime (`--deploy-hook 'nginx -s reload'`). The certbot output goes to the container logs (journald on the VM). Certbot renews only when less than 30 days remain before expiry.

If renewal fails, `site-health.yml` reports it: it fails when the certificate has less than 14 days of validity. To check the renewal path without touching the certificate in use, run `certbot renew --dry-run` inside the container (it uses the Let's Encrypt staging environment).

**Required variables:**

```
DOMAIN=locus.now
LETS_ENCRYPT_EMAIL=ops@locus.now
```

---

## Local development

### Prerequisites

- Docker, or Podman with `podman-compose`
- A `.env` file at the root of this repository, created from `app.env.example` (the fake defaults are enough for development)

### Start

```bash
# from the .github folder
docker compose up
# or with podman:
podman compose up
```

The `api/` and `client/` repositories must be checked out next to this one, because the compose file mounts them. The compose starts four services (there is no Postgres: locally Django uses `settings_dev`, which defaults to SQLite):

| Service | Image | Purpose |
|---|---|---|
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Azure Blob Storage emulator |
| `api` | `ghcr.io/astral-sh/uv:python3.12-alpine` | Django with hot reload (`runserver`) |
| `client` | `node:26-alpine` | Next.js with hot reload (`npm run dev`) |
| `nginx` | `nginx:alpine` | Reverse proxy on `http://localhost:8080` |

The sources of `api/` and `client/` are mounted as volumes, so code changes show up without a rebuild.

The `client` service uses `node:26-alpine`, in line with the Node version used by the client's `test.yml` workflow, and not `node:20-alpine`: on Node 20, `npm run test:ci` fails with `webidl.util.markAsUncloneable is not a function` (an incompatibility between the installed `jsdom@30` and `undici@8` and that Node version).

### Checking changes locally

The compose stack is the recommended way to verify things end to end. No populated `.env` is needed:

```bash
cd .github
podman compose up --build -d      # or docker compose
podman compose logs -f            # follow the logs
curl -i http://localhost:8080/api/categories/   # smoke test

# API tests with Azurite (the whole suite passes inside the compose)
podman compose exec api uv run pytest

podman compose down -v            # cleanup
```

To check changes to the production image (Dockerfile, supervisord, `nginx.fullstack.conf`, `init-https.sh`), build it directly:

```bash
podman build -t locus-fullstack .github
podman run --rm -p 8080:8080 -p 8081:8081 --env-file .github/.env locus-fullstack
```

---

## Deploy to Azure

Branches, pull requests and the promotion of `dev` to `main` are described once, in [CONTRIBUTING.md](CONTRIBUTING.md). Two things matter for this repository. A merge to `main` of `api` or `client` deploys to production, so it is promoted only deliberately and always through a pull request with a plain merge commit. And `main` of this repository is protected: changes go through a pull request here too. Update the READMEs and other Markdown documents a change makes stale in the same pull request.

### Flow overview

```
push to main (api / client / .github)
        │
        ▼
  deploy.yml workflow
  ├─ Checkout of api, client, .github
  ├─ docker build → fullstack image
  ├─ docker push → GHCR (ghcr.io/git-locus/locus:<sha>)
  └─ git push sync/<run-id>-<sha> → docker2azure4student
                                          │
                                          ▼
                                    Workflow B (infrastructure repo)
                                    └─ Deploys the container to the Azure VM
                                       (docker pull with retries, then restart)
```

`docker2azure4student` (the infrastructure repository) holds no code of its own: its two workflows call the public template [morph-eos/docker2azure4student](https://github.com/morph-eos/docker2azure4student) at a **fixed release** (`v1.0.0` today, set after the `@` in `.github/workflows/deploy-from-sync.yml` and `rollback.yml`). The Terraform that runs on a deploy is that release's; to take a newer one, read its release notes and change the version in both files (one pull request). A rollback of the infrastructure takes a tag of the template as `git_ref`.

The workflow always rebuilds the image from `main` of **both** `api` and `client`: you cannot release only one of them. `deploy.yml` has a `concurrency` (`group: deploy-production`, `cancel-in-progress: false`), so two close dispatches queue instead of overlapping.

### Triggers

`deploy.yml` runs on:

- a `push` to `main` of this repository (`.github`), only when relevant files change (`Dockerfile`, `nginx/**`, `supervisord.conf`, `scripts/**`, `app.env.example`, `docker-compose.yml`, `deploy.yml`),
- a `repository_dispatch` of type `deploy` sent by `api` or `client` (their `notify-deploy.yml` has a similar `paths-ignore`, so documentation-only changes do not deploy),
- a manual `workflow_dispatch` from the GitHub UI.

### Required secrets and variables

The secrets are configured in the **environment `production`** of this repository (Settings, Environments), not in the repository's own secrets: the environment is limited to the `main` branch, so a workflow on any other branch (a pull request, a test branch) cannot read them. The jobs of `deploy.yml` and `dast-zap.yml` declare `environment: production`.

| Name | Type | Description |
|---|---|---|
| `APP_CLIENT_ID` | Environment secret | Client ID of the "locus-deploy-bot" GitHub App (installed on `api`, `client` and `docker2azure4student` with Contents: Read and write; the workflow caps the token to that permission) |
| `APP_PRIVATE_KEY` | Environment secret | Private key (.pem) of the same GitHub App. To rotate it: generate a new key in the App's settings, set the secret, delete the old key |
| `CONTAINER_REGISTRY_USERNAME` | Environment secret | Registry username |
| `CONTAINER_REGISTRY_PASSWORD` | Environment secret | Password or token of the container registry |
| `REGISTRY_LOGIN_SERVER` | Environment secret | For example `ghcr.io` |
| `IMAGE_REGISTRY` | Environment secret | For example `ghcr.io/git-locus` |
| `IMAGE_NAME` | Environment secret | For example `locus` |
| `DOMAIN` | Variable | The production domain probed by the ZAP scan |

Set one with `gh secret set --env production --repo git-locus/.github NAME` (it asks for the value).

### Protection of `main` and of the deploy

- `main` has a ruleset: a pull request, the five jobs of the Security workflow passing, no force push, no deletion, **no bypass** (administrators included). Merge commits are the team's style and stay allowed.
- Third-party actions must be pinned to a full commit SHA (a repository setting), workflows get a read-only token by default, and the deploy takes `source_repo` and `source_sha` of a dispatch only if they have the expected shape.
- The ZAP scan does not run on pull requests: its fallback mints the App token, which a pull request must never reach.
- `api` and `client` call this repository with `DEPLOY_PAT`, a personal access token stored in each of them. It should become the GitHub App's short-lived token, like the rest of the chain.

`APP_ENV_VARS_B64` is not a secret of this repository: it lives in `docker2azure4student` and is used only to initialise `app-env-base` in Key Vault the very first time an environment is deployed (see below).

### Updating the production environment variables

`app.env.example` in this repository stays the reference for **which** variables exist. Once an environment has been created, the current values no longer live in a GitHub secret: they live in the `app-env-base` secret of the Azure Key Vault of the environment, which the deploy workflow reads and reassembles on every run. Only two identities can read that Key Vault's secrets (access policy, not RBAC): the `locus-deploy` service principal (used by the pipeline through OIDC) and the VM's managed identity (read only, used by the VM). No human account has access by default.

To add or change a variable:

1. Whoever needs to do it gives themselves temporary access (this requires the Owner or Contributor role on the subscription):

   ```bash
   az keyvault set-policy --name <key-vault-name> --upn <your-email> \
     --secret-permissions get list set
   ```

2. Read, edit and rewrite `app-env-base`:

   ```bash
   az keyvault secret show --vault-name <key-vault-name> --name app-env-base \
     --query value -o tsv | base64 -d > .env
   # edit .env with an editor
   base64 -w0 .env > .env.b64
   az keyvault secret set --vault-name <key-vault-name> --name app-env-base --file .env.b64
   shred -u .env .env.b64
   ```

3. Revoke the access as soon as you are done:

   ```bash
   az keyvault delete-policy --name <key-vault-name> --upn <your-email>
   ```

4. The change takes effect on the next deploy (the workflow rereads `app-env-base` on every run).

### Web push keys (VAPID)

Web push stays off while `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` are unset: nothing is sent, devices cannot register and the client hides every push control. A maintainer generates the pair once and adds it to `app-env-base` with the procedure above. Never paste the private key in a repository, an issue or a chat.

| Variable | Description |
|---|---|
| `VAPID_PUBLIC_KEY` | Public key, base64url text of the 65-byte point. The API gives it to browsers. |
| `VAPID_PRIVATE_KEY` | Private key, base64url text of the raw 32-byte key. A secret. |
| `VAPID_SUBJECT` | Contact the push services may use, `mailto:` or https. Defaults to `mailto:noreply@locus.now`. |

To generate a pair, run this once in the `api` container (it prints both values; copy them straight into the secret and close the terminal):

```python
import base64
from py_vapid import Vapid
from cryptography.hazmat.primitives import serialization as ser

key = Vapid()
key.generate_keys()
b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
print("VAPID_PRIVATE_KEY=" + b64(key.private_key.private_numbers().private_value.to_bytes(32, "big")))
print("VAPID_PUBLIC_KEY=" + b64(key.public_key.public_bytes(ser.Encoding.X962, ser.PublicFormat.UncompressedPoint)))
```

Keep the same pair for good: changing it makes every existing browser subscription stop working until people turn push on again.

### Logs and memory in production

On every deploy, `docker2azure4student` prepares the VM (2 GiB of swap with `vm.swappiness=10`, persistent journald capped at 300 MB) and starts the container with the `journald` log driver, so the nginx, Next.js and Django logs survive the `docker rm` of the next deploy. Gunicorn recycles its workers (`--max-requests` with jitter, see `api/entrypoint.sh`). An Azure Monitor alert e-mails the subscription Owners when the VM's available memory falls below a threshold. Details are in the Observability section of the `docker2azure4student` README.

The site and the certificate are checked by the `site-health.yml` workflow, scheduled every hour. GitHub's schedule is best effort: runs can arrive late or be skipped, so the check is there to catch a certificate that is about to expire, not to guarantee a detection time for an outage.

Where to look first when something is slow:

1. Log Analytics, table `AppRequests`: duration and failures of the Django requests.
2. The VM metrics in the portal (available memory), and `free -m` on the VM for swap.
3. The host logs: `journalctl CONTAINER_NAME=app-service --since "2 days ago"` for nginx timings, 4xx/5xx responses and Next.js errors.

---

## Related repositories

The repositories of the project, and what each one does, are listed in [CONTRIBUTING.md](CONTRIBUTING.md). This one orchestrates the build and the deploy, and hands the image to `docker2azure4student`, which deploys it on Azure.

---

## Security

To report a vulnerability, follow [SECURITY.md](SECURITY.md).

### Active hardening

- **Unprivileged application processes**: the API (gunicorn) runs as `django`, Next.js as `nextjs` and oauth2-proxy as `oauth2proxy`, each started by supervisord with its own `user=` (see `Dockerfile` and `supervisord.conf`). nginx's master process and certbot still run as root, which is tracked in two open issues about running them without root.
- **Next.js and gunicorn on loopback**: `node server.js` binds to `HOSTNAME=127.0.0.1` and gunicorn (`api/entrypoint.sh`) to `127.0.0.1:8000`, neither to `0.0.0.0`, since nginx talks to both over loopback anyway. So even if a future `docker run` published port 3000 or 8000 by mistake, the process would still refuse outside connections instead of relying only on that port not being published today.
- **`/admin` behind GitHub-organization SSO**: `nginx.fullstack.conf` asks oauth2-proxy (a separate process on `127.0.0.1:4180`, GitHub provider only, members of the `git-locus` organization) through `auth_request` before forwarding any request to `/admin/`. Without a valid session the user is redirected straight to the GitHub login (`--skip-provider-button`) and Django is never reached. Django's own staff login stays on top as an independent second layer, so a compromised oauth2-proxy session alone is not enough. Configuration: `OAUTH2_PROXY_CLIENT_ID`, `_CLIENT_SECRET` and `_COOKIE_SECRET` in the `app-env-base` secret of Key Vault (see above), and an OAuth App created on GitHub under the organization's Settings, Developer settings, OAuth Apps, with callback `https://<domain>/oauth2/callback`.
- **TLS**: TLSv1.2 and 1.3 only, Mozilla Intermediate ciphers, OCSP stapling, `ssl_session_tickets off`.
- **Headers**: HSTS for one year with preload, a restrictive CSP, `X-Frame-Options DENY`, `Referrer-Policy strict-origin-when-cross-origin`, a `Permissions-Policy` that blocks camera, microphone, geolocation, payment and USB, and COOP and CORP. They are shared between the HTTPS server block and `location /static/` through `include nginx/security-headers.conf` (nginx's `add_header` does not inherit between blocks, so declaring them only partly on `/static/` would silently lose the rest). `script-src` keeps `'unsafe-inline'` here as an nginx-level baseline: the browser applies the intersection of all the CSP headers it receives, and the client overlays its own stricter nonce-based one (`client/src/middleware.js`, see the [client security notes](https://github.com/git-locus/client/blob/main/docs/security.md)), so the nonce-based policy is not weakened by this one. This file must still be safe on its own for everything nginx serves directly (for example `/static/`), where no Next.js middleware ever runs.
- **nginx rate limits**, per zone: `auth_zone` 5r/m on the login, signup and password reset endpoints, `upload_zone` 2r/s on uploads, and `api_zone` 20r/s in general.
- **Filtered deploy trigger**: see the Triggers section above.

### Security CI workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `security.yml` | PR to `main`, weekly cron, `workflow_dispatch` | hadolint, trivy-config (CRITICAL, HIGH, MEDIUM), shellcheck, actionlint, zizmor, gitleaks (full history with an allowlist) |
| `scripts.yml` | PR touching `scripts/**`, `workflow_dispatch` | shellcheck and the tests of the digest scheduler (`scripts/test-send-digest-loop.sh`) under `sh` and `bash` |
| `dast-zap.yml` | weekly cron, PR (on `Dockerfile` changes), `workflow_dispatch` | Starts the ephemeral docker compose stack and runs a ZAP baseline scan against `http://localhost:8080` |
| `site-health.yml` | hourly cron (minute 7), `workflow_dispatch` | Checks that `https://$DOMAIN/landing` answers 200 and that the TLS certificate has at least 14 days of validity. If it fails, GitHub notifies about the failed workflow. It takes a few seconds and the repository is public, so it uses no paid minutes. It replaces a paid Azure availability test. |

The `api` and `client` repositories have similar `security.yml` workflows (bandit, semgrep, pip-audit or npm audit, CodeQL, trivy-fs, gitleaks). Every action used is pinned to a full commit SHA.
