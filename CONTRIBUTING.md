# Contributing to Locus

Thanks for wanting to help. Locus ("the social network for ideas") is made of a few repositories under the `git-locus` organization:

| Repo | What it is |
|---|---|
| `api` | Django REST API |
| `client` | Next.js web app |
| `.github` | Build, nginx, local compose stack and the deploy pipeline |
| `docker2azure4student` | Azure infrastructure (Terraform) |
| `knowledge` | Operational guides and cross-repo documentation |

Each repository has its own README with the details of its toolchain. Read it before changing that repository.

## Before you start

- Check the open issues. For anything bigger than a small fix, open an issue first and agree on the approach before writing code.
- Never commit secrets, real user data or personal information. Use fake values in tests, fixtures and examples.
- Security problems go through [SECURITY.md](SECURITY.md), not through public issues.
- By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Local setup

You need Docker, or Podman with `podman-compose`. No Azure account and no private registry is needed.

```bash
git clone git@github.com:git-locus/.github.git
git clone git@github.com:git-locus/api.git
git clone git@github.com:git-locus/client.git
cd .github
cp app.env.example .env        # the fake defaults are enough for development
docker compose up              # or: podman compose up
```

The app is then served at `http://localhost:8080`. The `api` and `client` folders must sit next to `.github`, because the compose file mounts them. See the README of the `.github` repository for details, including how to run the test suites inside the containers.

## Workflow

1. Create a branch from `dev` named `<type>/<short-description>`, where type is `feature`, `fix`, `chore` or `docs`.
2. Make your change, with tests and documentation (see below).
3. Open a pull request against `dev`. Describe what changed and why, and link the issue.
4. Run the tests and the linter of the repository locally: the automated checks of `api` and `client` run only on pull requests into `main`, not on pull requests into `dev`. Wait for a review. The owners listed in each repository's `CODEOWNERS` are asked for review automatically, but their approval is not required to merge. Pull requests from forks need a maintainer to approve the workflow run.
5. Maintainers promote `dev` to `main` with a separate pull request (where the checks run) and a plain merge commit. A merge to `main` of `api` or `client` deploys to production, so contributors never target `main` directly.

Commit messages follow the conventional style already used in the history, for example `feat(post): report an idea` or `fix(auth): refresh token on 401`.

## What every change needs

- **Tests.** New behaviour and bug fixes come with automated tests in the same pull request. Run the whole suite of every repository you touched:
  - `api`: from `api/src`, `DJANGO_SETTINGS_MODULE=api.settings_test uv run pytest`, and `uv run ruff check .` plus `uv run ruff format --check .`
  - `client`: `npm run test:ci` and `npm run lint`
- **Documentation.** If the change makes a README or another document stale (endpoints, environment variables, UI flows, architecture decisions), update it in the same pull request.
- **A look at the UI.** For any visible change, run the app and check the page yourself, including empty, loading and error states. Screenshots in the pull request help reviewers.
- **No weakening of security.** Do not loosen authentication, CSRF, permissions or password validation, and do not turn on `DEBUG` or add wildcard origins in production settings.

## Style

- Keep changes focused. Avoid unrelated refactors in the same pull request.
- Match the style of the surrounding code, including comment density and naming.
- Comments and documentation describe the current behaviour. Do not mention issue or pull request numbers in code comments or versioned documents.

## Licensing

The project license has not been chosen yet. For anything beyond a small fix, please discuss it in an issue before sending code.
