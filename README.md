# Locus — repo di orchestrazione `.github`

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
| `client-deps` | `node:18-alpine` | Installa le dipendenze npm |
| `client-builder` | `node:18-alpine` | Compila Next.js in modalità `standalone` |
| `api-builder` | `python:3.12-alpine` | Installa le dipendenze Python con `uv` |
| `final` | `python:3.12-alpine` | Immagine runtime con nginx + supervisord |

L'immagine finale contiene **tre processi** gestiti da supervisord:

- `gunicorn` — Django API su `127.0.0.1:8000`
- `node server.js` — Next.js standalone su `127.0.0.1:3000`
- `nginx` — Reverse proxy pubblico, espone `:8080` (HTTP→HTTPS redirect) e `:8081` (HTTPS)

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

Il compose avvia 5 servizi:

| Servizio | Immagine | Funzione |
|---|---|---|
| `db` | `postgres:16-alpine` | Database PostgreSQL |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Emulatore Azure Blob Storage |
| `api` | `python:3.12-alpine` | Django con hot-reload (`runserver`) |
| `client` | `node:18-alpine` | Next.js con hot-reload (`npm run dev`) |
| `nginx` | `nginx:alpine` | Reverse proxy su `http://localhost:8080` |

Il sorgente di `api/` e `client/` è montato come volume: le modifiche al codice sono subito visibili senza rebuild.

---

## Deploy su Azure

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
| `INFRA_REPO_PAT` | Secret | PAT con `contents:write` su `docker2azure4student` |
| `CONTAINER_REGISTRY_PASSWORD` | Secret | Password/token per il container registry |
| `APP_ENV_VARS_B64` | Secret | Contenuto di `app.env` codificato in base64 |
| `REGISTRY_LOGIN_SERVER` | Variable | Es. `ghcr.io` |
| `IMAGE_REGISTRY` | Variable | Es. `ghcr.io/git-locus` |
| `IMAGE_NAME` | Variable | Es. `locus` |
| `CONTAINER_REGISTRY_USERNAME` | Variable | Username del registry |

### Aggiornare le variabili d'ambiente di produzione

1. Modifica il file `.env` nella root della repo locale (vedi `app.env.example`).
2. Rigenera il base64: `base64 -w0 .env > .env.b64`
3. Copia il contenuto di `.env.b64` nel secret `APP_ENV_VARS_B64` su GitHub.

---

## Repo correlate

| Repo | Ruolo |
|---|---|
| `git-locus/api` | Backend Django |
| `git-locus/client` | Frontend Next.js |
| `git-locus/.github` (questa) | Orchestrazione build e deploy |
| `git-locus/docker2azure4student` | Infra Azure — riceve il sync bundle e fa il deploy |
| `git-locus/knowledge` | Documentazione e guide operative |
