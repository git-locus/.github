# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

- Use GitHub's **private vulnerability reporting** ("Report a vulnerability" in the Security tab of the repository), or
- write to **security@locus.now**.

Include what you found, how to reproduce it, the affected repository, endpoint or page, and the impact you expect. Proof of concept code is welcome. Please do not include real personal data of other people.

We aim to acknowledge a report within 5 days and to keep you updated until it is fixed. We will credit you in the fix if you wish.

## Scope

In scope:

- the production site at `locus.now` and its API under `/api/`
- the code in the `git-locus` repositories: `api`, `client`, `.github`

Out of scope:

- denial of service, volumetric attacks and anything that degrades the service for other people
- social engineering, phishing and physical attacks
- automated scanner output without a demonstrated impact
- findings in third party services we use, unless our configuration is what makes them exploitable

## Good faith

If you act in good faith, limit yourself to your own test accounts, do not access or change other people's data, and give us reasonable time to fix the problem before disclosing it, we will not take legal action against you.

## Supported versions

Only what is currently deployed from the `main` branch is supported. Fixes are shipped there.
