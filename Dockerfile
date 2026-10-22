# =============================================================================
# Locus – Fullstack Docker image
#
# Build structure (multi-stage):
#
#   client-deps    → installs the npm deps
#   client-builder → builds Next.js (standalone)
#   api-builder    → installs the Python dependencies with uv
#   final          → runtime image: nginx + supervisor + Next.js + Django
#
# The final image exposes:
#   :8080  → nginx (public reverse proxy, HTTP)
#   nginx routes /api/* → gunicorn (internal :8000)
#            everything else → standalone Next.js (internal :3000)
#
# Build from the context of the .github repository (where this file is):
#   docker build \
#     --build-arg CLIENT_DIR=../client \
#     --build-arg API_DIR=../api \
#     -t locus:latest .
#
# In CI the workflow copies client/ and api/ next to it before the build,
# so the context is the sync-bundle/ folder and the paths are relative.
# =============================================================================

ARG PYTHON_VERSION=3.12.2
ARG NODE_VERSION=20

# -----------------------------------------------------------------------------
# Stage 1 – Client: install the npm dependencies
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS client-deps
# npm 10.x (bundled with node:20) has a real Arborist bug resolving
# circular/optional peer dependencies (TypeError: Cannot read properties
# of null (reading 'edgesOut') in build-ideal-tree.js), reproducible with
# vitest 5's peer set; npm 11 fixes it and still supports Node 20.
RUN apk add --no-cache libc6-compat \
    && npm install -g npm@11
WORKDIR /client
COPY client/package.json client/package-lock.json ./
RUN npm ci

# -----------------------------------------------------------------------------
# Stage 2 – Client: build Next.js in standalone mode
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS client-builder
WORKDIR /client
COPY --from=client-deps /client/node_modules ./node_modules
COPY client/ .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# -----------------------------------------------------------------------------
# Stage 3 – API: install the Python dependencies with uv
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-alpine AS api-builder
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv
WORKDIR /api
COPY api/src/pyproject.toml api/src/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# -----------------------------------------------------------------------------
# Stage 4 – Final runtime
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-alpine AS final

# --- Base system ---
RUN apk add --no-cache \
        nginx \
        nodejs \
        supervisor \
        curl \
        openssl \
        gettext \
    && pip install --no-cache-dir certbot \
    && rm -rf /var/cache/apk/*

# --- Unprivileged users for Next.js, Django and oauth2-proxy ---
# nginx, supervisord and certbot keep running as root (needed to bind
# privileged ports, write /etc/letsencrypt, and so on). Only the application
# processes drop privileges.
RUN addgroup -S nodejs && adduser -S -G nodejs nextjs \
    && addgroup -S django && adduser -S -G django django \
    && addgroup -S oauth2proxy && adduser -S -G oauth2proxy oauth2proxy

# ---- oauth2-proxy: gate on /admin (see nginx.fullstack.conf) ----
# Official binary downloaded and verified against the published checksum, not
# an external Docker image: it stays a single reproducible build layer.
SHELL ["/bin/ash", "-o", "pipefail", "-c"]
ARG OAUTH2_PROXY_VERSION=7.15.4
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) OAUTH2_PROXY_SHA256="4fbe902189aab713d9c0519b90a645032d4636ecb523dc36f5cc312d8ebef1e2" ;; \
        arm64) OAUTH2_PROXY_SHA256="b3fb0b61aecfb4b776dccb6daff406676ed0ead74245dc6e4bdf71f993eb1710" ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    ARCHIVE="oauth2-proxy-v${OAUTH2_PROXY_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v${OAUTH2_PROXY_VERSION}/${ARCHIVE}"; \
    echo "${OAUTH2_PROXY_SHA256}  ${ARCHIVE}" | sha256sum -c -; \
    mkdir -p /tmp/oauth2-proxy && tar -xzf "${ARCHIVE}" -C /tmp/oauth2-proxy; \
    mv /tmp/oauth2-proxy/*/oauth2-proxy /usr/local/bin/oauth2-proxy; \
    chmod +x /usr/local/bin/oauth2-proxy; \
    rm -rf "${ARCHIVE}" /tmp/oauth2-proxy

# ---- API (Django + gunicorn) ----
WORKDIR /api
ENV VIRTUAL_ENV=/api/.venv \
    PATH="/api/.venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=api-builder --chown=django:django /api/.venv /api/.venv
COPY --chown=django:django api/src/manage.py ./
COPY --chown=django:django api/src/apps ./apps
COPY --chown=django:django api/src/api ./api
COPY --chown=django:django api/src/scripts ./scripts
COPY --chown=django:django api/entrypoint.sh api/setup.sh ./
RUN chmod +x ./entrypoint.sh ./setup.sh

# ---- Client (Next.js standalone) ----
WORKDIR /client
COPY --from=client-builder --chown=nextjs:nodejs /client/public ./public
COPY --from=client-builder --chown=nextjs:nodejs /client/.next/standalone ./
COPY --from=client-builder --chown=nextjs:nodejs /client/.next/static ./.next/static
RUN mkdir -p .next && chown nextjs:nodejs .next

# ---- Nginx ----
COPY .github/nginx/nginx.fullstack.conf /etc/nginx/nginx.template.conf
COPY .github/nginx/nginx-acme.conf /etc/nginx/nginx-acme.conf
COPY .github/nginx/security-headers.conf /etc/nginx/security-headers.conf

# ---- Supervisor ----
COPY .github/supervisord.conf /etc/supervisord.conf

# ---- Init HTTPS and the daily digest scheduler ----
COPY .github/scripts/init-https.sh .github/scripts/send-digest-loop.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-https.sh /usr/local/bin/send-digest-loop.sh

# ---- Static files (shared between Django and nginx) ----
# Owned by the django user: collectstatic runs as django and must write here.
# nginx reads as root (internal privilege drop through worker_processes).
RUN mkdir -p /static && chown -R django:django /static

EXPOSE 8080 8081

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=30s \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:8000/healthz/ || exit 1"]

CMD ["/usr/local/bin/init-https.sh"]
