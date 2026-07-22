---
name: deploy-full
description: Deploy or redeploy full apps and static apps from a local Codex workspace to the user's Docker + Traefik VPS. Use when Codex needs to publish, redeploy, or diagnose a project using local deploy.env, Dockerfile.deploy generation, /compose, /compose/volume, /compose/script, Docker Compose, Traefik labels, and optional persistent mounts.
---

# Deploy Full

Use this skill to deploy projects to the VPS while preserving the operational safety checks from `deploy-static` and extending them for runtime apps, generated `Dockerfile.deploy`, and persistent mounts.

## Core Contract

Run the local wrapper from the project root:

```bash
deploy-full-local.sh
```

State is kept in:

```text
./deploy.env
/compose/volume/PROJECT/deploy.env
```

## Deterministic Flow

1. Read local `deploy.env`, if it exists.
2. Detect recommended defaults from the local project.
3. Always show a numbered confirmation of every deploy variable before remote execution.
4. If local `deploy.env` exists, show the values read from it and let the user confirm or edit by item number.
5. If local `deploy.env` does not exist, show every required deploy variable with detected defaults where available and let the user fill or edit them.
6. Send the confirmed values to the remote script.
7. Remote script validates remote state before mutating anything.
8. If local and remote state diverge, stop and report; never auto-repair.
9. If state is consistent, clone or update the repo, generate `Dockerfile.deploy`, generate Compose, and run `docker compose`.
10. After success, sync remote `deploy.env` back into the project root.

## Variables

Required infra variables:

```env
PROJECT_NAME=
DOMAIN=
REPO_URL=
BRANCH=
TRAEFIK_NETWORK=
CERT_RESOLVER=
```

Technical variables collected on first configuration and then reused automatically:

```env
DEPLOY_STRATEGY=static|runtime
RUNTIME=node|python|custom
INSTALL_COMMAND=
BUILD_COMMAND=
START_COMMAND=
DIST_DIR=
INTERNAL_PORT=
PERSISTENT_MOUNTS=
```

`PERSISTENT_MOUNTS` uses:

```text
subdir:/app/path,other-subdir:/app/other-path
```

Each `subdir` is resolved under:

```text
/compose/volume/PROJECT_NAME/
```

## Safety Rules

- Never delete `/compose/volume/PROJECT` automatically.
- Never expose public `ports` directly in Compose.
- Never overwrite unmanaged `Dockerfile.deploy` or Compose files without explicit force flags.
- Always back up managed files before rewriting them.
- Always stop on local/remote divergence.
- Treat detected mounts as suggestions on first configuration; let the user confirm or edit them.

## Resources

- `deploy-full-local.sh`: local wrapper. Run from the project root.
- `deploy-full.sh`: remote deploy/redeploy script. Install on the VPS.
- `deploy-full-template.yml`: Compose template stored next to `deploy-full.sh`.

Install on the VPS with:

```bash
scp deploy-full.sh deploy-full-template.yml contabo-vps:/compose/script/
ssh contabo-vps 'chmod +x /compose/script/deploy-full.sh'
```

## Expected Result

A successful deploy creates or updates:

- `./deploy.env`
- `/compose/PROJECT.yml`
- `/compose/volume/PROJECT`
- `/compose/volume/PROJECT/deploy.env`
- `/compose/volume/PROJECT/repo`
- `/compose/volume/PROJECT/repo/Dockerfile.deploy`
- `/compose/volume/PROJECT/.deploy/backups`

Use `--dry-run` on the local wrapper to inspect the generated plan without changing local or remote state.
