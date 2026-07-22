#!/usr/bin/env bash
set -Eeuo pipefail

SERVER_IP="185.215.165.130"
COMPOSE_DIR="/compose"
VOLUME_ROOT="/compose/volume"
SKILL_ID="full-deploy-skill"
SKILL_VERSION="v3"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${DEPLOY_FULL_TEMPLATE:-$SCRIPT_DIR/deploy-full-template.yml}"
CURL_IMAGE="${DEPLOY_FULL_CURL_IMAGE:-curlimages/curl:8.11.1}"

APPLY=false
STATE_HASH_MODE=false
FORCE_YML=false
FORCE_DOCKERFILE=false
CONFIRMED_PLAN_HASH=""
EXPECTED_REMOTE_STATE_HASH=""
PROJECT_NAME=""
DOMAIN=""
REPO_URL=""
BRANCH=""
TRAEFIK_NETWORK=""
CERT_RESOLVER=""
DEPLOY_STRATEGY=""
RUNTIME=""
INSTALL_COMMAND=""
BUILD_COMMAND=""
START_COMMAND=""
DIST_DIR=""
INTERNAL_PORT=""
PERSISTENT_MOUNTS=""
APP_ENV_FILE=""
PACKAGE_MANAGER=""
SOURCE_COMMIT=""

log() { printf '\n\033[1;34m[DEPLOY]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatorio nao encontrado: $1"; }
shell_quote() { printf '%q' "$1"; }
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
sha256_stdin() { if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
app_dir_for_project() { printf '%s/%s' "$VOLUME_ROOT" "$1"; }

usage() {
  cat <<'EOF'
Uso interno da skill:
  ./deploy-full.sh --state-hash --project NOME
  ./deploy-full.sh --apply --confirmed-plan-hash HASH --expected-remote-state-hash HASH ...
Os modos --yes, --dry-run e --redetect foram removidos. Use o wrapper local.
EOF
}

validate_project_name() { [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "PROJECT_NAME invalido."; }
validate_port() { [[ "$INTERNAL_PORT" =~ ^([1-9][0-9]{0,4})$ ]] && (( INTERNAL_PORT <= 65535 )) || fail "INTERNAL_PORT deve estar entre 1 e 65535."; }
validate_mounts() {
  [[ -z "$PERSISTENT_MOUNTS" ]] && return 0
  [[ "$PERSISTENT_MOUNTS" =~ ^[A-Za-z0-9._-]+:/[A-Za-z0-9._/-]+(,[A-Za-z0-9._-]+:/[A-Za-z0-9._/-]+)*$ && "$PERSISTENT_MOUNTS" != *..* ]] || fail "PERSISTENT_MOUNTS invalido."
}
validate_config() {
  validate_project_name
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ && -n "$REPO_URL" && -n "$BRANCH" && -n "$TRAEFIK_NETWORK" && -n "$CERT_RESOLVER" ]] || fail "Configuracao de infraestrutura invalida."
  [[ "$DEPLOY_STRATEGY" =~ ^(static|runtime)$ ]] || fail "DEPLOY_STRATEGY deve ser static ou runtime."
  [[ "$RUNTIME" =~ ^(node|python|custom)$ ]] || fail "RUNTIME invalido."
  validate_port
  [[ "$DEPLOY_STRATEGY" != runtime || -n "$START_COMMAND" ]] || fail "START_COMMAND e obrigatorio para runtime."
  [[ "$DEPLOY_STRATEGY" != static || -n "$DIST_DIR" ]] || fail "DIST_DIR e obrigatorio para static."
  [[ "$DIST_DIR" != /* && "$DIST_DIR" != *..* ]] || fail "DIST_DIR deve ser relativo e sem '..'."
  validate_mounts
}
remote_state_hash() {
  local app state compose repo
  app="$(app_dir_for_project "$PROJECT_NAME")"
  state="$app/deploy.env"
  compose="$COMPOSE_DIR/$PROJECT_NAME.yml"
  repo="$app/repo"
  {
    printf 'deploy_env=%s\n' "$( [[ -f "$state" ]] && sha256_file "$state" || printf absent )"
    printf 'compose=%s\n' "$( [[ -f "$compose" ]] && sha256_file "$compose" || printf absent )"
    printf 'repo_head=%s\n' "$( [[ -d "$repo/.git" ]] && git -C "$repo" rev-parse HEAD 2>/dev/null || printf absent )"
    printf 'container_image=%s\n' "$( docker inspect "$PROJECT_NAME" --format '{{.Image}}' 2>/dev/null || printf absent )"
  } | sha256_stdin
}
plan_payload() {
  printf 'PROJECT_NAME=%s\nDOMAIN=%s\nREPO_URL=%s\nBRANCH=%s\nTRAEFIK_NETWORK=%s\nCERT_RESOLVER=%s\nDEPLOY_STRATEGY=%s\nRUNTIME=%s\nINSTALL_COMMAND=%s\nBUILD_COMMAND=%s\nSTART_COMMAND=%s\nDIST_DIR=%s\nINTERNAL_PORT=%s\nPERSISTENT_MOUNTS=%s\nAPP_ENV_FILE=%s\nSOURCE_COMMIT=%s\nREMOTE_STATE_HASH=%s\nFORCE_YML=%s\nFORCE_DOCKERFILE=%s\n' \
    "$PROJECT_NAME" "$DOMAIN" "$REPO_URL" "$BRANCH" "$TRAEFIK_NETWORK" "$CERT_RESOLVER" "$DEPLOY_STRATEGY" "$RUNTIME" "$INSTALL_COMMAND" "$BUILD_COMMAND" "$START_COMMAND" "$DIST_DIR" "$INTERNAL_PORT" "$PERSISTENT_MOUNTS" "$APP_ENV_FILE" "$SOURCE_COMMIT" "$EXPECTED_REMOTE_STATE_HASH" "$FORCE_YML" "$FORCE_DOCKERFILE"
}
plan_hash() { plan_payload | sha256_stdin; }

parse_mounts() {
  MOUNT_SUBDIRS=()
  MOUNT_TARGETS=()
  [[ -z "$PERSISTENT_MOUNTS" ]] && return 0
  local item oldifs="$IFS"
  IFS=',' read -ra items <<< "$PERSISTENT_MOUNTS"
  IFS="$oldifs"
  for item in "${items[@]}"; do MOUNT_SUBDIRS+=("${item%%:*}"); MOUNT_TARGETS+=("${item#*:}"); done
}
prepare_mounts() {
  parse_mounts
  local index
  for index in "${!MOUNT_SUBDIRS[@]}"; do
    mkdir -p "$APP_DIR/${MOUNT_SUBDIRS[$index]}"
    [[ -w "$APP_DIR/${MOUNT_SUBDIRS[$index]}" ]] || fail "Mount sem permissao de escrita: $APP_DIR/${MOUNT_SUBDIRS[$index]}"
  done
}
validate_app_env_file() {
  [[ -z "$APP_ENV_FILE" ]] && return 0
  local resolved_app resolved_env mode
  resolved_app="$(realpath -e "$APP_DIR")"; resolved_env="$(realpath -e "$APP_ENV_FILE")"
  [[ "$resolved_env" == "$resolved_app/"* && -f "$resolved_env" ]] || fail "APP_ENV_FILE deve existir sob $APP_DIR, sem symlink externo."
  mode="$(stat -c '%a' "$resolved_env")"
  (( (8#$mode & 8#077) == 0 )) || fail "APP_ENV_FILE nao pode ser legivel, gravavel ou executavel por grupo/outros."
  APP_ENV_FILE="$resolved_env"
}
detect_package_manager() {
  if [[ -f "$CANDIDATE_REPO/pnpm-lock.yaml" ]]; then PACKAGE_MANAGER=pnpm
  elif [[ -f "$CANDIDATE_REPO/yarn.lock" ]]; then PACKAGE_MANAGER=yarn
  elif [[ -f "$CANDIDATE_REPO/package-lock.json" ]]; then PACKAGE_MANAGER=npm
  elif [[ -f "$CANDIDATE_REPO/requirements.txt" ]]; then PACKAGE_MANAGER=pip
  else PACKAGE_MANAGER=custom; fi
}
generate_dockerignore() {
  cat > "$CANDIDATE_REPO/Dockerfile.deploy.dockerignore" <<'EOF'
node_modules
.git
dist
out
.next
.cache
.vite
__pycache__
*.pyc
.venv
.DS_Store
EOF
}
docker_base_image() { case "$RUNTIME" in node) printf node:22-alpine;; python) printf python:3.12-slim;; custom) printf debian:bookworm-slim;; esac; }
generate_dockerfile() {
  local base
  base="$(docker_base_image)"
  if [[ "$DEPLOY_STRATEGY" == static ]]; then
    cat > "$CANDIDATE_REPO/Dockerfile.deploy" <<EOF
# managed-by: $SKILL_ID
# version: $SKILL_VERSION
FROM $base AS builder
WORKDIR /app
COPY . .
$( [[ -n "$INSTALL_COMMAND" ]] && printf 'RUN %s\n' "$INSTALL_COMMAND" )
$( [[ -n "$BUILD_COMMAND" ]] && printf 'RUN %s\n' "$BUILD_COMMAND" )
RUN test -f "/app/$DIST_DIR/index.html" || (echo "ERRO: o artefato estatico deve conter $DIST_DIR/index.html" && exit 1)
FROM nginx:1.27-alpine
RUN rm -f /etc/nginx/conf.d/default.conf && rm -rf /usr/share/nginx/html/* && cat > /etc/nginx/conf.d/default.conf <<'NGINX'
server {
  listen $INTERNAL_PORT;
  server_name _;
  root /usr/share/nginx/html;
  index index.html;
  location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
COPY --from=builder /app/$DIST_DIR/ /usr/share/nginx/html/
EXPOSE $INTERNAL_PORT
CMD ["nginx", "-g", "daemon off;"]
EOF
  else
    cat > "$CANDIDATE_REPO/Dockerfile.deploy" <<EOF
# managed-by: $SKILL_ID
# version: $SKILL_VERSION
FROM $base
WORKDIR /app
COPY . .
$( [[ -n "$INSTALL_COMMAND" ]] && printf 'RUN %s\n' "$INSTALL_COMMAND" )
$( [[ -n "$BUILD_COMMAND" ]] && printf 'RUN %s\n' "$BUILD_COMMAND" )
ENV PORT=$INTERNAL_PORT
ENV HOST=0.0.0.0
EXPOSE $INTERNAL_PORT
CMD $START_COMMAND
EOF
  fi
}
volumes_block() {
  [[ ${#MOUNT_SUBDIRS[@]} -eq 0 ]] && return 0
  printf '    volumes:\n'
  local index
  for index in "${!MOUNT_SUBDIRS[@]}"; do printf '      - %s/%s:%s\n' "$APP_DIR" "${MOUNT_SUBDIRS[$index]}" "${MOUNT_TARGETS[$index]}"; done
}
env_file_block() { [[ -n "$APP_ENV_FILE" ]] && printf '    env_file:\n      - %s\n' "$APP_ENV_FILE"; }
generate_compose() {
  local target="$1" repo="$2" content volumes envblock
  volumes="$(volumes_block)"
  envblock="$(env_file_block)"
  content="$(< "$TEMPLATE_FILE")"
  content="${content//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}"
  content="${content//\{\{DOMAIN\}\}/$DOMAIN}"
  content="${content//\{\{IMAGE_NAME\}\}/$IMAGE_NAME}"
  content="${content//\{\{TRAEFIK_NETWORK\}\}/$TRAEFIK_NETWORK}"
  content="${content//\{\{CERT_RESOLVER\}\}/$CERT_RESOLVER}"
  content="${content//\{\{INTERNAL_PORT\}\}/$INTERNAL_PORT}"
  content="${content//\{\{REPO_DIR\}\}/$repo}"
  content="${content//\{\{VOLUMES_BLOCK\}\}/$volumes}"
  content="${content//\{\{ENV_FILE_BLOCK\}\}/$envblock}"
  printf '%s\n' "$content" > "$target"
}
write_deploy_env() {
  local target="$APP_DIR/deploy.env" now
  now="$(date -Iseconds)"
  {
    echo "# managed-by: $SKILL_ID"
    echo "# version: $SKILL_VERSION"
    for key in PROJECT_NAME DOMAIN REPO_URL BRANCH TRAEFIK_NETWORK CERT_RESOLVER DEPLOY_STRATEGY RUNTIME INSTALL_COMMAND BUILD_COMMAND START_COMMAND DIST_DIR INTERNAL_PORT PERSISTENT_MOUNTS APP_ENV_FILE; do echo "$key=$(shell_quote "${!key}")"; done
    echo "PACKAGE_MANAGER=$(shell_quote "$PACKAGE_MANAGER")"
    echo "IMAGE_NAME=$(shell_quote "$IMAGE_NAME")"
    echo "LAST_DEPLOY_AT=$(shell_quote "$now")"
  } > "$target"
}
assert_managed_or_forced() {
  local file="$1" label="$2" force="$3"
  [[ -f "$file" ]] || return 0
  grep -q "managed-by: $SKILL_ID" "$file" || [[ "$force" == true ]] || fail "$label nao gerenciado. Use a flag --force correspondente apos revisao."
}
clone_candidate() {
  rm -rf "$CANDIDATE_DIR"
  mkdir -p "$CANDIDATE_DIR"
  log "Clonando candidato isolado no commit $SOURCE_COMMIT..."
  git clone --no-checkout "$REPO_URL" "$CANDIDATE_REPO"
  git -C "$CANDIDATE_REPO" checkout --detach "$SOURCE_COMMIT"
  [[ "$(git -C "$CANDIDATE_REPO" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "O repositorio nao resolveu o commit confirmado."
}
candidate_args() {
  local index
  for index in "${!MOUNT_SUBDIRS[@]}"; do printf '%q ' -v "$APP_DIR/${MOUNT_SUBDIRS[$index]}:${MOUNT_TARGETS[$index]}"; done
}
healthcheck_candidate() {
  local container="$PROJECT_NAME-candidate-${PLAN_HASH:0:12}" alias="candidate-$PROJECT_NAME" network="$PROJECT_NAME-candidate-net-${PLAN_HASH:0:8}" body="" attempt
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker network create --internal "$network" >/dev/null
  # shellcheck disable=SC2046
  docker run -d --rm --name "$container" --network "$network" --network-alias "$alias" "$IMAGE_NAME" >/dev/null
  for attempt in {1..15}; do
    if body="$(docker run --rm --network "$network" "$CURL_IMAGE" --fail --silent --show-error --max-time 5 "http://$alias:$INTERNAL_PORT/" 2>/dev/null)"; then
      if [[ "$DEPLOY_STRATEGY" != static || "$body" != *'Welcome to nginx!'* ]]; then docker rm -f "$container" >/dev/null; docker network rm "$network" >/dev/null; ok "Candidato respondeu HTTP na porta $INTERNAL_PORT."; return 0; fi
    fi
    sleep 2
  done
  docker logs "$container" 2>/dev/null || true
  docker rm -f "$container" >/dev/null 2>&1 || true; docker network rm "$network" >/dev/null 2>&1 || true
  fail "O candidato nao respondeu HTTP na porta confirmada."
}
PREVIOUS_REPO=""
PREVIOUS_COMPOSE=""
ACTIVATED=false
HAD_PREVIOUS_RELEASE=false
ROLLING_BACK=false
rollback() {
  [[ "$ACTIVATED" == true && "$ROLLING_BACK" == false ]] || return 0
  ROLLING_BACK=true
  log "Falha apos ativacao; restaurando versao anterior."
  [[ -n "$PREVIOUS_COMPOSE" && -f "$PREVIOUS_COMPOSE" ]] && cp -a "$PREVIOUS_COMPOSE" "$COMPOSE_FILE"
  if [[ -n "$PREVIOUS_REPO" && -d "$PREVIOUS_REPO" ]]; then mv "$REPO_DIR" "$CANDIDATE_DIR/rejected-repo" 2>/dev/null || true; mv "$PREVIOUS_REPO" "$REPO_DIR"; fi
  if [[ "$HAD_PREVIOUS_RELEASE" == true ]]; then docker compose -f "$COMPOSE_FILE" up -d --no-build --force-recreate || true; else docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true; rm -f "$COMPOSE_FILE"; fi
  ACTIVATED=false
}
on_exit() { local status="$?"; if [[ "$status" -ne 0 ]]; then rollback || true; fi; exit "$status"; }
healthcheck_public() {
  local body attempt
  for attempt in {1..15}; do
    if body="$(curl --fail --silent --show-error --max-time 8 "https://$DOMAIN/" 2>/dev/null)"; then
      [[ "$DEPLOY_STRATEGY" != static || "$body" != *'Welcome to nginx!'* ]] && return 0
    fi
    sleep 2
  done
  return 1
}
activate_release() {
  assert_managed_or_forced "$COMPOSE_FILE" Compose "$FORCE_YML"
  assert_managed_or_forced "$REPO_DIR/Dockerfile.deploy" Dockerfile.deploy "$FORCE_DOCKERFILE"
  mkdir -p "$BACKUPS_DIR" "$DEPLOY_DIR/releases"
  if [[ -f "$COMPOSE_FILE" ]]; then HAD_PREVIOUS_RELEASE=true; PREVIOUS_COMPOSE="$BACKUPS_DIR/$(basename "$COMPOSE_FILE").$(date +%Y%m%d-%H%M%S).bak"; cp -a "$COMPOSE_FILE" "$PREVIOUS_COMPOSE"; fi
  if [[ -d "$REPO_DIR" ]]; then PREVIOUS_REPO="$DEPLOY_DIR/releases/repo-$(date +%Y%m%d-%H%M%S)"; mv "$REPO_DIR" "$PREVIOUS_REPO"; fi
  mv "$CANDIDATE_REPO" "$REPO_DIR"
  generate_compose "$COMPOSE_FILE" "$REPO_DIR"
  docker compose -f "$COMPOSE_FILE" config >/dev/null
  ACTIVATED=true
  docker compose -f "$COMPOSE_FILE" up -d --no-build --force-recreate
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-hash) STATE_HASH_MODE=true; shift;;
    --apply) APPLY=true; shift;;
    --confirmed-plan-hash) CONFIRMED_PLAN_HASH="${2:-}"; shift 2;;
    --expected-remote-state-hash) EXPECTED_REMOTE_STATE_HASH="${2:-}"; shift 2;; --source-commit) SOURCE_COMMIT="${2:-}"; shift 2;;
    --project) PROJECT_NAME="${2:-}"; shift 2;;
    --domain) DOMAIN="${2:-}"; shift 2;;
    --repo-url|--repo) REPO_URL="${2:-}"; shift 2;;
    --branch) BRANCH="${2:-}"; shift 2;;
    --traefik-network|--network) TRAEFIK_NETWORK="${2:-}"; shift 2;;
    --cert-resolver|--certresolver) CERT_RESOLVER="${2:-}"; shift 2;;
    --deploy-strategy|--strategy) DEPLOY_STRATEGY="${2:-}"; shift 2;;
    --runtime) RUNTIME="${2:-}"; shift 2;;
    --install-command|--install) INSTALL_COMMAND="${2:-}"; shift 2;;
    --build-command|--build) BUILD_COMMAND="${2:-}"; shift 2;;
    --start-command|--start) START_COMMAND="${2:-}"; shift 2;;
    --dist-dir|--dist) DIST_DIR="${2:-}"; shift 2;;
    --internal-port) INTERNAL_PORT="${2:-}"; shift 2;;
    --persistent-mounts|--mounts) PERSISTENT_MOUNTS="${2:-}"; shift 2;;
    --app-env-file) APP_ENV_FILE="${2:-}"; shift 2;;
    --force-yml) FORCE_YML=true; shift;;
    --force-dockerfile) FORCE_DOCKERFILE=true; shift;;
    --yes|-y|--dry-run|--redetect) fail "$1 foi removido. Use --plan e o hash confirmado.";;
    --help|-h) usage; exit 0;;
    *) fail "Opcao desconhecida: $1";;
  esac
done
validate_project_name
if [[ "$STATE_HASH_MODE" == true ]]; then [[ "$APPLY" == false ]] || fail "--state-hash nao pode aplicar."; printf 'REMOTE_STATE_HASH=%s\n' "$(remote_state_hash)"; exit 0; fi
[[ "$APPLY" == true && -n "$CONFIRMED_PLAN_HASH" && -n "$EXPECTED_REMOTE_STATE_HASH" ]] || fail "Aplicacao exige hash de plano e hash de estado remoto."
validate_config
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "SOURCE_COMMIT invalido."
PLAN_HASH="$(plan_hash)"
[[ "$PLAN_HASH" == "$CONFIRMED_PLAN_HASH" ]] || fail "O hash nao corresponde aos parametros recebidos."
APP_DIR="$(app_dir_for_project "$PROJECT_NAME")"
REPO_DIR="$APP_DIR/repo"
DEPLOY_DIR="$APP_DIR/.deploy"
BACKUPS_DIR="$DEPLOY_DIR/backups"
CANDIDATE_DIR="$DEPLOY_DIR/candidate"
CANDIDATE_REPO="$CANDIDATE_DIR/repo"
COMPOSE_FILE="$COMPOSE_DIR/$PROJECT_NAME.yml"
[[ "$(remote_state_hash)" == "$EXPECTED_REMOTE_STATE_HASH" ]] || fail "O estado remoto mudou depois da confirmacao. Gere novo plano."
require_command docker
require_command git
require_command curl
[[ -f "$TEMPLATE_FILE" ]] || fail "Template Compose ausente."
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin nao encontrado."
trap on_exit EXIT
docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1 || docker network create "$TRAEFIK_NETWORK" >/dev/null
mkdir -p "$APP_DIR" "$DEPLOY_DIR" "$BACKUPS_DIR"
prepare_mounts
validate_app_env_file
clone_candidate
detect_package_manager
generate_dockerignore
generate_dockerfile
IMAGE_NAME="local/$PROJECT_NAME:${SOURCE_COMMIT:0:12}-${PLAN_HASH:0:12}"
generate_compose "$CANDIDATE_DIR/$PROJECT_NAME.yml" "$CANDIDATE_REPO"
docker compose -f "$CANDIDATE_DIR/$PROJECT_NAME.yml" config >/dev/null
log "Construindo e verificando candidato isolado..."
docker build --pull -f "$CANDIDATE_REPO/Dockerfile.deploy" -t "$IMAGE_NAME" "$CANDIDATE_REPO"
healthcheck_candidate
activate_release
if ! healthcheck_public; then rollback; fail "O dominio nao passou na verificacao publica; a versao anterior foi restaurada."; fi
write_deploy_env
ok "Deploy concluido: conteudo valido no container e no dominio publico."
