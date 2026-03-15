# Locus

This repository contains shared configurations, workflows, and templates used across all **git-locus** repositories.

## Contents

- **CI/CD** — [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml): reusable workflow that builds the fullstack Docker image and triggers deployment on Azure via [`docker2azure4student`](https://github.com/git-locus/docker2azure4student).
- **Docker** — [`Dockerfile`](Dockerfile): multi-stage image (Next.js + Django + nginx) built in CI and deployed on the VM.
- **Local development** — [`docker-compose.yml`](docker-compose.yml): stack locale con hot-reload (nessun build necessario).
- **Templates** — Issue templates e PR template per standardizzare i contributi.

## Repositories

| Repo | Descrizione |
|---|---|
| [`api`](https://github.com/git-locus/api) | Backend Django REST Framework |
| [`client`](https://github.com/git-locus/client) | Frontend Next.js |
| [`knowledge`](https://github.com/git-locus/knowledge) | Documentazione interna |

## Deploy

Ogni push su `main` di `api` o `client` triggera automaticamente il workflow di build e deploy. Per un deploy manuale: **Actions → Build & sync to Azure infra → Run workflow**.
