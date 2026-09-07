# Full Deploy VPS

An agnostic skill for automating production deployments to VPS environments with Docker + Traefik.

It is designed to make web application publishing more deterministic, clean, secure, and fast, while adapting to different stacks, dependencies, and project architectures.

## What It Does

- Deploys static and dynamic applications to a VPS.
- Adapts the deployment flow to the technical profile of the project.
- Supports different runtimes, dependencies, and application structures.
- Generates an immutable deployment plan before making changes.
- Pins the exact source commit that will be deployed.
- Synchronizes the local `.env` file with the VPS without exposing secrets.
- Builds and validates an isolated candidate container before promoting it to production.
- Uses Docker + Traefik for build, routing, TLS, and public exposure.
- Automatically rolls back if the public health check fails.

## Philosophy

Deployments should not depend on luck, memory, or fragile manual steps.

Full Deploy VPS turns remote publishing into a reproducible process: plan, confirm, validate, activate, and verify. Only after passing this flow does the new version reach production.

## Flow

1. The skill detects the application profile.
2. It generates a deployment plan with a confirmation hash.
3. The user explicitly confirms the plan.
4. The code is cloned at the pinned commit.
5. The build runs in a controlled environment.
6. An isolated candidate container is validated.
7. The release is promoted to production.
8. The public domain is verified.
9. If validation fails, the previous version is restored.

## Goal

Reduce operational friction, prevent inconsistent deployments, and bring predictability to the development cycle through a robust automation layer for publishing real applications to remote environments.
