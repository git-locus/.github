# =============================================================================
# Locus – Fullstack Docker image
#
# Struttura del build (multi-stage):
#
#   client-deps    → installa npm deps
#   client-builder → compila Next.js (standalone)
#   api-builder    → installa dipendenze Python con uv
#   final          → immagine runtime: nginx + supervisor + Next.js + Django
#
# L'immagine finale espone:
#   :8080  → nginx (reverse proxy pubblico, HTTP)
#   nginx instrada /api/* → gunicorn (interno :8000)
#            tutto il resto → Next.js standalone (interno :3000)
#
# Build dal contesto della repo .github (dove si trova questo file):
#   docker build \
#     --build-arg CLIENT_DIR=../client \
#     --build-arg API_DIR=../api \
#     -t locus:latest .
#
# In CI il workflow copia client/ e api/ al suo fianco prima del build,
# quindi il contesto è la cartella sync-bundle/ e i path sono relativi.
# =============================================================================

ARG PYTHON_VERSION=3.12.2
ARG NODE_VERSION=18

# -----------------------------------------------------------------------------
# Stage 1 – Client: installa dipendenze npm
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS client-deps
RUN apk add --no-cache libc6-compat
WORKDIR /client
COPY client/package.json client/package-lock.json* ./
RUN npm ci

# -----------------------------------------------------------------------------
# Stage 2 – Client: compila Next.js in modalità standalone
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS client-builder
WORKDIR /client
COPY --from=client-deps /client/node_modules ./node_modules
COPY client/ .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# -----------------------------------------------------------------------------
# Stage 3 – API: installa dipendenze Python con uv
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
# Stage 4 – Runtime finale
# -----------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-alpine AS final

# --- Sistema base ---
RUN apk add --no-cache \
        nginx \
        nodejs \
        supervisor \
        curl \
    && rm -rf /var/cache/apk/*

# --- Utente non-root per Next.js ---
RUN addgroup -S nodejs && adduser -S -G nodejs nextjs

# ---- API (Django + gunicorn) ----
WORKDIR /api
ENV VIRTUAL_ENV=/api/.venv \
    PATH="/api/.venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=api-builder /api/.venv /api/.venv
COPY api/src/manage.py ./
COPY api/src/apps ./apps
COPY api/src/api ./api
COPY api/entrypoint.sh api/setup.sh ./
RUN chmod +x ./entrypoint.sh ./setup.sh

# ---- Client (Next.js standalone) ----
WORKDIR /client
COPY --from=client-builder --chown=nextjs:nodejs /client/public ./public
COPY --from=client-builder --chown=nextjs:nodejs /client/.next/standalone ./
COPY --from=client-builder --chown=nextjs:nodejs /client/.next/static ./.next/static
RUN mkdir -p .next && chown nextjs:nodejs .next

# ---- Nginx ----
COPY .github/nginx/nginx.fullstack.conf /etc/nginx/nginx.conf

# ---- Supervisor ----
COPY .github/supervisord.conf /etc/supervisord.conf

# ---- Static files (condivisi tra Django e nginx) ----
RUN mkdir -p /static && chown nobody:nobody /static

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
