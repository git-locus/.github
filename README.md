# Locus, repo di orchestrazione `.github`

Questa repo è il **cuore del ciclo di vita** di Locus. Contiene:

- Il **Dockerfile fullstack** che impacchetta Django + Next.js in un'unica immagine.
- La **configurazione nginx** con HTTPS automatico via Let's Encrypt.
- Il **`docker-compose.yml`** per lo sviluppo locale.
- Il **workflow GitHub Actions** di build e deploy su Azure.

---

## Struttura

```
.github/
├── Dockerfile              # Build multi-stage dell'immagine fullstack
├── supervisord.conf        # Supervisord: gestisce nginx, gunicorn, Next.js
├── app.env.example         # Template delle variabili d'ambiente di produzione
├── docker-compose.yml      # Ambiente di sviluppo locale
├── nginx/
│   ├── nginx.conf              # Config nginx per docker-compose locale
│   ├── nginx.fullstack.conf    # Template nginx per il container di produzione
│   ├── security-headers.conf   # Header di sicurezza condivisi, `include`d sia dal
│   │                           # server block HTTPS che da location /static/ in nginx.fullstack.conf
│   └── nginx-acme.conf         # Config nginx temporanea per ACME challenge
├── scripts/
│   └── init-https.sh       # Entrypoint: genera nginx.conf, ottiene cert TLS, avvia supervisord
└── .github/
    └── workflows/
        └── deploy.yml      # Workflow di build e sync verso l'infra Azure
```

---

## Immagine Docker

Il `Dockerfile` usa un build **multi-stage**:

| Stage | Base | Scopo |
|---|---|---|
| `client-deps` | `node:20-alpine` | Installa le dipendenze npm |
| `client-builder` | `node:20-alpine` | Compila Next.js in modalità `standalone` |
| `api-builder` | `python:3.12-alpine` | Installa le dipendenze Python con `uv` |
| `final` | `python:3.12-alpine` | Immagine runtime con nginx + supervisord |

L'immagine finale contiene **tre processi** gestiti da supervisord:

- `gunicorn`: Django API su `127.0.0.1:8000`, non su tutte le interfacce (nginx gli parla comunque solo via loopback)
- `node server.js`: Next.js standalone su `127.0.0.1:3000`
- `nginx`: Reverse proxy pubblico, espone `:8080` (HTTP→HTTPS redirect) e `:8081` (HTTPS)

### Porte esposte

| Porta container | Protocollo | Destinazione |
|---|---|---|
| `8080` | HTTP | Redirect 301 → HTTPS (+ ACME challenge) |
| `8081` | HTTPS | Traffico applicativo (Next.js + `/api/*` → Django) |

---

## TLS / HTTPS

L'entrypoint `scripts/init-https.sh` al primo avvio:

1. Genera `nginx.conf` dal template sostituendo `${DOMAIN}`.
2. Avvia nginx in HTTP-only per rispondere alla **ACME challenge** di Let's Encrypt.
3. Esegue `certbot certonly --webroot` per ottenere il certificato.
4. Se certbot fallisce (es. dominio non raggiungibile), genera un **certificato self-signed** come fallback.
5. Avvia `supervisord` con nginx, gunicorn e Next.js.

Il rinnovo automatico è gestito da un programma supervisord (`certbot-renew`) che esegue `certbot renew` ogni 12 ore.

**Variabili richieste:**

```
DOMAIN=locus.now
LETS_ENCRYPT_EMAIL=ops@locus.now
```

---

## Sviluppo locale

### Prerequisiti

- Docker (o Podman con `podman-compose`)
- Crea il file `.env` nella root della repo a partire da `app.env.example`

### Avvio

```bash
# dalla cartella .github/
docker compose up
# oppure con podman:
podman compose up
```

Il compose avvia 4 servizi (nessun database Postgres: in locale Django usa
`settings_dev`, che di default è SQLite):

| Servizio | Immagine | Funzione |
|---|---|---|
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Emulatore Azure Blob Storage |
| `api` | `ghcr.io/astral-sh/uv:python3.12-alpine` | Django con hot-reload (`runserver`) |
| `client` | `node:26-alpine` | Next.js con hot-reload (`npm run dev`) |
| `nginx` | `nginx:alpine` | Reverse proxy su `http://localhost:8080` |

Il sorgente di `api/` e `client/` è montato come volume: le modifiche al codice sono subito visibili senza rebuild.

Il servizio `client` usa `node:26-alpine`, in linea con la versione Node
usata da `client/.github/workflows/test.yml` (`actions/setup-node`,
versione 26), non `node:20-alpine`: su Node 20, `npm run test:ci` fallisce
con `webidl.util.markAsUncloneable is not a function` (incompatibilità tra
`jsdom@30`/`undici@8` installati e quella versione di Node), quindi
`podman compose exec client npm run test:ci` avrebbe altrimenti richiesto
di lanciare `vitest` con un'immagine diversa da quella del compose.

### Verifica locale con compose

Il compose stack è il modo raccomandato per la verifica locale E2E. Non serve un `.env` popolato: i default fake sono sufficienti per lo sviluppo.

```bash
cd .github
podman compose up --build -d      # oppure docker compose
podman compose logs -f             # seguire i log
curl -i http://localhost:8080/api/categories/   # verifica

# test dell'api con Azurite (l'intera suite passa nel compose)
podman compose exec api uv run pytest

podman compose down -v             # cleanup
```

Per verificare le modifiche all'immagine di produzione (Dockerfile,
supervisord, nginx.fullstack.conf, init-https.sh) usare il build diretto:

```bash
podman build -t locus-fullstack .github
podman run --rm -p 8080:8080 -p 8081:8081 --env-file .github/.env locus-fullstack
```

---

## Deploy su Azure

### Branch, pull request e documentazione

La convenzione branch ad-hoc → pull request → `dev` vale per i repository applicativi `api` e `client`. Quando il lavoro è completo e verificato, apri una pull request verso `dev` e considera i controlli GitHub Actions della PR parte della definizione di pronto.

Per questa repo di orchestrazione è accettabile committare e pushare direttamente su `main` quando la modifica è circoscritta e verificata. Prima del merge in `dev` di `api` o `client`, e sempre prima di modifiche architetturali o operative importanti, aggiorna i README e gli altri file `.md` coinvolti: non solo il README principale, ma ogni documento Markdown pertinente nei repository interessati.

### Panoramica del flusso

```
push su main (api / client / .github)
        │
        ▼
  Workflow deploy.yml
  ├─ Checkout api, client, .github
  ├─ docker build → immagine fullstack
  ├─ docker push → GHCR (ghcr.io/git-locus/locus:<sha>)
  └─ git push sync/<run-id>-<sha> → docker2azure4student
                                          │
                                          ▼
                                    Workflow B (infra repo)
                                    └─ Deploy su Azure Container Instance
```

### Trigger

Il workflow `deploy.yml` si attiva su:

- `push` su `main` di questa repo (`.github`)
- `repository_dispatch` di tipo `deploy` inviato da `api` o `client`
- `workflow_dispatch` manuale dalla GitHub UI

I dispatch provenienti dalla repo `knowledge` vengono ignorati.

### Secrets e variabili richiesti

Configurati in **questa repo** → Settings → Secrets / Variables:

| Nome | Tipo | Descrizione |
|---|---|---|
| `APP_CLIENT_ID` | Secret | Client ID della GitHub App "locus-deploy-bot" (installata su `api`, `client`, `docker2azure4student` con permesso Contents: Read and write) |
| `APP_PRIVATE_KEY` | Secret | Chiave privata (.pem) della stessa GitHub App |
| `CONTAINER_REGISTRY_PASSWORD` | Secret | Password/token per il container registry |
| `REGISTRY_LOGIN_SERVER` | Variable | Es. `ghcr.io` |
| `IMAGE_REGISTRY` | Variable | Es. `ghcr.io/git-locus` |
| `IMAGE_NAME` | Variable | Es. `locus` |
| `CONTAINER_REGISTRY_USERNAME` | Variable | Username del registry |

`APP_ENV_VARS_B64` non è un secret di questa repo: vive su
`docker2azure4student` e serve solo a inizializzare `app-env-base` su
Key Vault al primissimo deploy di un ambiente nuovo (vedi sotto).

### Aggiornare le variabili d'ambiente di produzione

`app.env.example` in questa repo resta il riferimento per **quali**
variabili esistono; il valore attuale, però, non vive più in un secret
GitHub una volta che l'ambiente è stato creato: vive nel secret
`app-env-base` del Key Vault Azure (`locus-kv`), letto e riassemblato
dal deploy workflow ad ogni run. Solo due identità hanno accesso ai
secret di quel Key Vault (access policy, non RBAC): il service
principal `locus-deploy` (usato dalla pipeline via OIDC) e la managed
identity `locus-vm` (sola lettura, usata dalla VM). Nessun account
umano ce l'ha per default.

Per aggiungere o cambiare una variabile:

1. Chi deve farlo si dà accesso temporaneo (richiede ruolo Owner/
   Contributor sulla subscription):

   ```bash
   az keyvault set-policy --name locus-kv --upn <la-tua-email> \
     --secret-permissions get list set
   ```

2. Legge, modifica, riscrive `app-env-base`:

   ```bash
   az keyvault secret show --vault-name locus-kv --name app-env-base \
     --query value -o tsv | base64 -d > .env
   # modifica .env con un editor
   base64 -w0 .env > .env.b64
   az keyvault secret set --vault-name locus-kv --name app-env-base --file .env.b64
   shred -u .env .env.b64
   ```

3. Si revoca l'accesso appena finito:

   ```bash
   az keyvault delete-policy --name locus-kv --upn <la-tua-email>
   ```

4. La modifica diventa effettiva al prossimo deploy (il workflow rilegge
   `app-env-base` ad ogni run).

---

## Repo correlate

| Repo | Ruolo |
|---|---|
| `git-locus/api` | Backend Django |
| `git-locus/client` | Frontend Next.js |
| `git-locus/.github` (questa) | Orchestrazione build e deploy |
| `git-locus/docker2azure4student` | Infra Azure, riceve il sync bundle e fa il deploy |
| `git-locus/knowledge` | Documentazione e guide operative |

---

## Sicurezza

### Hardening attivo

- **Container non-root**: nginx, gunicorn e Next.js girano come utente non
  privilegiato `django` (vedi `Dockerfile` + `supervisord.conf`).
- **Next.js e gunicorn su loopback**: `node server.js` bind su
  `HOSTNAME=127.0.0.1` e `gunicorn` (`api/entrypoint.sh`) bind su
  `127.0.0.1:8000` (nessuno dei due su `0.0.0.0`), dato che nginx parla
  comunque a entrambi solo via loopback. Cosi' anche se un futuro
  `docker run` pubblicasse per errore la porta 3000 o 8000, il processo
  rifiuta comunque connessioni esterne invece di fare affidamento solo sul
  fatto che quella porta non e' pubblicata oggi.
- **`/admin` dietro SSO GitHub-org**: `nginx.fullstack.conf` chiede a
  oauth2-proxy (processo separato, `127.0.0.1:4180`, solo provider
  GitHub, membro dell'org `git-locus`) tramite `auth_request` prima di
  inoltrare qualunque richiesta a `/admin/`; senza sessione valida
  l'utente viene rediretto direttamente al login GitHub
  (`--skip-provider-button`), Django non viene mai raggiunto. Il login
  staff di Django resta comunque attivo sopra, come secondo livello
  indipendente: anche una sessione oauth2-proxy compromessa non basta da
  sola. Configurazione: `OAUTH2_PROXY_CLIENT_ID`/`_CLIENT_SECRET`/
  `_COOKIE_SECRET` nell'`app-env-base` di Key Vault (vedi sotto), OAuth
  App creata su GitHub → Org `git-locus` → Settings → Developer
  settings → OAuth Apps, callback `https://<dominio>/oauth2/callback`.
- **TLS**: solo TLSv1.2/1.3, cipher Mozilla Intermediate, OCSP stapling,
  `ssl_session_tickets off`.
- **Headers**: HSTS 1y preload, CSP restrittiva, `X-Frame-Options DENY`,
  `Referrer-Policy strict-origin-when-cross-origin`, `Permissions-Policy`
  che blocca camera/mic/geolocation/payment/USB, COOP/CORP. Condivisi tra il
  server block HTTPS e `location /static/` via `include nginx/security-headers.conf`
  (`add_header` di nginx non fa inheritance tra blocchi, quindi
  dichiararli solo in parte su `/static/` ne perderebbe silenziosamente
  il resto). `script-src` mantiene `'unsafe-inline'` qui come baseline a
  livello nginx: il browser applica l'intersezione di tutti gli header
  CSP ricevuti, e `client` sovrappone il proprio, più restrittivo,
  basato su nonce (`client/src/middleware.js`, vedi
  [client/README.md](https://github.com/git-locus/client/blob/main/README.md#security)),
  quindi la policy nonce-based non viene indebolita da questa. Questo
  file deve però restare sicuro da solo per tutto ciò che nginx serve
  direttamente (es. `/static/`), dove nessun middleware Next.js gira mai.
- **Rate limit nginx** per zone: `auth_zone` 5r/m sugli endpoint di
  login/signup/password-reset, `upload_zone` 2r/s sugli upload, `api_zone`
  20r/s generico.
- **Trigger di deploy filtrato**: il workflow `deploy.yml` parte su `push`
  solo se cambiano file rilevanti (`Dockerfile`, `nginx/**`, `supervisord.conf`,
  `scripts/**`, `app.env.example`, `docker-compose.yml`, `deploy.yml`).
  Modifiche a README, agenti, instructions, knowledge non triggerano deploy.
  Le altre repo (`api`, `client`) usano `paths-ignore` analogo nel
  workflow `notify-deploy.yml`.

### Workflow CI di sicurezza

| Workflow | Trigger | Cosa fa |
|---|---|---|
| `security.yml` | PR su `main`, weekly cron, `workflow_dispatch` | hadolint, trivy-config (CRITICAL/HIGH/MEDIUM), shellcheck, actionlint, zizmor, gitleaks (full history con allowlist) |
| `dast-zap.yml` | weekly cron, PR (su modifiche al `Dockerfile`), `workflow_dispatch` | Avvia lo stack docker compose effimero ed esegue ZAP baseline contro `http://localhost:8080` |

Le repo `api` e `client` hanno workflow `security.yml` analoghi (bandit, semgrep,
pip-audit / npm-audit, codeql, trivy-fs, gitleaks). Tutte le action usate sono
pinnate per SHA40.

