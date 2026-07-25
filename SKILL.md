---
name: deploy-full
description: Deploy static sites, single HTTP runtime applications, and Vite/React + FastAPI hybrid apps from a local Codex workspace to a Docker + Traefik VPS, using an immutable confirmed plan, fixed source commit, isolated candidate validation, and rollback on failed public health checks.
---

# Deploy Full

Use this skill for Docker + Traefik deployments to the VPS. It supports static sites, Node runtime apps, Python runtime apps, and hybrid Vite/React + FastAPI apps, but it never guesses when the project cannot be classified safely.

## Mandatory two-step contract

Run the local wrapper from the project root.

```bash
deploy-full-local.sh --plan
```

Present the complete plan and its `HASH DO PLANO` in the chat. Then stop and wait for the user’s explicit confirmation in the chat. Do not answer an interactive terminal prompt, press Enter automatically, use input redirection, or use `--yes`.

Only after confirmation, run exactly the command printed by the wrapper:

```bash
deploy-full-local.sh --confirmed-plan-hash HASH
```

The printed command includes the complete resolved configuration, the fixed Git commit, the selected force flags, and the remote-state fingerprint captured during planning. Execute that exact command after confirmation; do not reconstruct it from `deploy.env`. The remote verifies that the fingerprint is unchanged immediately before mutation.

`--plan` and `--print-config-json` are read-only. They resolve the Git commit and retrieve a remote fingerprint over SSH, but they never clone, create directories or networks, generate files, write `deploy.env`, build images, or run Compose. `--offline` is allowed only with a plan and can never be applied.

## Profile detection and acceptance

Detection is a proposal only. The final profile is proven by the candidate build:

- Plain HTML: static, with `DIST_DIR=.`; no install command is required.
- Vite with no runtime/SSR signal: static, with `DIST_DIR=dist`; the candidate must contain `dist/index.html`. Vite with a start script or SSR signal is proposed as runtime, because Vite itself supports SSR.
- Next/Vinext with `output: "export"`: static, with `DIST_DIR=out`.
- Next/Vinext without static export: Node runtime, normally port 3000.
- Node with a start script: runtime; confirm its command and listening port.
- Python: runtime; confirm its command and listening port.
- Vite/React + FastAPI: runtime with `RUNTIME=python-fastapi`, normally port 8000. Build the frontend with Node and run the final app as Python/ASGI. If the project already has a reviewed multi-stage `Dockerfile.deploy`, use `DOCKERFILE_SOURCE=project`; otherwise use the generated hybrid Dockerfile.
- Unknown: block and ask the user to choose the profile and technical values.

For static deployments, the Docker build fails unless the selected public root contains `index.html`; the generated Nginx image clears its default HTML before copying the artifact. For runtime deployments, the candidate receives `PORT` and `HOST=0.0.0.0`, and must answer HTTP on the confirmed port.

## Variables

Required infrastructure variables:

```env
PROJECT_NAME=
DOMAIN=
REPO_URL=
BRANCH=
TRAEFIK_NETWORK=
CERT_RESOLVER=
```

Technical variables:

```env
DEPLOY_STRATEGY=static|runtime
RUNTIME=node|python|python-fastapi|custom
INSTALL_COMMAND=
BUILD_COMMAND=
START_COMMAND=
DIST_DIR=
INTERNAL_PORT=
PERSISTENT_MOUNTS=
APP_ENV_FILE=
DOCKERFILE_SOURCE=generated|project
```

`PERSISTENT_MOUNTS` uses `subdir:/app/path,other-subdir:/app/other-path`. For compatibility, a single absolute container path such as `/app/data` is normalized in the plan to `data:/app/data`; the normalized value is what enters the confirmed hash. The plan must show both the base directory `/compose/volume/PROJECT_NAME` and every host/container mount. Mount paths are checked for existence and writability during application.

`APP_ENV_FILE` is optional and must already exist below `/compose/volume/PROJECT_NAME`, with mode `0600` or stricter. Do not put secrets in `deploy.env`, command-line arguments, plans, or chat. When `.env.example` exists, the plan may display its variable names only.

`DOCKERFILE_SOURCE=generated` means the skill writes the candidate `Dockerfile.deploy`. `DOCKERFILE_SOURCE=project` means the candidate uses the `Dockerfile.deploy` from the fixed Git commit. Use project source for reviewed hybrid apps whose Dockerfile already expresses the correct multi-stage build, for example Node/Vite frontend build plus Python/FastAPI runtime.

## Deployment transaction

1. The remote executor verifies the confirmed plan hash and a fingerprint containing `deploy.env`, Compose, active repo commit, and active container image.
2. It clones the fixed commit into `/compose/volume/PROJECT/.deploy/candidate/repo`.
3. It generates `Dockerfile.deploy` or reuses the project's reviewed `Dockerfile.deploy` according to `DOCKERFILE_SOURCE`, and manages only the Docker-supported `Dockerfile.deploy.dockerignore` inside the candidate when needed. It never rewrites the project’s `.dockerignore`.
4. It validates the candidate Compose file, builds it, and starts an isolated candidate container on a private Docker network, without production mounts or runtime secret files.
5. The candidate must respond over HTTP on `INTERNAL_PORT`; a static response must not be the default Nginx page.
6. Only then does it replace the active repository/Compose definition and start the verified image.
7. It tests `https://DOMAIN/` through real DNS with normal TLS validation. If that test fails, it restores the prior repository and Compose definition.
8. It writes `/compose/volume/PROJECT/deploy.env` only after the public health check succeeds, then synchronizes it back to the local project.

Never delete `/compose/volume/PROJECT` automatically. Releases use an image tag containing both commit and plan ID, so a rollback never relies on a mutable tag. Managed Compose and Dockerfile files are backed up before replacement. An unmanaged existing file blocks the deployment unless the user has explicitly reviewed it and used the corresponding force flag.

## Resources

- `deploy-full-local.sh`: local read-only planning and confirmed-plan wrapper.
- `deploy-full.sh`: remote candidate-build, validation, activation, and rollback executor.
- `deploy-full-template.yml`: managed Compose template.

Install or update the remote resources deliberately:

```bash
scp deploy-full.sh deploy-full-template.yml contabo-vps:/compose/script/
ssh contabo-vps 'chmod +x /compose/script/deploy-full.sh'
```

## Acceptance criteria

- A plan never changes local or remote state, and it fixes both source commit and remote-state fingerprint.
- No static site can deploy without its requested `index.html`.
- No runtime app, including `python-fastapi`, is successful unless it serves HTTP on the confirmed internal port.
- No configuration change occurs without a plan hash confirmed in chat.
- No deployment is successful until the public Traefik route responds with valid DNS/TLS; a failed public check rolls back the active release.
