#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="deploy.env"
SSH_TARGET="${DEPLOY_FULL_SSH_TARGET:-contabo-vps}"
REMOTE_SCRIPT_DIR="${DEPLOY_FULL_REMOTE_SCRIPT_DIR:-/compose/script}"
SSH_BIN="${DEPLOY_FULL_SSH_BIN:-ssh.exe}"
SCP_BIN="${DEPLOY_FULL_SCP_BIN:-scp.exe}"
YES="false"
DRY_RUN="false"
REDETECT="false"
FORCE_YML="false"
FORCE_DOCKERFILE="false"
ENV_FILE_EXISTS="false"

PROJECT_NAME=""
DOMAIN=""
REPO_URL=""
BRANCH=""
TRAEFIK_NETWORK=""
CERT_RESOLVER=""
INTERNAL_PORT=""
INSTALL_COMMAND=""
BUILD_COMMAND=""
START_COMMAND=""
DIST_DIR=""
DEPLOY_STRATEGY=""
RUNTIME=""
PERSISTENT_MOUNTS=""

DETECTED_PROJECT_NAME=""
DETECTED_REPO_URL=""
DETECTED_BRANCH=""
DETECTED_TRAEFIK_NETWORK="traknet"
DETECTED_CERT_RESOLVER="le"
DETECTED_INTERNAL_PORT=""
DETECTED_INSTALL_COMMAND=""
DETECTED_BUILD_COMMAND=""
DETECTED_START_COMMAND=""
DETECTED_DIST_DIR=""
DETECTED_DEPLOY_STRATEGY=""
DETECTED_RUNTIME=""
DETECTED_PERSISTENT_MOUNTS=""

log() {
  printf "\n\033[1;34m[LOCAL]\033[0m %s\n" "$*"
}

fail() {
  printf "\n\033[1;31m[LOCAL ERRO]\033[0m %s\n" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso:

  ./deploy-full-local.sh [opcoes]

Fluxo:

  1. Le ./deploy.env na raiz do projeto local, se existir.
  2. Detecta defaults de deploy a partir do projeto local.
  3. Sempre mostra uma revisao numerada das variaveis para confirmar ou editar.
  4. Executa /compose/script/deploy-full.sh no VPS.
  5. Baixa o deploy.env remoto para a pasta local apos sucesso.

Opcoes:

  --env-file ARQUIVO          Arquivo local de estado. Padrao: deploy.env
  --ssh-target ALVO           Alias/host SSH. Padrao: contabo-vps
  --remote-dir DIR            Pasta do script remoto. Padrao: /compose/script
  --project NOME              PROJECT_NAME
  --domain DOMINIO            DOMAIN
  --repo REPO_URL             REPO_URL
  --branch BRANCH             BRANCH
  --network NOME              TRAEFIK_NETWORK. Padrao remoto: traknet
  --certresolver NOME         CERT_RESOLVER. Padrao remoto: le
  --internal-port PORTA       INTERNAL_PORT
  --strategy TIPO             DEPLOY_STRATEGY: static|runtime
  --runtime TIPO              RUNTIME: node|python|custom
  --install "COMANDO"         INSTALL_COMMAND
  --build "COMANDO"           BUILD_COMMAND
  --start "COMANDO"           START_COMMAND
  --dist PASTA                DIST_DIR
  --mounts LISTA              PERSISTENT_MOUNTS no formato subdir:/app/path,...
  --redetect                  Redetecta defaults locais
  --force-yml                 Permite sobrescrever Compose nao gerenciado
  --force-dockerfile          Permite sobrescrever Dockerfile nao gerenciado
  --yes                       Nao pergunta; usa valores salvos/detectados e falha se faltar variavel obrigatoria
  --dry-run                   Mostra plano sem mutar remoto nem local
  --help                      Mostra esta ajuda

EOF
}

decode_env_value() {
  local value="$1"
  local out=""
  local i ch

  if [[ "$value" == \$\'* ]]; then
    fail "Formato de valor nao suportado em $ENV_FILE: $value"
  fi

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  for ((i = 0; i < ${#value}; i++)); do
    ch="${value:i:1}"
    if [[ "$ch" == "\\" && $((i + 1)) -lt ${#value} ]]; then
      i=$((i + 1))
      out+="${value:i:1}"
    else
      out+="$ch"
    fi
  done

  printf "%s" "$out"
}

set_if_empty() {
  local key="$1"
  local value="$2"
  local current="${!key:-}"

  if [[ -z "$current" ]]; then
    printf -v "$key" "%s" "$value"
  fi
}

load_local_env() {
  local line key raw_value decoded_value

  [[ -f "$ENV_FILE" ]] || return 0

  log "deploy.env local encontrado: $ENV_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"
    decoded_value="$(decode_env_value "$raw_value")"

    case "$key" in
      PROJECT_NAME|DOMAIN|REPO_URL|BRANCH|TRAEFIK_NETWORK|CERT_RESOLVER|INTERNAL_PORT|INSTALL_COMMAND|BUILD_COMMAND|START_COMMAND|DIST_DIR|DEPLOY_STRATEGY|RUNTIME|PERSISTENT_MOUNTS)
        set_if_empty "$key" "$decoded_value"
        ;;
    esac
  done < "$ENV_FILE"
}

git_default_repo() {
  git remote get-url origin 2>/dev/null || true
}

git_default_branch() {
  git branch --show-current 2>/dev/null || true
}

default_project_name() {
  basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-'
}

package_has_script() {
  local script_name="$1"
  [[ -f package.json ]] || return 1
  grep -Eq "\"$script_name\"[[:space:]]*:" package.json
}

detect_install_defaults() {
  if [[ -f pnpm-lock.yaml ]]; then
    DETECTED_RUNTIME="node"
    DETECTED_INSTALL_COMMAND="corepack enable && pnpm install --frozen-lockfile"
  elif [[ -f yarn.lock ]]; then
    DETECTED_RUNTIME="node"
    DETECTED_INSTALL_COMMAND="corepack enable && yarn install --frozen-lockfile"
  elif [[ -f package-lock.json ]]; then
    DETECTED_RUNTIME="node"
    DETECTED_INSTALL_COMMAND="npm ci"
  elif [[ -f package.json ]]; then
    DETECTED_RUNTIME="node"
    DETECTED_INSTALL_COMMAND="npm install"
  elif [[ -f requirements.txt ]]; then
    DETECTED_RUNTIME="python"
    DETECTED_INSTALL_COMMAND="pip install -r requirements.txt"
  else
    DETECTED_RUNTIME="custom"
    DETECTED_INSTALL_COMMAND=""
  fi
}

detect_build_defaults() {
  if [[ "$DETECTED_RUNTIME" == "node" ]]; then
    if package_has_script "build"; then
      if [[ -f pnpm-lock.yaml ]]; then
        DETECTED_BUILD_COMMAND="pnpm run build"
      elif [[ -f yarn.lock ]]; then
        DETECTED_BUILD_COMMAND="yarn build"
      else
        DETECTED_BUILD_COMMAND="npm run build"
      fi
    else
      DETECTED_BUILD_COMMAND=""
    fi

    if [[ -f vite.config.ts || -f vite.config.js ]]; then
      DETECTED_DIST_DIR="dist"
    elif grep -Eqi '"next"[[:space:]]*:' package.json 2>/dev/null; then
      DETECTED_DIST_DIR=".next"
    elif grep -Eqi '"react-scripts"[[:space:]]*:' package.json 2>/dev/null; then
      DETECTED_DIST_DIR="build"
    fi
  elif [[ "$DETECTED_RUNTIME" == "python" ]]; then
    DETECTED_BUILD_COMMAND=""
    DETECTED_DIST_DIR=""
  fi
}

detect_start_defaults() {
  if [[ "$DETECTED_RUNTIME" == "node" ]]; then
    if package_has_script "start"; then
      if [[ -f pnpm-lock.yaml ]]; then
        DETECTED_START_COMMAND="pnpm start"
      elif [[ -f yarn.lock ]]; then
        DETECTED_START_COMMAND="yarn start"
      else
        DETECTED_START_COMMAND="npm run start"
      fi
    elif [[ -f server.js ]]; then
      DETECTED_START_COMMAND="node server.js"
    elif [[ -f server/index.js ]]; then
      DETECTED_START_COMMAND="node server/index.js"
    elif [[ -f server/app.js ]]; then
      DETECTED_START_COMMAND="node server/app.js"
    fi
  elif [[ "$DETECTED_RUNTIME" == "python" ]]; then
    if [[ -f main.py ]]; then
      DETECTED_START_COMMAND="uvicorn main:app --host 0.0.0.0 --port 8000"
    elif [[ -f app.py ]]; then
      DETECTED_START_COMMAND="gunicorn app:app --bind 0.0.0.0:8000"
    fi
  fi
}

detect_strategy_defaults() {
  if [[ -n "$DETECTED_START_COMMAND" ]]; then
    DETECTED_DEPLOY_STRATEGY="runtime"
  elif [[ -n "$DETECTED_DIST_DIR" ]]; then
    DETECTED_DEPLOY_STRATEGY="static"
  else
    DETECTED_DEPLOY_STRATEGY="runtime"
  fi

  if [[ "$DETECTED_DEPLOY_STRATEGY" == "static" ]]; then
    DETECTED_INTERNAL_PORT="80"
  elif [[ "$DETECTED_RUNTIME" == "python" ]]; then
    DETECTED_INTERNAL_PORT="8000"
  else
    DETECTED_INTERNAL_PORT="3000"
  fi
}

detect_mount_defaults() {
  local candidates=()
  local dir

  for dir in files uploads data storage media; do
    if [[ -d "$dir" ]]; then
      candidates+=("$dir")
    elif rg -q "(^|/)${dir}/?$" .gitignore 2>/dev/null; then
      candidates+=("$dir")
    fi
  done

  if ((${#candidates[@]} == 0)); then
    DETECTED_PERSISTENT_MOUNTS=""
    return 0
  fi

  local unique=()
  local seen="|"
  for dir in "${candidates[@]}"; do
    if [[ "$seen" != *"|$dir|"* ]]; then
      unique+=("$dir")
      seen+="${dir}|"
    fi
  done

  local mounts=()
  for dir in "${unique[@]}"; do
    mounts+=("${dir}:/app/${dir}")
  done

  local joined=""
  local item
  for item in "${mounts[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=","
    fi
    joined+="$item"
  done

  DETECTED_PERSISTENT_MOUNTS="$joined"
}

detect_local_defaults() {
  DETECTED_PROJECT_NAME="$(default_project_name)"
  DETECTED_REPO_URL="$(git_default_repo)"
  DETECTED_BRANCH="$(git_default_branch)"
  DETECTED_BRANCH="${DETECTED_BRANCH:-main}"
  DETECTED_TRAEFIK_NETWORK="traknet"
  DETECTED_CERT_RESOLVER="le"
  DETECTED_INTERNAL_PORT=""
  DETECTED_INSTALL_COMMAND=""
  DETECTED_BUILD_COMMAND=""
  DETECTED_START_COMMAND=""
  DETECTED_DIST_DIR=""
  DETECTED_DEPLOY_STRATEGY=""
  DETECTED_RUNTIME=""
  DETECTED_PERSISTENT_MOUNTS=""

  detect_install_defaults
  detect_build_defaults
  detect_start_defaults
  detect_strategy_defaults
  detect_mount_defaults
}

ask_required() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-}"

  if [[ "$YES" == "true" ]]; then
    current_value="${current_value:-$default_value}"
    [[ -n "$current_value" ]] || fail "Variavel obrigatoria ausente: $var_name"
    printf -v "$var_name" "%s" "$current_value"
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " current_value
    current_value="${current_value:-${!var_name:-$default_value}}"
  else
    read -r -p "$label: " current_value
    current_value="${current_value:-${!var_name:-}}"
  fi

  [[ -n "$current_value" ]] || fail "$var_name nao pode ficar vazio."
  printf -v "$var_name" "%s" "$current_value"
}

ask_optional() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-}"

  if [[ "$YES" == "true" ]]; then
    current_value="${current_value:-$default_value}"
    printf -v "$var_name" "%s" "$current_value"
    return 0
  fi

  read -r -p "$label [$default_value]: " current_value
  current_value="${current_value:-${!var_name:-$default_value}}"
  printf -v "$var_name" "%s" "$current_value"
}

validate_project_name_value() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

validate_domain_value() {
  local value="$1"
  [[ -n "$value" && "$value" != *"\`"* && "$value" != *" "* ]]
}

validate_strategy_value() {
  [[ "$1" =~ ^(static|runtime)$ ]]
}

validate_runtime_value() {
  [[ "$1" =~ ^(node|python|custom)$ ]]
}

validate_port_value() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

ask_required_validated() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local validator="$4"
  local error_message="$5"

  while true; do
    ask_required "$var_name" "$label" "$default_value"
    if "$validator" "${!var_name}"; then
      return 0
    fi
    [[ "$YES" == "true" ]] && fail "$error_message"
    printf '%s\n' "$error_message" >&2
    printf -v "$var_name" "%s" ""
  done
}

env_is_configured() {
  [[ -n "$PROJECT_NAME" && -n "$DOMAIN" && -n "$REPO_URL" && -n "$BRANCH" && -n "$DEPLOY_STRATEGY" && -n "$RUNTIME" && -n "$INTERNAL_PORT" ]] || return 1

  if [[ "$DEPLOY_STRATEGY" == "runtime" ]]; then
    [[ -n "$START_COMMAND" ]] || return 1
  fi

  if [[ "$DEPLOY_STRATEGY" == "static" ]]; then
    [[ -n "$DIST_DIR" ]] || return 1
  fi

  return 0
}

apply_config_defaults() {
  PROJECT_NAME="${PROJECT_NAME:-$DETECTED_PROJECT_NAME}"
  REPO_URL="${REPO_URL:-$DETECTED_REPO_URL}"
  BRANCH="${BRANCH:-$DETECTED_BRANCH}"
  TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-$DETECTED_TRAEFIK_NETWORK}"
  CERT_RESOLVER="${CERT_RESOLVER:-$DETECTED_CERT_RESOLVER}"
  DEPLOY_STRATEGY="${DEPLOY_STRATEGY:-$DETECTED_DEPLOY_STRATEGY}"
  RUNTIME="${RUNTIME:-$DETECTED_RUNTIME}"
  INSTALL_COMMAND="${INSTALL_COMMAND:-$DETECTED_INSTALL_COMMAND}"
  BUILD_COMMAND="${BUILD_COMMAND:-$DETECTED_BUILD_COMMAND}"
  START_COMMAND="${START_COMMAND:-$DETECTED_START_COMMAND}"
  DIST_DIR="${DIST_DIR:-$DETECTED_DIST_DIR}"
  INTERNAL_PORT="${INTERNAL_PORT:-$DETECTED_INTERNAL_PORT}"
  PERSISTENT_MOUNTS="${PERSISTENT_MOUNTS:-$DETECTED_PERSISTENT_MOUNTS}"
}

config_key_by_number() {
  case "$1" in
    1) printf "PROJECT_NAME" ;;
    2) printf "DOMAIN" ;;
    3) printf "REPO_URL" ;;
    4) printf "BRANCH" ;;
    5) printf "TRAEFIK_NETWORK" ;;
    6) printf "CERT_RESOLVER" ;;
    7) printf "DEPLOY_STRATEGY" ;;
    8) printf "RUNTIME" ;;
    9) printf "INSTALL_COMMAND" ;;
    10) printf "BUILD_COMMAND" ;;
    11) printf "START_COMMAND" ;;
    12) printf "DIST_DIR" ;;
    13) printf "INTERNAL_PORT" ;;
    14) printf "PERSISTENT_MOUNTS" ;;
    *) return 1 ;;
  esac
}

show_config_review() {
  local source_label="valores sugeridos"
  [[ "$ENV_FILE_EXISTS" == "true" ]] && source_label="valores lidos de $ENV_FILE e complementados com defaults"

  log "Confirme as variaveis do deploy ($source_label):"
  printf "  1. PROJECT_NAME=%s\n" "${PROJECT_NAME:-}"
  printf "  2. DOMAIN=%s\n" "${DOMAIN:-}"
  printf "  3. REPO_URL=%s\n" "${REPO_URL:-}"
  printf "  4. BRANCH=%s\n" "${BRANCH:-}"
  printf "  5. TRAEFIK_NETWORK=%s\n" "${TRAEFIK_NETWORK:-}"
  printf "  6. CERT_RESOLVER=%s\n" "${CERT_RESOLVER:-}"
  printf "  7. DEPLOY_STRATEGY=%s\n" "${DEPLOY_STRATEGY:-}"
  printf "  8. RUNTIME=%s\n" "${RUNTIME:-}"
  printf "  9. INSTALL_COMMAND=%s\n" "${INSTALL_COMMAND:-}"
  printf "  10. BUILD_COMMAND=%s\n" "${BUILD_COMMAND:-}"
  printf "  11. START_COMMAND=%s\n" "${START_COMMAND:-}"
  printf "  12. DIST_DIR=%s\n" "${DIST_DIR:-}"
  printf "  13. INTERNAL_PORT=%s\n" "${INTERNAL_PORT:-}"
  printf "  14. PERSISTENT_MOUNTS=%s\n" "${PERSISTENT_MOUNTS:-}"
}

edit_config_item() {
  local item_number="$1"
  local key current_value new_value

  key="$(config_key_by_number "$item_number")" || fail "Item invalido: $item_number"
  current_value="${!key:-}"
  read -r -p "$item_number. $key [$current_value]: " new_value
  printf -v "$key" "%s" "${new_value:-$current_value}"
}

confirm_configuration() {
  apply_config_defaults

  if [[ "$YES" == "true" ]]; then
    return 0
  fi

  while true; do
    show_config_review
    echo
    echo "Pressione Enter para confirmar, digite o numero do item para editar, ou 'all' para revisar campo a campo."

    local option=""
    read -r -p "Opcao: " option
    option="${option:-confirm}"

    case "$option" in
      confirm|c|C|s|S|sim|SIM|y|Y|yes|YES)
        if configuration_is_complete; then
          return 0
        fi
        echo
        printf '%s\n' "Revise os itens acima antes de continuar." >&2
        ;;
      all|ALL|tudo|TUDO)
        edit_config_item 1
        edit_config_item 2
        edit_config_item 3
        edit_config_item 4
        edit_config_item 5
        edit_config_item 6
        edit_config_item 7
        edit_config_item 8
        edit_config_item 9
        edit_config_item 10
        edit_config_item 11
        edit_config_item 12
        edit_config_item 13
        edit_config_item 14
        ;;
      [1-9]|1[0-4])
        edit_config_item "$option"
        ;;
      *)
        printf '%s\n' "Opcao invalida." >&2
        ;;
    esac
  done
}

configuration_is_complete() {
  local valid="true"

  if ! validate_project_name_value "${PROJECT_NAME:-}"; then
    printf '%s\n' "PROJECT_NAME invalido. Use minusculas, numeros, hifen e underscore." >&2
    valid="false"
  fi
  if ! validate_domain_value "${DOMAIN:-}"; then
    printf '%s\n' "DOMAIN invalido. Nao use espacos nem crase." >&2
    valid="false"
  fi
  if [[ -z "${REPO_URL:-}" ]]; then
    printf '%s\n' "REPO_URL nao pode ficar vazio." >&2
    valid="false"
  fi
  if [[ -z "${BRANCH:-}" ]]; then
    printf '%s\n' "BRANCH nao pode ficar vazia." >&2
    valid="false"
  fi
  if [[ -z "${TRAEFIK_NETWORK:-}" ]]; then
    printf '%s\n' "TRAEFIK_NETWORK nao pode ficar vazia." >&2
    valid="false"
  fi
  if [[ -z "${CERT_RESOLVER:-}" ]]; then
    printf '%s\n' "CERT_RESOLVER nao pode ficar vazio." >&2
    valid="false"
  fi
  if ! validate_strategy_value "${DEPLOY_STRATEGY:-}"; then
    printf '%s\n' "DEPLOY_STRATEGY invalido. Use static ou runtime." >&2
    valid="false"
  fi
  if ! validate_runtime_value "${RUNTIME:-}"; then
    printf '%s\n' "RUNTIME invalido. Use node, python ou custom." >&2
    valid="false"
  fi
  if [[ -z "${INSTALL_COMMAND:-}" ]]; then
    printf '%s\n' "INSTALL_COMMAND nao pode ficar vazio." >&2
    valid="false"
  fi
  if [[ "$DEPLOY_STRATEGY" == "runtime" && -z "${START_COMMAND:-}" ]]; then
    printf '%s\n' "START_COMMAND e obrigatorio para DEPLOY_STRATEGY=runtime." >&2
    valid="false"
  fi
  if [[ "$DEPLOY_STRATEGY" == "static" && -z "${DIST_DIR:-}" ]]; then
    printf '%s\n' "DIST_DIR e obrigatorio para DEPLOY_STRATEGY=static." >&2
    valid="false"
  fi
  if ! validate_port_value "${INTERNAL_PORT:-}"; then
    printf '%s\n' "INTERNAL_PORT deve ser numerico." >&2
    valid="false"
  fi

  [[ "$valid" == "true" ]]
}

validate_inputs() {
  [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "PROJECT_NAME invalido. Use minusculas, numeros, hifen e underscore."
  [[ "$DOMAIN" != *"\`"* ]] || fail "DOMAIN nao pode conter crase."
  [[ "$DOMAIN" != *" "* ]] || fail "DOMAIN nao pode conter espacos."
  [[ -n "$REPO_URL" ]] || fail "REPO_URL nao pode ficar vazio."
  [[ -n "$BRANCH" ]] || fail "BRANCH nao pode ficar vazia."
  [[ -n "$TRAEFIK_NETWORK" ]] || fail "TRAEFIK_NETWORK nao pode ficar vazia."
  [[ -n "$CERT_RESOLVER" ]] || fail "CERT_RESOLVER nao pode ficar vazio."
  [[ "$DEPLOY_STRATEGY" =~ ^(static|runtime)$ ]] || fail "DEPLOY_STRATEGY invalido. Use static ou runtime."
  [[ "$RUNTIME" =~ ^(node|python|custom)$ ]] || fail "RUNTIME invalido. Use node, python ou custom."
  [[ -n "$INSTALL_COMMAND" ]] || fail "INSTALL_COMMAND nao pode ficar vazio."
  [[ "$INTERNAL_PORT" =~ ^[0-9]+$ ]] || fail "INTERNAL_PORT deve ser numerico."
  if [[ "$DEPLOY_STRATEGY" == "runtime" && -z "$START_COMMAND" ]]; then
    fail "START_COMMAND e obrigatorio para DEPLOY_STRATEGY=runtime."
  fi
  if [[ "$DEPLOY_STRATEGY" == "static" && -z "$DIST_DIR" ]]; then
    fail "DIST_DIR e obrigatorio para DEPLOY_STRATEGY=static."
  fi
}

shell_quote() {
  printf "%q" "$1"
}

run_remote() {
  local remote_cmd="./deploy-full.sh"

  remote_cmd+=" --project $(shell_quote "$PROJECT_NAME")"
  remote_cmd+=" --domain $(shell_quote "$DOMAIN")"
  remote_cmd+=" --repo $(shell_quote "$REPO_URL")"
  remote_cmd+=" --branch $(shell_quote "$BRANCH")"
  remote_cmd+=" --network $(shell_quote "$TRAEFIK_NETWORK")"
  remote_cmd+=" --certresolver $(shell_quote "$CERT_RESOLVER")"
  remote_cmd+=" --internal-port $(shell_quote "$INTERNAL_PORT")"
  remote_cmd+=" --strategy $(shell_quote "$DEPLOY_STRATEGY")"
  remote_cmd+=" --runtime $(shell_quote "$RUNTIME")"
  remote_cmd+=" --install $(shell_quote "$INSTALL_COMMAND")"
  [[ -n "$BUILD_COMMAND" ]] && remote_cmd+=" --build $(shell_quote "$BUILD_COMMAND")"
  [[ -n "$START_COMMAND" ]] && remote_cmd+=" --start $(shell_quote "$START_COMMAND")"
  [[ -n "$DIST_DIR" ]] && remote_cmd+=" --dist $(shell_quote "$DIST_DIR")"
  [[ -n "$PERSISTENT_MOUNTS" ]] && remote_cmd+=" --mounts $(shell_quote "$PERSISTENT_MOUNTS")"
  remote_cmd+=" --yes"

  [[ "$REDETECT" == "true" ]] && remote_cmd+=" --redetect"
  [[ "$FORCE_YML" == "true" ]] && remote_cmd+=" --force-yml"
  [[ "$FORCE_DOCKERFILE" == "true" ]] && remote_cmd+=" --force-dockerfile"
  [[ "$DRY_RUN" == "true" ]] && remote_cmd+=" --dry-run"

  log "Executando no VPS: $SSH_TARGET"
  "$SSH_BIN" "$SSH_TARGET" "cd $(shell_quote "$REMOTE_SCRIPT_DIR") && $remote_cmd"
}

fetch_remote_env() {
  local remote_env="/compose/volume/$PROJECT_NAME/deploy.env"

  [[ "$DRY_RUN" == "true" ]] && return 0
  "$SCP_BIN" "$SSH_TARGET:$remote_env" "$ENV_FILE"
  log "deploy.env local sincronizado a partir do VPS: $ENV_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --ssh-target)
      SSH_TARGET="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_SCRIPT_DIR="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT_NAME="${2:-}"
      shift 2
      ;;
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --network)
      TRAEFIK_NETWORK="${2:-}"
      shift 2
      ;;
    --certresolver)
      CERT_RESOLVER="${2:-}"
      shift 2
      ;;
    --internal-port)
      INTERNAL_PORT="${2:-}"
      shift 2
      ;;
    --strategy)
      DEPLOY_STRATEGY="${2:-}"
      shift 2
      ;;
    --runtime)
      RUNTIME="${2:-}"
      shift 2
      ;;
    --install)
      INSTALL_COMMAND="${2:-}"
      shift 2
      ;;
    --build)
      BUILD_COMMAND="${2:-}"
      shift 2
      ;;
    --start)
      START_COMMAND="${2:-}"
      shift 2
      ;;
    --dist)
      DIST_DIR="${2:-}"
      shift 2
      ;;
    --mounts)
      PERSISTENT_MOUNTS="${2:-}"
      shift 2
      ;;
    --redetect)
      REDETECT="true"
      shift
      ;;
    --force-yml)
      FORCE_YML="true"
      shift
      ;;
    --force-dockerfile)
      FORCE_DOCKERFILE="true"
      shift
      ;;
    --yes|-y)
      YES="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Opcao desconhecida: $1"
      ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  ENV_FILE_EXISTS="true"
fi

load_local_env
detect_local_defaults

if [[ "$REDETECT" == "true" ]]; then
  PROJECT_NAME="${PROJECT_NAME:-$DETECTED_PROJECT_NAME}"
  REPO_URL="${REPO_URL:-$DETECTED_REPO_URL}"
  BRANCH="${BRANCH:-$DETECTED_BRANCH}"
  TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-$DETECTED_TRAEFIK_NETWORK}"
  CERT_RESOLVER="${CERT_RESOLVER:-$DETECTED_CERT_RESOLVER}"
  DEPLOY_STRATEGY="${DEPLOY_STRATEGY:-$DETECTED_DEPLOY_STRATEGY}"
  RUNTIME="${RUNTIME:-$DETECTED_RUNTIME}"
  INSTALL_COMMAND="${INSTALL_COMMAND:-$DETECTED_INSTALL_COMMAND}"
  BUILD_COMMAND="${BUILD_COMMAND:-$DETECTED_BUILD_COMMAND}"
  START_COMMAND="${START_COMMAND:-$DETECTED_START_COMMAND}"
  DIST_DIR="${DIST_DIR:-$DETECTED_DIST_DIR}"
  INTERNAL_PORT="${INTERNAL_PORT:-$DETECTED_INTERNAL_PORT}"
  PERSISTENT_MOUNTS="${PERSISTENT_MOUNTS:-$DETECTED_PERSISTENT_MOUNTS}"
fi

confirm_configuration

validate_inputs
run_remote
fetch_remote_env
