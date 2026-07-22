#!/usr/bin/env bash
set -Eeuo pipefail

SERVER_IP="185.215.165.130"
COMPOSE_DIR="/compose"
VOLUME_ROOT="/compose/volume"
DEFAULT_BRANCH="main"
DEFAULT_NETWORK="traknet"
DEFAULT_CERT_RESOLVER="le"
SKILL_ID="full-deploy-skill"
SKILL_VERSION="v1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${DEPLOY_FULL_TEMPLATE:-$SCRIPT_DIR/deploy-full-template.yml}"

YES="false"
FORCE_YML="false"
FORCE_DOCKERFILE="false"
REDETECT="false"
DRY_RUN="false"

PROJECT_NAME=""
DOMAIN=""
REPO_URL=""
BRANCH=""
TRAEFIK_NETWORK=""
CERT_RESOLVER=""
INTERNAL_PORT=""
DEPLOY_STRATEGY=""
RUNTIME=""
INSTALL_COMMAND=""
BUILD_COMMAND=""
START_COMMAND=""
DIST_DIR=""
PERSISTENT_MOUNTS=""
PACKAGE_MANAGER=""

log() {
  printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"
}

ok() {
  printf "\033[1;32m[OK]\033[0m %s\n" "$*"
}

warn() {
  printf "\033[1;33m[AVISO]\033[0m %s\n" "$*"
}

fail() {
  printf "\n\033[1;31m[ERRO]\033[0m %s\n" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso:

  ./deploy-full.sh --project NOME --domain DOMINIO --repo REPO_URL [opcoes]

Opcoes:

  --project NOME              Nome do projeto/container/service
  --domain DOMINIO            Dominio publico do app
  --repo REPO_URL             URL do repositorio Git
  --branch BRANCH             Branch do repositorio. Padrao: main
  --network NOME              Rede Docker/Traefik. Padrao: traknet
  --certresolver NOME         Cert resolver do Traefik. Padrao: le
  --internal-port PORTA       Porta interna do app/container
  --strategy TIPO             static|runtime
  --runtime TIPO              node|python|custom
  --install "COMANDO"         Comando de instalacao
  --build "COMANDO"           Comando de build
  --start "COMANDO"           Comando de runtime/producao
  --dist PASTA                Pasta de saida estatica
  --mounts LISTA              Ex.: files:/app/files,uploads:/app/uploads
  --redetect                  Redetecta defaults do projeto mesmo com deploy.env
  --force-yml                 Sobrescreve YML nao gerenciado apos backup
  --force-dockerfile          Sobrescreve Dockerfile.deploy nao gerenciado apos backup
  --yes                       Nao pergunta confirmacao
  --dry-run                   Mostra o que faria, mas nao executa build/deploy
  --help                      Mostra esta ajuda

EOF
}

ask_required() {
  local var_name="$1"
  local label="$2"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ "$YES" == "true" ]]; then
    fail "Variavel obrigatoria ausente em modo --yes: $var_name"
  fi

  read -r -p "$label: " current_value
  [[ -n "$current_value" ]] || fail "$var_name nao pode ficar vazio."
  printf -v "$var_name" '%s' "$current_value"
}

ask_default() {
  local var_name="$1"
  local label="$2"
  local default_value="$3"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ "$YES" == "true" ]]; then
    printf -v "$var_name" '%s' "$default_value"
    return 0
  fi

  read -r -p "$label [$default_value]: " current_value
  current_value="${current_value:-$default_value}"
  printf -v "$var_name" '%s' "$current_value"
}

confirm() {
  local question="$1"

  if [[ "$YES" == "true" ]]; then
    return 0
  fi

  local answer=""
  read -r -p "$question [s/N]: " answer
  case "$answer" in
    s|S|sim|SIM|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatorio nao encontrado: $1"
}

validate_project_name() {
  [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "PROJECT_NAME invalido. Use apenas minusculas, numeros, hifen e underscore."
}

validate_domain() {
  [[ "$DOMAIN" != *"\`"* ]] || fail "DOMAIN nao pode conter crase."
  [[ "$DOMAIN" != *" "* ]] || fail "DOMAIN nao pode conter espacos."
}

validate_internal_port() {
  [[ "$INTERNAL_PORT" =~ ^[0-9]+$ ]] || fail "INTERNAL_PORT deve ser numerico."
}

validate_strategy() {
  [[ "$DEPLOY_STRATEGY" =~ ^(static|runtime)$ ]] || fail "DEPLOY_STRATEGY deve ser static ou runtime."
}

validate_runtime() {
  [[ "$RUNTIME" =~ ^(node|python|custom)$ ]] || fail "RUNTIME deve ser node, python ou custom."
}

validate_mounts() {
  local mounts="${PERSISTENT_MOUNTS:-}"
  [[ -z "$mounts" ]] && return 0
  [[ "$mounts" != *".."* ]] || fail "PERSISTENT_MOUNTS nao pode conter '..'."
  [[ "$mounts" != *'$('* && "$mounts" != *';'* && "$mounts" != *$'\n'* ]] || fail "PERSISTENT_MOUNTS contem caracteres proibidos."

  local old_ifs="$IFS"
  IFS=',' read -r -a mount_list <<< "$mounts"
  IFS="$old_ifs"

  local item left right
  for item in "${mount_list[@]}"; do
    [[ "$item" == *:* ]] || fail "Mount invalido: $item"
    left="${item%%:*}"
    right="${item#*:}"
    [[ "$left" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Subpasta invalida em mount: $left"
    [[ "$right" == /* ]] || fail "Destino do mount deve ser absoluto: $right"
  done
}

is_allowed_deploy_env_key() {
  case "$1" in
    PROJECT_NAME|DOMAIN|REPO_URL|BRANCH|TRAEFIK_NETWORK|CERT_RESOLVER|INTERNAL_PORT|DEPLOY_STRATEGY|RUNTIME|PACKAGE_MANAGER|INSTALL_COMMAND|BUILD_COMMAND|START_COMMAND|DIST_DIR|PERSISTENT_MOUNTS)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

decode_deploy_env_value() {
  local value="$1"
  local out=""
  local i ch

  if [[ "$value" == \$\'* ]]; then
    fail "Formato de valor nao suportado no arquivo env: $value"
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

load_deploy_env() {
  local deploy_env_file="$1"
  local line key raw_value decoded_value

  [[ -f "$deploy_env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"
    if is_allowed_deploy_env_key "$key"; then
      decoded_value="$(decode_deploy_env_value "$raw_value")"
      printf -v "$key" "%s" "$decoded_value"
    fi
  done < "$deploy_env_file"
}

read_env_key() {
  local env_file="$1"
  local wanted_key="$2"
  local line key raw_value

  [[ -f "$env_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"
    if [[ "$key" == "$wanted_key" ]]; then
      decode_deploy_env_value "$raw_value"
      return 0
    fi
  done < "$env_file"
  return 1
}

shell_quote() {
  printf "%q" "$1"
}

write_deploy_env() {
  local deploy_env_file="$1"
  local now
  now="$(date -Iseconds)"

  mkdir -p "$(dirname "$deploy_env_file")"
  {
    echo "# managed-by: $SKILL_ID"
    echo "# version: $SKILL_VERSION"
    echo "PROJECT_NAME=$(shell_quote "$PROJECT_NAME")"
    echo "DOMAIN=$(shell_quote "$DOMAIN")"
    echo "REPO_URL=$(shell_quote "$REPO_URL")"
    echo "BRANCH=$(shell_quote "$BRANCH")"
    echo "TRAEFIK_NETWORK=$(shell_quote "$TRAEFIK_NETWORK")"
    echo "CERT_RESOLVER=$(shell_quote "$CERT_RESOLVER")"
    echo "INTERNAL_PORT=$(shell_quote "$INTERNAL_PORT")"
    echo "DEPLOY_STRATEGY=$(shell_quote "$DEPLOY_STRATEGY")"
    echo "RUNTIME=$(shell_quote "$RUNTIME")"
    echo "PACKAGE_MANAGER=$(shell_quote "$PACKAGE_MANAGER")"
    echo "INSTALL_COMMAND=$(shell_quote "$INSTALL_COMMAND")"
    echo "BUILD_COMMAND=$(shell_quote "$BUILD_COMMAND")"
    echo "START_COMMAND=$(shell_quote "$START_COMMAND")"
    echo "DIST_DIR=$(shell_quote "$DIST_DIR")"
    echo "PERSISTENT_MOUNTS=$(shell_quote "$PERSISTENT_MOUNTS")"
    echo "SERVER_IP=$(shell_quote "$SERVER_IP")"
    echo "COMPOSE_FILE=$(shell_quote "$COMPOSE_FILE")"
    echo "REPO_DIR=$(shell_quote "$REPO_DIR")"
    echo "IMAGE_NAME=$(shell_quote "$IMAGE_NAME")"
    echo "LAST_DEPLOY_AT=$(shell_quote "$now")"
    echo "SKILL_VERSION=$(shell_quote "$SKILL_VERSION")"
  } > "$deploy_env_file"
}

backup_file_if_exists() {
  local file_path="$1"
  local backups_dir="$2"
  if [[ -f "$file_path" ]]; then
    mkdir -p "$backups_dir"
    cp -a "$file_path" "$backups_dir/$(basename "$file_path").$(date +%Y%m%d-%H%M%S).bak"
  fi
}

append_divergence() {
  DIVERGENCES+=("$1")
}

compare_remote_key() {
  local env_file="$1"
  local key="$2"
  local current_value="${!key:-}"
  local remote_value=""

  if ! remote_value="$(read_env_key "$env_file" "$key")"; then
    append_divergence "$key ausente em $env_file"
    return 0
  fi
  if [[ "$remote_value" != "$current_value" ]]; then
    append_divergence "$key divergente: local='$current_value' remoto='$remote_value'"
  fi
}

require_remote_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || append_divergence "$label ausente: $path"
}

require_remote_dir() {
  local path="$1"
  local label="$2"
  [[ -d "$path" ]] || append_divergence "$label ausente: $path"
}

check_managed_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || return 0
  grep -q "managed-by: $SKILL_ID" "$path" || append_divergence "$label nao gerenciado pela skill: $path"
}

classify_remote_state() {
  DIVERGENCES=()
  DEPLOY_KIND="first_deploy"
  REMOTE_STATE_FILE=""

  if [[ -f "$DEPLOY_ENV" ]]; then
    REMOTE_STATE_FILE="$DEPLOY_ENV"
    DEPLOY_KIND="redeploy"
  fi

  if [[ -n "$REMOTE_STATE_FILE" ]]; then
    compare_remote_key "$REMOTE_STATE_FILE" PROJECT_NAME
    compare_remote_key "$REMOTE_STATE_FILE" DOMAIN
    compare_remote_key "$REMOTE_STATE_FILE" REPO_URL
    compare_remote_key "$REMOTE_STATE_FILE" BRANCH
    compare_remote_key "$REMOTE_STATE_FILE" TRAEFIK_NETWORK
    compare_remote_key "$REMOTE_STATE_FILE" CERT_RESOLVER
    compare_remote_key "$REMOTE_STATE_FILE" INTERNAL_PORT
    compare_remote_key "$REMOTE_STATE_FILE" DEPLOY_STRATEGY
    compare_remote_key "$REMOTE_STATE_FILE" RUNTIME
    compare_remote_key "$REMOTE_STATE_FILE" INSTALL_COMMAND
    compare_remote_key "$REMOTE_STATE_FILE" BUILD_COMMAND
    compare_remote_key "$REMOTE_STATE_FILE" START_COMMAND
    compare_remote_key "$REMOTE_STATE_FILE" DIST_DIR
    compare_remote_key "$REMOTE_STATE_FILE" PERSISTENT_MOUNTS

    require_remote_dir "$APP_DIR" "Pasta do projeto"
    require_remote_dir "$REPO_DIR/.git" "Repositorio Git"
    require_remote_file "$COMPOSE_FILE" "Compose"
    require_remote_file "$REPO_DIR/Dockerfile.deploy" "Dockerfile.deploy"
    require_remote_file "$TEMPLATE_FILE" "Template Compose"
    check_managed_file "$REPO_DIR/Dockerfile.deploy" "Dockerfile.deploy"
    check_managed_file "$COMPOSE_FILE" "Compose"
  else
    [[ -e "$COMPOSE_FILE" ]] && append_divergence "Compose existe sem deploy.env remoto: $COMPOSE_FILE"
    [[ -d "$REPO_DIR" ]] && append_divergence "Repositorio remoto existe sem deploy.env remoto: $REPO_DIR"
    if [[ -d "$APP_DIR" ]] && [[ -n "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 2>/dev/null || true)" ]]; then
      append_divergence "Pasta do projeto existe sem deploy.env remoto: $APP_DIR"
    fi
  fi

  if ((${#DIVERGENCES[@]} > 0)); then
    printf "\n\033[1;31m[ERRO]\033[0m Divergencia no estado remoto. Nada foi alterado.\n" >&2
    printf "Projeto: %s\n" "$PROJECT_NAME" >&2
    printf "Estado detectado: %s\n" "${DEPLOY_KIND:-indefinido}" >&2
    printf "Problemas:\n" >&2
    printf "  - %s\n" "${DIVERGENCES[@]}" >&2
    exit 1
  fi

  ok "Estado remoto classificado como: $DEPLOY_KIND"
}

ensure_network() {
  if docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
    ok "Rede Docker existente: $TRAEFIK_NETWORK"
  else
    log "Rede $TRAEFIK_NETWORK nao existe. Criando..."
    [[ "$DRY_RUN" == "true" ]] || docker network create "$TRAEFIK_NETWORK"
    ok "Rede Docker garantida: $TRAEFIK_NETWORK"
  fi
}

clone_or_update_repo() {
  mkdir -p "$APP_DIR"

  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Repositorio ja existe. Atualizando branch $BRANCH..."
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" fetch origin "$BRANCH" --prune
    git -C "$REPO_DIR" checkout "$BRANCH"
    git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
    ok "Repositorio atualizado."
  else
    if [[ -d "$REPO_DIR" ]] && [[ -n "$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 2>/dev/null || true)" ]]; then
      fail "A pasta $REPO_DIR existe, mas nao e um repositorio Git vazio. Revise antes de continuar."
    fi
    log "Clonando repositorio..."
    rm -rf "$REPO_DIR"
    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    ok "Repositorio clonado em $REPO_DIR"
  fi
}

detect_package_manager() {
  if [[ -f "$REPO_DIR/pnpm-lock.yaml" ]]; then
    PACKAGE_MANAGER="pnpm"
    [[ -n "$INSTALL_COMMAND" && "$REDETECT" != "true" ]] || INSTALL_COMMAND="corepack enable && pnpm install --frozen-lockfile"
    [[ -n "$RUNTIME" && "$REDETECT" != "true" ]] || RUNTIME="node"
  elif [[ -f "$REPO_DIR/yarn.lock" ]]; then
    PACKAGE_MANAGER="yarn"
    [[ -n "$INSTALL_COMMAND" && "$REDETECT" != "true" ]] || INSTALL_COMMAND="corepack enable && yarn install --frozen-lockfile"
    [[ -n "$RUNTIME" && "$REDETECT" != "true" ]] || RUNTIME="node"
  elif [[ -f "$REPO_DIR/package-lock.json" ]]; then
    PACKAGE_MANAGER="npm"
    [[ -n "$INSTALL_COMMAND" && "$REDETECT" != "true" ]] || INSTALL_COMMAND="npm ci"
    [[ -n "$RUNTIME" && "$REDETECT" != "true" ]] || RUNTIME="node"
  elif [[ -f "$REPO_DIR/package.json" ]]; then
    PACKAGE_MANAGER="npm"
    [[ -n "$INSTALL_COMMAND" && "$REDETECT" != "true" ]] || INSTALL_COMMAND="npm install"
    [[ -n "$RUNTIME" && "$REDETECT" != "true" ]] || RUNTIME="node"
  elif [[ -f "$REPO_DIR/requirements.txt" ]]; then
    PACKAGE_MANAGER="pip"
    [[ -n "$INSTALL_COMMAND" && "$REDETECT" != "true" ]] || INSTALL_COMMAND="pip install -r requirements.txt"
    [[ -n "$RUNTIME" && "$REDETECT" != "true" ]] || RUNTIME="python"
  else
    PACKAGE_MANAGER="custom"
    [[ -n "$RUNTIME" ]] || RUNTIME="custom"
  fi
}

package_has_script() {
  local script_name="$1"
  [[ -f "$REPO_DIR/package.json" ]] || return 1
  grep -Eq "\"$script_name\"[[:space:]]*:" "$REPO_DIR/package.json"
}

detect_runtime_defaults() {
  detect_package_manager

  if [[ "$RUNTIME" == "node" ]]; then
    if [[ -z "$BUILD_COMMAND" || "$REDETECT" == "true" ]]; then
      if package_has_script "build"; then
        case "$PACKAGE_MANAGER" in
          pnpm) BUILD_COMMAND="pnpm run build" ;;
          yarn) BUILD_COMMAND="yarn build" ;;
          *) BUILD_COMMAND="npm run build" ;;
        esac
      fi
    fi

    if [[ -z "$START_COMMAND" || "$REDETECT" == "true" ]]; then
      if package_has_script "start"; then
        case "$PACKAGE_MANAGER" in
          pnpm) START_COMMAND="pnpm start" ;;
          yarn) START_COMMAND="yarn start" ;;
          *) START_COMMAND="npm run start" ;;
        esac
      elif [[ -f "$REPO_DIR/server.js" ]]; then
        START_COMMAND="node server.js"
      elif [[ -f "$REPO_DIR/server/index.js" ]]; then
        START_COMMAND="node server/index.js"
      fi
    fi

    if [[ -z "$DIST_DIR" || "$REDETECT" == "true" ]]; then
      if [[ -f "$REPO_DIR/vite.config.ts" || -f "$REPO_DIR/vite.config.js" ]]; then
        DIST_DIR="dist"
      elif grep -Eqi '"react-scripts"[[:space:]]*:' "$REPO_DIR/package.json" 2>/dev/null; then
        DIST_DIR="build"
      elif grep -Eqi '"next"[[:space:]]*:' "$REPO_DIR/package.json" 2>/dev/null; then
        DIST_DIR=".next"
      fi
    fi
  elif [[ "$RUNTIME" == "python" ]]; then
    if [[ -z "$START_COMMAND" || "$REDETECT" == "true" ]]; then
      if [[ -f "$REPO_DIR/main.py" ]]; then
        START_COMMAND="uvicorn main:app --host 0.0.0.0 --port 8000"
      elif [[ -f "$REPO_DIR/app.py" ]]; then
        START_COMMAND="gunicorn app:app --bind 0.0.0.0:8000"
      fi
    fi
  fi

  if [[ -z "$DEPLOY_STRATEGY" || "$REDETECT" == "true" ]]; then
    if [[ -n "$START_COMMAND" ]]; then
      DEPLOY_STRATEGY="runtime"
    elif [[ -n "$DIST_DIR" ]]; then
      DEPLOY_STRATEGY="static"
    fi
  fi
}

review_or_edit_config() {
  log "Configuracao detectada/salva:"
  echo "  DEPLOY_STRATEGY : $DEPLOY_STRATEGY"
  echo "  RUNTIME         : $RUNTIME"
  echo "  PACKAGE_MANAGER : $PACKAGE_MANAGER"
  echo "  INSTALL_COMMAND : $INSTALL_COMMAND"
  echo "  BUILD_COMMAND   : $BUILD_COMMAND"
  echo "  START_COMMAND   : $START_COMMAND"
  echo "  DIST_DIR        : $DIST_DIR"
  echo "  INTERNAL_PORT   : $INTERNAL_PORT"
  echo "  PERSISTENT_MOUNTS: $PERSISTENT_MOUNTS"

  if [[ "$YES" == "true" ]]; then
    return 0
  fi

  echo
  echo "Escolha uma opcao:"
  echo "  1) Usar configuracao acima"
  echo "  2) Editar tudo"
  echo
  local option=""
  read -r -p "Opcao [1]: " option
  option="${option:-1}"

  case "$option" in
    1) ;;
    2)
      read -r -p "DEPLOY_STRATEGY [$DEPLOY_STRATEGY]: " value
      DEPLOY_STRATEGY="${value:-$DEPLOY_STRATEGY}"
      read -r -p "RUNTIME [$RUNTIME]: " value
      RUNTIME="${value:-$RUNTIME}"
      read -r -p "INSTALL_COMMAND [$INSTALL_COMMAND]: " value
      INSTALL_COMMAND="${value:-$INSTALL_COMMAND}"
      read -r -p "BUILD_COMMAND [$BUILD_COMMAND]: " value
      BUILD_COMMAND="${value:-$BUILD_COMMAND}"
      read -r -p "START_COMMAND [$START_COMMAND]: " value
      START_COMMAND="${value:-$START_COMMAND}"
      read -r -p "DIST_DIR [$DIST_DIR]: " value
      DIST_DIR="${value:-$DIST_DIR}"
      read -r -p "INTERNAL_PORT [$INTERNAL_PORT]: " value
      INTERNAL_PORT="${value:-$INTERNAL_PORT}"
      read -r -p "PERSISTENT_MOUNTS [$PERSISTENT_MOUNTS]: " value
      PERSISTENT_MOUNTS="${value:-$PERSISTENT_MOUNTS}"
      ;;
    *)
      fail "Opcao invalida."
      ;;
  esac
}

generate_dockerignore() {
  local dockerignore="$REPO_DIR/.dockerignore"
  cat > "$dockerignore" <<'EOF'
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
npm-debug.log
yarn-error.log
pnpm-debug.log
EOF
  ok ".dockerignore garantido."
}

docker_base_image() {
  case "$RUNTIME" in
    node) printf "node:22-alpine" ;;
    python) printf "python:3.12-slim" ;;
    custom) printf "debian:bookworm-slim" ;;
    *) fail "RUNTIME invalido: $RUNTIME" ;;
  esac
}

generate_dockerfile() {
  local dockerfile="$REPO_DIR/Dockerfile.deploy"
  local base_image
  base_image="$(docker_base_image)"

  if [[ -f "$dockerfile" ]] && ! grep -q "managed-by: $SKILL_ID" "$dockerfile"; then
    backup_file_if_exists "$dockerfile" "$BACKUPS_DIR"
    if [[ "$YES" == "true" && "$FORCE_DOCKERFILE" != "true" ]]; then
      fail "Dockerfile.deploy existente nao foi criado por esta skill. Use --force-dockerfile para sobrescrever apos backup."
    fi
    if [[ "$FORCE_DOCKERFILE" != "true" ]]; then
      confirm "Dockerfile.deploy existente nao foi criado por esta skill. Sobrescrever apos backup?" || fail "Operacao cancelada."
    fi
  else
    backup_file_if_exists "$dockerfile" "$BACKUPS_DIR"
  fi

  if [[ "$DEPLOY_STRATEGY" == "static" ]]; then
    cat > "$dockerfile" <<EOF
# managed-by: $SKILL_ID
# version: $SKILL_VERSION
# project: $PROJECT_NAME

FROM $base_image AS builder

WORKDIR /app
COPY . .
$( [[ -n "$INSTALL_COMMAND" ]] && printf 'RUN %s\n' "$INSTALL_COMMAND" )
$( [[ -n "$BUILD_COMMAND" ]] && printf 'RUN %s\n' "$BUILD_COMMAND" )
RUN test -d "$DIST_DIR" || (echo "ERRO: pasta de build '$DIST_DIR' nao encontrada." && find . -maxdepth 2 -type d | sort && exit 1)

FROM nginx:1.27-alpine

RUN rm -f /etc/nginx/conf.d/default.conf && cat > /etc/nginx/conf.d/default.conf <<'NGINX_CONF'
server {
  listen $INTERNAL_PORT;
  server_name _;

  root /usr/share/nginx/html;
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
NGINX_CONF

COPY --from=builder /app/$DIST_DIR/ /usr/share/nginx/html/

EXPOSE $INTERNAL_PORT
CMD ["nginx", "-g", "daemon off;"]
EOF
  else
    cat > "$dockerfile" <<EOF
# managed-by: $SKILL_ID
# version: $SKILL_VERSION
# project: $PROJECT_NAME

FROM $base_image

WORKDIR /app
COPY . .
$( [[ -n "$INSTALL_COMMAND" ]] && printf 'RUN %s\n' "$INSTALL_COMMAND" )
$( [[ -n "$BUILD_COMMAND" ]] && printf 'RUN %s\n' "$BUILD_COMMAND" )

EXPOSE $INTERNAL_PORT
CMD $START_COMMAND
EOF
  fi

  ok "Dockerfile.deploy gerado em $dockerfile"
}

build_volumes_block() {
  local mounts="${PERSISTENT_MOUNTS:-}"
  [[ -z "$mounts" ]] && return 0

  printf "    volumes:\n"

  local old_ifs="$IFS"
  IFS=',' read -r -a mount_list <<< "$mounts"
  IFS="$old_ifs"
  local item left right
  for item in "${mount_list[@]}"; do
    left="${item%%:*}"
    right="${item#*:}"
    printf "      - %s/%s:%s\n" "$APP_DIR" "$left" "$right"
  done
}

ensure_persistent_dirs() {
  local mounts="${PERSISTENT_MOUNTS:-}"
  [[ -z "$mounts" ]] && return 0

  local old_ifs="$IFS"
  IFS=',' read -r -a mount_list <<< "$mounts"
  IFS="$old_ifs"
  local item left
  for item in "${mount_list[@]}"; do
    left="${item%%:*}"
    mkdir -p "$APP_DIR/$left"
  done
}

generate_compose_yml() {
  local compose_content=""
  local volumes_block=""

  [[ -f "$TEMPLATE_FILE" ]] || fail "Template Compose nao encontrado: $TEMPLATE_FILE"

  if [[ -f "$COMPOSE_FILE" ]] && ! grep -q "managed-by: $SKILL_ID" "$COMPOSE_FILE"; then
    backup_file_if_exists "$COMPOSE_FILE" "$BACKUPS_DIR"
    if [[ "$YES" == "true" && "$FORCE_YML" != "true" ]]; then
      fail "YML existente nao foi criado por esta skill. Use --force-yml para sobrescrever apos backup."
    fi
    if [[ "$FORCE_YML" != "true" ]]; then
      confirm "YML existente nao foi criado por esta skill. Sobrescrever apos backup?" || fail "Operacao cancelada."
    fi
  else
    backup_file_if_exists "$COMPOSE_FILE" "$BACKUPS_DIR"
  fi

  volumes_block="$(build_volumes_block)"
  compose_content="$(< "$TEMPLATE_FILE")"
  compose_content="${compose_content//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}"
  compose_content="${compose_content//\{\{DOMAIN\}\}/$DOMAIN}"
  compose_content="${compose_content//\{\{IMAGE_NAME\}\}/$IMAGE_NAME}"
  compose_content="${compose_content//\{\{TRAEFIK_NETWORK\}\}/$TRAEFIK_NETWORK}"
  compose_content="${compose_content//\{\{CERT_RESOLVER\}\}/$CERT_RESOLVER}"
  compose_content="${compose_content//\{\{INTERNAL_PORT\}\}/$INTERNAL_PORT}"
  compose_content="${compose_content//\{\{REPO_DIR\}\}/$REPO_DIR}"
  compose_content="${compose_content//\{\{VOLUMES_BLOCK\}\}/$volumes_block}"
  printf "%s\n" "$compose_content" > "$COMPOSE_FILE"

  ok "YML gerado em $COMPOSE_FILE"
}

check_dns() {
  if ! command -v getent >/dev/null 2>&1; then
    warn "getent nao encontrado. Pulando verificacao DNS."
    return 0
  fi

  local resolved_ip
  resolved_ip="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)"
  if [[ -z "$resolved_ip" ]]; then
    warn "Dominio ainda nao resolveu em IPv4: $DOMAIN"
    return 0
  fi
  if [[ "$resolved_ip" == "$SERVER_IP" ]]; then
    ok "DNS OK: $DOMAIN aponta para $SERVER_IP"
  else
    warn "DNS divergente: $DOMAIN resolveu para $resolved_ip, mas o VPS padrao e $SERVER_IP"
  fi
}

deploy_compose() {
  log "Executando build e deploy via Docker Compose..."

  if [[ "$DRY_RUN" == "true" ]]; then
    echo
    echo "DRY-RUN:"
    echo "  cd $COMPOSE_DIR"
    echo "  docker compose -f $(basename "$COMPOSE_FILE") build --pull"
    echo "  docker compose -f $(basename "$COMPOSE_FILE") up -d --force-recreate"
    return 0
  fi

  cd "$COMPOSE_DIR"
  docker compose -f "$(basename "$COMPOSE_FILE")" build --pull
  docker compose -f "$(basename "$COMPOSE_FILE")" up -d --force-recreate
  ok "Deploy aplicado com sucesso."
}

show_diagnostics() {
  log "Diagnostico do deploy"
  echo
  echo "Container:"
  docker ps --filter "name=^/${PROJECT_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  echo
  echo "Inspect resumido:"
  docker inspect "$PROJECT_NAME" --format='Container: {{.Name}}
  IP: {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}
  Networks: {{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}
  Image: {{.Config.Image}}' 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_NAME="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --repo) REPO_URL="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --network) TRAEFIK_NETWORK="${2:-}"; shift 2 ;;
    --certresolver) CERT_RESOLVER="${2:-}"; shift 2 ;;
    --internal-port) INTERNAL_PORT="${2:-}"; shift 2 ;;
    --strategy) DEPLOY_STRATEGY="${2:-}"; shift 2 ;;
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --install) INSTALL_COMMAND="${2:-}"; shift 2 ;;
    --build) BUILD_COMMAND="${2:-}"; shift 2 ;;
    --start) START_COMMAND="${2:-}"; shift 2 ;;
    --dist) DIST_DIR="${2:-}"; shift 2 ;;
    --mounts) PERSISTENT_MOUNTS="${2:-}"; shift 2 ;;
    --redetect) REDETECT="true"; shift ;;
    --force-yml) FORCE_YML="true"; shift ;;
    --force-dockerfile) FORCE_DOCKERFILE="true"; shift ;;
    --yes|-y) YES="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opcao desconhecida: $1" ;;
  esac
done

ask_required PROJECT_NAME "Nome do projeto/container"
validate_project_name

APP_DIR="$VOLUME_ROOT/$PROJECT_NAME"
REPO_DIR="$APP_DIR/repo"
DEPLOY_DIR="$APP_DIR/.deploy"
BACKUPS_DIR="$DEPLOY_DIR/backups"
DEPLOY_ENV="$APP_DIR/deploy.env"
COMPOSE_FILE="$COMPOSE_DIR/$PROJECT_NAME.yml"
IMAGE_SAFE_NAME="$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')"
IMAGE_NAME="local/$IMAGE_SAFE_NAME:latest"

SAVED_DOMAIN="$DOMAIN"
SAVED_REPO_URL="$REPO_URL"
SAVED_BRANCH="$BRANCH"
SAVED_NETWORK="$TRAEFIK_NETWORK"
SAVED_CERT_RESOLVER="$CERT_RESOLVER"
SAVED_INTERNAL_PORT="$INTERNAL_PORT"
SAVED_DEPLOY_STRATEGY="$DEPLOY_STRATEGY"
SAVED_RUNTIME="$RUNTIME"
SAVED_INSTALL_COMMAND="$INSTALL_COMMAND"
SAVED_BUILD_COMMAND="$BUILD_COMMAND"
SAVED_START_COMMAND="$START_COMMAND"
SAVED_DIST_DIR="$DIST_DIR"
SAVED_PERSISTENT_MOUNTS="$PERSISTENT_MOUNTS"

if [[ -f "$DEPLOY_ENV" ]]; then
  log "deploy.env remoto encontrado. Carregando configuracao salva..."
  load_deploy_env "$DEPLOY_ENV"
  ok "Configuracao salva carregada."
fi

DOMAIN="${SAVED_DOMAIN:-${DOMAIN:-}}"
REPO_URL="${SAVED_REPO_URL:-${REPO_URL:-}}"
BRANCH="${SAVED_BRANCH:-${BRANCH:-}}"
TRAEFIK_NETWORK="${SAVED_NETWORK:-${TRAEFIK_NETWORK:-}}"
CERT_RESOLVER="${SAVED_CERT_RESOLVER:-${CERT_RESOLVER:-}}"
INTERNAL_PORT="${SAVED_INTERNAL_PORT:-${INTERNAL_PORT:-}}"
DEPLOY_STRATEGY="${SAVED_DEPLOY_STRATEGY:-${DEPLOY_STRATEGY:-}}"
RUNTIME="${SAVED_RUNTIME:-${RUNTIME:-}}"
INSTALL_COMMAND="${SAVED_INSTALL_COMMAND:-${INSTALL_COMMAND:-}}"
BUILD_COMMAND="${SAVED_BUILD_COMMAND:-${BUILD_COMMAND:-}}"
START_COMMAND="${SAVED_START_COMMAND:-${START_COMMAND:-}}"
DIST_DIR="${SAVED_DIST_DIR:-${DIST_DIR:-}}"
PERSISTENT_MOUNTS="${SAVED_PERSISTENT_MOUNTS:-${PERSISTENT_MOUNTS:-}}"

ask_required DOMAIN "Dominio do app"
validate_domain
ask_required REPO_URL "URL do repositorio Git"
ask_default BRANCH "Branch" "$DEFAULT_BRANCH"
ask_default TRAEFIK_NETWORK "Rede Docker/Traefik" "$DEFAULT_NETWORK"
ask_default CERT_RESOLVER "Traefik certresolver" "$DEFAULT_CERT_RESOLVER"

classify_remote_state

mkdir -p "$COMPOSE_DIR" "$VOLUME_ROOT" "$APP_DIR" "$DEPLOY_DIR" "$BACKUPS_DIR"
require_command docker
require_command git
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin nao encontrado. Esperado: docker compose"

ensure_network
clone_or_update_repo
detect_runtime_defaults
review_or_edit_config

ask_required DEPLOY_STRATEGY "DEPLOY_STRATEGY"
ask_required RUNTIME "RUNTIME"
ask_required INSTALL_COMMAND "INSTALL_COMMAND"
if [[ "$DEPLOY_STRATEGY" == "runtime" ]]; then
  ask_required START_COMMAND "START_COMMAND"
fi
if [[ "$DEPLOY_STRATEGY" == "static" ]]; then
  ask_required DIST_DIR "DIST_DIR"
fi
ask_required INTERNAL_PORT "INTERNAL_PORT"

validate_strategy
validate_runtime
validate_internal_port
validate_mounts

generate_dockerignore
generate_dockerfile
ensure_persistent_dirs
generate_compose_yml
check_dns
deploy_compose
write_deploy_env "$DEPLOY_ENV"
show_diagnostics

ok "Finalizado."
