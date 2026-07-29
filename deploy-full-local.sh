#!/usr/bin/env bash
set -Eeuo pipefail

# This wrapper is deliberately a two-step interface.  It may inspect a VPS,
# but it never deploys until the plan hash printed by --plan is supplied back.
ENV_FILE="deploy.env"
SSH_TARGET="${DEPLOY_FULL_SSH_TARGET:-contabo-vps}"
REMOTE_SCRIPT_DIR="${DEPLOY_FULL_REMOTE_SCRIPT_DIR:-/compose/script}"
SSH_BIN="${DEPLOY_FULL_SSH_BIN:-ssh.exe}"
SCP_BIN="${DEPLOY_FULL_SCP_BIN:-scp.exe}"

PLAN_ONLY="false"
PRINT_JSON="false"
OFFLINE="false"
REDETECT="false"
FORCE_YML="false"
FORCE_DOCKERFILE="false"
CONFIRMED_PLAN_HASH=""
REMOTE_STATE_HASH="absent"
SOURCE_COMMIT=""
EXPECTED_REMOTE_STATE_HASH=""

CONFIG_KEYS=(PROJECT_NAME DOMAIN REPO_URL BRANCH TRAEFIK_NETWORK CERT_RESOLVER DEPLOY_STRATEGY RUNTIME INSTALL_COMMAND BUILD_COMMAND START_COMMAND DIST_DIR INTERNAL_PORT PERSISTENT_MOUNTS APP_ENV_FILE DOCKERFILE_SOURCE)
for key in "${CONFIG_KEYS[@]}"; do
  printf -v "$key" '%s' ""
  printf -v "OVERRIDE_$key" '%s' ""
  printf -v "OVERRIDE_SET_$key" '%s' "false"
done

DETECTED_PROJECT_NAME=""
DETECTED_REPO_URL=""
DETECTED_BRANCH="main"
DETECTED_TRAEFIK_NETWORK="traknet"
DETECTED_CERT_RESOLVER="le"
DETECTED_DEPLOY_STRATEGY=""
DETECTED_RUNTIME=""
DETECTED_INSTALL_COMMAND=""
DETECTED_BUILD_COMMAND=""
DETECTED_START_COMMAND=""
DETECTED_DIST_DIR=""
DETECTED_INTERNAL_PORT=""
DETECTED_PERSISTENT_MOUNTS=""
DETECTED_DOCKERFILE_SOURCE="generated"
PROFILE_REASON="Nao foi possivel classificar o projeto com seguranca."
ENV_EXAMPLE_KEYS=""

log() { printf '\n\033[1;34m[LOCAL]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[LOCAL ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso seguro (sempre em duas etapas):

  ./deploy-full-local.sh --plan
  ./deploy-full-local.sh --confirmed-plan-hash HASH_MOSTRADO

Opcoes:
  --plan                       Inspecao somente leitura; nao altera o projeto nem o VPS.
  --print-config-json          Igual a --plan, em JSON para automacao.
  --offline                    Nao consulta o estado remoto durante o plano.
  --confirmed-plan-hash HASH   Executa exatamente o plano previamente apresentado e confirmado no chat.
  --env-file ARQUIVO           Estado local (padrao: deploy.env).
  --ssh-target ALVO            Alias/host SSH (padrao: contabo-vps).
  --remote-dir DIR             Diretorio remoto da skill (padrao: /compose/script).
  --project, --domain, --repo, --branch, --network, --certresolver
  --strategy static|runtime    --runtime node|python|python-fastapi|custom
  --install CMD --build CMD --start CMD --dist DIR --internal-port PORTA
  --mounts LISTA               subdir:/app/path,other:/app/other
  --app-env-file CAMINHO       Arquivo remoto com segredos (nunca e copiado pelo wrapper).
  --dockerfile-source generated|project
  --redetect                   Recalcula o perfil tecnico inteiro; mostra a diferenca no plano.
  --force-yml --force-dockerfile

--yes, redirecionamento de entrada e confirmacao pelo terminal nao sao suportados.
Confirme os valores no chat antes de reutilizar o hash mostrado pelo plano.
EOF
}

decode_env_value() {
  local value="$1" out="" i ch
  [[ "$value" != \$\'* ]] || fail "Formato de valor nao suportado em $ENV_FILE."
  if [[ "$value" == \"* && "$value" == *\" ]]; then value="${value:1:${#value}-2}";
  elif [[ "$value" == \'* && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
  for ((i=0; i<${#value}; i++)); do
    ch="${value:i:1}"
    if [[ "$ch" == "\\" && $((i+1)) -lt ${#value} ]]; then ((i++)); out+="${value:i:1}"; else out+="$ch"; fi
  done
  printf '%s' "$out"
}

load_local_env() {
  local line key raw value
  [[ -f "$ENV_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; raw="${BASH_REMATCH[2]}"
    case " ${CONFIG_KEYS[*]} " in *" $key "*) value="$(decode_env_value "$raw")"; printf -v "$key" '%s' "$value";; esac
  done < "$ENV_FILE"
}

package_json_query() { command -v node >/dev/null 2>&1 || return 1; node -e 'const p=require("./package.json"), q=process.argv[1]; process.exit((p.dependencies?.[q]||p.devDependencies?.[q]||p.scripts?.[q])?0:1)' "$1" 2>/dev/null; }
package_has_script() { [[ -f package.json ]] && package_json_query "$1" && node -e 'const p=require("./package.json"); process.exit(p.scripts?.[process.argv[1]]?0:1)' "$1" 2>/dev/null; }
package_uses() { [[ -f package.json ]] && package_json_query "$1"; }
has_export_output() { local file; for file in next.config.js next.config.ts next.config.mjs; do [[ -f "$file" ]] && grep -Eq "output[[:space:]]*:[[:space:]]*['\"]export['\"]" "$file" && return 0; done; return 1; }
has_vite_frontend() { [[ -f vite.config.js || -f vite.config.ts || -f vite.config.mjs ]] && package_uses "vite"; }
has_fastapi_backend() { [[ -d backend ]] && grep -R -Eq 'FastAPI[[:space:]]*\(' backend 2>/dev/null && { [[ -f backend/requirements.txt ]] && grep -Eiq '^fastapi([=<>~ ]|$)' backend/requirements.txt || [[ -f pyproject.toml ]]; }; }

detect_local_defaults() {
  DETECTED_PROJECT_NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
  DETECTED_REPO_URL="$(git remote get-url origin 2>/dev/null || true)"
  DETECTED_BRANCH="$(git branch --show-current 2>/dev/null || true)"; DETECTED_BRANCH="${DETECTED_BRANCH:-main}"
  DETECTED_TRAEFIK_NETWORK="traknet"; DETECTED_CERT_RESOLVER="le"
  ENV_EXAMPLE_KEYS="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{print $1}' .env.example 2>/dev/null | paste -sd, - || true)"

  if has_vite_frontend && has_fastapi_backend; then
    DETECTED_DEPLOY_STRATEGY="runtime"; DETECTED_RUNTIME="python-fastapi"; DETECTED_DIST_DIR="dist"; DETECTED_INTERNAL_PORT="8000"
    DETECTED_DOCKERFILE_SOURCE="generated"
    [[ -f Dockerfile.deploy ]] && DETECTED_DOCKERFILE_SOURCE="project"
    if [[ -f backend/alembic.ini ]]; then
      DETECTED_START_COMMAND="alembic -c backend/alembic.ini upgrade head && uvicorn backend.app.main:app --host 0.0.0.0 --port 8000 --workers 1"
    else
      DETECTED_START_COMMAND="uvicorn backend.app.main:app --host 0.0.0.0 --port 8000 --workers 1"
    fi
    PROFILE_REASON="Projeto hibrido Vite + FastAPI: build do frontend em Node e runtime Python/ASGI. Use DOCKERFILE_SOURCE=project quando Dockerfile.deploy multi-stage ja existir."
  elif [[ -f index.html && ! -f package.json ]]; then
    DETECTED_DEPLOY_STRATEGY="static"; DETECTED_RUNTIME="custom"; DETECTED_DIST_DIR="."; DETECTED_INTERNAL_PORT="80"
    PROFILE_REASON="HTML puro: index.html na raiz publicavel e nenhuma dependencia de runtime detectada."
  elif [[ -f vite.config.js || -f vite.config.ts || -f vite.config.mjs ]] && ! package_uses "vinext"; then
    DETECTED_RUNTIME="node"
    if package_has_script start || grep -Eq '(ssr|middlewareMode)' vite.config.* 2>/dev/null; then
      DETECTED_DEPLOY_STRATEGY="runtime"; DETECTED_INTERNAL_PORT="3000"
      PROFILE_REASON="Vite com sinal de SSR/runtime: confirme o comando e a porta; a presenca de Vite nao prova exportacao estatica."
    else
      DETECTED_DEPLOY_STRATEGY="static"; DETECTED_DIST_DIR="dist"; DETECTED_INTERNAL_PORT="80"
      PROFILE_REASON="Vite sem sinal de SSR: o perfil proposto e estatico; o build ainda deve produzir dist/index.html."
    fi
  elif package_uses "next" || package_uses "vinext" || [[ -f next.config.js || -f next.config.ts || -f next.config.mjs ]]; then
    DETECTED_RUNTIME="node"
    if has_export_output; then
      DETECTED_DEPLOY_STRATEGY="static"; DETECTED_DIST_DIR="out"; DETECTED_INTERNAL_PORT="80"
      PROFILE_REASON="Next/Vinext com output export: o build deve produzir out/index.html."
    else
      DETECTED_DEPLOY_STRATEGY="runtime"; DETECTED_INTERNAL_PORT="3000"
      PROFILE_REASON="Next/Vinext sem output export: requer servidor de runtime, normalmente na porta 3000."
    fi
  elif [[ -f requirements.txt || -f pyproject.toml ]]; then
    DETECTED_DEPLOY_STRATEGY="runtime"; DETECTED_RUNTIME="python"; DETECTED_INTERNAL_PORT="8000"
    PROFILE_REASON="Projeto Python: requer processo web de runtime; confirme comando e porta."
  elif [[ -f package.json ]] && package_has_script start; then
    DETECTED_DEPLOY_STRATEGY="runtime"; DETECTED_RUNTIME="node"; DETECTED_INTERNAL_PORT="3000"
    PROFILE_REASON="Projeto Node com script start: requer processo de runtime; confirme a porta."
  fi

  if [[ "$DETECTED_RUNTIME" == node || "$DETECTED_RUNTIME" == python-fastapi ]]; then
    if [[ -f pnpm-lock.yaml ]]; then DETECTED_INSTALL_COMMAND="corepack enable && pnpm install --frozen-lockfile"; package_has_script build && DETECTED_BUILD_COMMAND="pnpm run build"; [[ "$DETECTED_RUNTIME" == node ]] && package_has_script start && DETECTED_START_COMMAND="pnpm start"
    elif [[ -f yarn.lock ]]; then DETECTED_INSTALL_COMMAND="corepack enable && yarn install --frozen-lockfile"; package_has_script build && DETECTED_BUILD_COMMAND="yarn build"; [[ "$DETECTED_RUNTIME" == node ]] && package_has_script start && DETECTED_START_COMMAND="yarn start"
    elif [[ -f package-lock.json ]]; then DETECTED_INSTALL_COMMAND="npm ci"; package_has_script build && DETECTED_BUILD_COMMAND="npm run build"; [[ "$DETECTED_RUNTIME" == node ]] && package_has_script start && DETECTED_START_COMMAND="npm run start"
    else DETECTED_INSTALL_COMMAND="npm install"; package_has_script build && DETECTED_BUILD_COMMAND="npm run build"; [[ "$DETECTED_RUNTIME" == node ]] && package_has_script start && DETECTED_START_COMMAND="npm run start"; fi
  elif [[ "$DETECTED_RUNTIME" == python ]]; then
    DETECTED_INSTALL_COMMAND="pip install -r requirements.txt"
    [[ -f main.py ]] && DETECTED_START_COMMAND="uvicorn main:app --host 0.0.0.0 --port 8000"
    [[ -f app.py ]] && DETECTED_START_COMMAND="gunicorn app:app --bind 0.0.0.0:8000"
  fi

  return 0
}

apply_detected_defaults() {
  for key in "${CONFIG_KEYS[@]}"; do
    local detected="DETECTED_$key"
    [[ -n "${!key}" ]] || [[ -z "${!detected:-}" ]] || printf -v "$key" '%s' "${!detected}"
  done
}

apply_redetection() {
  local technical=(DEPLOY_STRATEGY RUNTIME INSTALL_COMMAND BUILD_COMMAND START_COMMAND DIST_DIR INTERNAL_PORT DOCKERFILE_SOURCE)
  local key detected
  for key in "${technical[@]}"; do detected="DETECTED_$key"; printf -v "$key" '%s' "${!detected:-}"; done
}

apply_overrides() { local key override set; for key in "${CONFIG_KEYS[@]}"; do override="OVERRIDE_$key"; set="OVERRIDE_SET_$key"; [[ "${!set}" == true ]] && printf -v "$key" '%s' "${!override}"; done; return 0; }
validate_port() { [[ "$1" =~ ^([1-9][0-9]{0,4})$ ]] && (( $1 <= 65535 )); }
normalize_mounts() {
  [[ -z "$PERSISTENT_MOUNTS" ]] && return 0
  local oldifs="$IFS" item clean subdir normalized="" sep=""
  IFS=',' read -ra items <<< "$PERSISTENT_MOUNTS"
  IFS="$oldifs"
  for item in "${items[@]}"; do
    [[ "$item" != *..* ]] || fail "PERSISTENT_MOUNTS invalido."
    if [[ "$item" == *:* ]]; then
      normalized+="$sep$item"
    elif [[ "$item" == /* ]]; then
      clean="${item%/}"
      subdir="${clean##*/}"
      [[ -n "$subdir" && "$subdir" =~ ^[A-Za-z0-9._-]+$ ]] || fail "PERSISTENT_MOUNTS absoluto nao pode apontar para raiz ou nome invalido."
      normalized+="$sep$subdir:$clean"
    else
      fail "PERSISTENT_MOUNTS invalido."
    fi
    sep=","
  done
  PERSISTENT_MOUNTS="$normalized"
}
validate_mounts() { [[ -z "$PERSISTENT_MOUNTS" ]] || [[ "$PERSISTENT_MOUNTS" =~ ^[A-Za-z0-9._-]+:/[A-Za-z0-9._/-]+(,[A-Za-z0-9._-]+:/[A-Za-z0-9._/-]+)*$ ]] || fail "PERSISTENT_MOUNTS invalido."; }
validate_config() {
  [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "PROJECT_NAME invalido."
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || fail "DOMAIN invalido."
  [[ -n "$REPO_URL" && -n "$BRANCH" && -n "$TRAEFIK_NETWORK" && -n "$CERT_RESOLVER" ]] || fail "Preencha PROJECT_NAME, DOMAIN, REPO_URL, BRANCH, TRAEFIK_NETWORK e CERT_RESOLVER."
  [[ "$DEPLOY_STRATEGY" =~ ^(static|runtime)$ ]] || fail "Perfil desconhecido. Informe --strategy static|runtime; a skill nao adivinha."
  [[ "$RUNTIME" =~ ^(node|python|python-fastapi|custom)$ ]] || fail "RUNTIME invalido."
  [[ "$DOCKERFILE_SOURCE" =~ ^(generated|project)$ ]] || fail "DOCKERFILE_SOURCE deve ser generated ou project."
  [[ "$DOCKERFILE_SOURCE" != project || -f Dockerfile.deploy ]] || fail "DOCKERFILE_SOURCE=project exige Dockerfile.deploy na raiz do projeto."
  validate_port "$INTERNAL_PORT" || fail "INTERNAL_PORT deve estar entre 1 e 65535."
  [[ "$DEPLOY_STRATEGY" != runtime || -n "$START_COMMAND" ]] || fail "START_COMMAND e obrigatorio para runtime."
  [[ "$DEPLOY_STRATEGY" != static || -n "$DIST_DIR" ]] || fail "DIST_DIR e obrigatorio para static."
  [[ "$DIST_DIR" != /* && "$DIST_DIR" != *..* ]] || fail "DIST_DIR deve ser relativo e sem '..'."
  validate_mounts
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
plan_payload() { local key; for key in "${CONFIG_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}"; done; printf 'SOURCE_COMMIT=%s\nREMOTE_STATE_HASH=%s\nFORCE_YML=%s\nFORCE_DOCKERFILE=%s\n' "$SOURCE_COMMIT" "$REMOTE_STATE_HASH" "$FORCE_YML" "$FORCE_DOCKERFILE"; }
plan_hash() { plan_payload | sha256; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\n'/\\n}"; printf '%s' "$value"; }

read_remote_state_hash() {
  [[ -n "$EXPECTED_REMOTE_STATE_HASH" ]] && REMOTE_STATE_HASH="$EXPECTED_REMOTE_STATE_HASH" && return 0
  [[ "$OFFLINE" == true ]] && return 0
  local remote_cmd="cd $(printf '%q' "$REMOTE_SCRIPT_DIR") && ./deploy-full.sh --state-hash --project $(printf '%q' "$PROJECT_NAME")"
  REMOTE_STATE_HASH="$($SSH_BIN "$SSH_TARGET" "$remote_cmd" | awk -F= '/^REMOTE_STATE_HASH=/{print $2; exit}')"
  [[ -n "$REMOTE_STATE_HASH" ]] || fail "Nao foi possivel ler o hash do estado remoto. Use --offline somente para inspecao local."
}

resolve_source_commit() {
  [[ -n "$SOURCE_COMMIT" ]] && return 0
  if [[ "$OFFLINE" == true ]]; then SOURCE_COMMIT="offline-unresolved"; return 0; fi
  SOURCE_COMMIT="$(git ls-remote "$REPO_URL" "refs/heads/$BRANCH" 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Nao foi possivel fixar o commit de $BRANCH."
}

show_plan() {
  local hash; hash="$(plan_hash)"
  if [[ "$PRINT_JSON" == true ]]; then
    printf '{"plan_hash":"%s","remote_state_hash":"%s","profile_reason":"%s","env_example_keys":"%s","config":{' "$hash" "$REMOTE_STATE_HASH" "$(json_escape "$PROFILE_REASON")" "$(json_escape "$ENV_EXAMPLE_KEYS")"
    local first=true key
    for key in "${CONFIG_KEYS[@]}"; do [[ "$first" == true ]] || printf ','; first=false; printf '"%s":"%s"' "$key" "$(json_escape "${!key}")"; done
    printf '}}\n'; return 0
  fi
  log "Plano somente leitura — confirme estes valores no chat antes de executar."
  local i=1 key; for key in "${CONFIG_KEYS[@]}"; do printf '  %2d. %s=%s\n' "$i" "$key" "${!key}"; ((i+=1)); done
  printf '\nPerfil: %s\n' "$PROFILE_REASON"
  printf 'Diretorio operacional: /compose/volume/%s\n' "$PROJECT_NAME"
  printf 'Montagens persistentes: %s\n' "${PERSISTENT_MOUNTS:-nenhuma}"
  printf 'Variaveis detectadas em .env.example (sem valores): %s\n' "${ENV_EXAMPLE_KEYS:-nenhuma}"
  printf 'Hash do estado remoto: %s\n' "$REMOTE_STATE_HASH"
  printf 'Commit fixado: %s\n' "$SOURCE_COMMIT"
  printf '\nHASH DO PLANO: %s\n' "$hash"
  printf 'Depois da confirmacao explicita no chat, execute exatamente:\n  ./deploy-full-local.sh --confirmed-plan-hash %q --expected-remote-state-hash %q --source-commit %q' "$hash" "$REMOTE_STATE_HASH" "$SOURCE_COMMIT"
  local key option
  for key in "${CONFIG_KEYS[@]}"; do option="$(option_for_key "$key")"; printf ' %s %q' "$option" "${!key}"; done
  [[ "$FORCE_YML" == true ]] && printf ' --force-yml'
  [[ "$FORCE_DOCKERFILE" == true ]] && printf ' --force-dockerfile'
  printf '\n'
}

option_for_key() {
  case "$1" in
    PROJECT_NAME) printf -- "--project";;
    DOMAIN) printf -- "--domain";;
    REPO_URL) printf -- "--repo";;
    BRANCH) printf -- "--branch";;
    TRAEFIK_NETWORK) printf -- "--network";;
    CERT_RESOLVER) printf -- "--certresolver";;
    DEPLOY_STRATEGY) printf -- "--strategy";;
    RUNTIME) printf -- "--runtime";;
    INSTALL_COMMAND) printf -- "--install";;
    BUILD_COMMAND) printf -- "--build";;
    START_COMMAND) printf -- "--start";;
    DIST_DIR) printf -- "--dist";;
    INTERNAL_PORT) printf -- "--internal-port";;
    PERSISTENT_MOUNTS) printf -- "--mounts";;
    APP_ENV_FILE) printf -- "--app-env-file";;
    DOCKERFILE_SOURCE) printf -- "--dockerfile-source";;
  esac
}

run_remote() {
  local hash="$1"
  local remote_cmd="./deploy-full.sh --apply --confirmed-plan-hash $(printf '%q' "$hash") --expected-remote-state-hash $(printf '%q' "$REMOTE_STATE_HASH") --source-commit $(printf '%q' "$SOURCE_COMMIT")"
  local key option
  for key in "${CONFIG_KEYS[@]}"; do
    option="$(option_for_key "$key")"
    remote_cmd+=" $option $(printf '%q' "${!key}")"
  done
  [[ "$FORCE_YML" == true ]] && remote_cmd+=" --force-yml"
  [[ "$FORCE_DOCKERFILE" == true ]] && remote_cmd+=" --force-dockerfile"
  log "Executando o plano confirmado no VPS."
  "$SSH_BIN" "$SSH_TARGET" "cd $(printf '%q' "$REMOTE_SCRIPT_DIR") && $remote_cmd"
}

fetch_remote_env() { "$SCP_BIN" "$SSH_TARGET:/compose/volume/$PROJECT_NAME/deploy.env" "$ENV_FILE"; log "Estado local sincronizado apos a verificacao publica."; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) PLAN_ONLY=true; shift;; --print-config-json) PLAN_ONLY=true; PRINT_JSON=true; shift;; --offline) OFFLINE=true; shift;;
    --confirmed-plan-hash) CONFIRMED_PLAN_HASH="${2:-}"; shift 2;; --expected-remote-state-hash) EXPECTED_REMOTE_STATE_HASH="${2:-}"; shift 2;; --source-commit) SOURCE_COMMIT="${2:-}"; shift 2;; --env-file) ENV_FILE="${2:-}"; shift 2;; --ssh-target) SSH_TARGET="${2:-}"; shift 2;; --remote-dir) REMOTE_SCRIPT_DIR="${2:-}"; shift 2;;
    --project|--domain|--repo|--branch|--network|--certresolver|--strategy|--runtime|--install|--build|--start|--dist|--internal-port|--mounts|--app-env-file|--dockerfile-source)
      case "$1" in --project) key=PROJECT_NAME;; --domain) key=DOMAIN;; --repo) key=REPO_URL;; --branch) key=BRANCH;; --network) key=TRAEFIK_NETWORK;; --certresolver) key=CERT_RESOLVER;; --strategy) key=DEPLOY_STRATEGY;; --runtime) key=RUNTIME;; --install) key=INSTALL_COMMAND;; --build) key=BUILD_COMMAND;; --start) key=START_COMMAND;; --dist) key=DIST_DIR;; --internal-port) key=INTERNAL_PORT;; --mounts) key=PERSISTENT_MOUNTS;; --app-env-file) key=APP_ENV_FILE;; --dockerfile-source) key=DOCKERFILE_SOURCE;; esac
      printf -v "OVERRIDE_$key" '%s' "${2:-}"; printf -v "OVERRIDE_SET_$key" '%s' true; shift 2;;
    --redetect) REDETECT=true; shift;; --force-yml) FORCE_YML=true; shift;; --force-dockerfile) FORCE_DOCKERFILE=true; shift;;
    --yes|-y|--dry-run) fail "$1 foi removido: use --plan, confirme no chat e reutilize --confirmed-plan-hash.";;
    --help|-h) usage; exit 0;; *) fail "Opcao desconhecida: $1";;
  esac
done

load_local_env; detect_local_defaults
[[ "$REDETECT" == true ]] && apply_redetection || apply_detected_defaults
apply_overrides; normalize_mounts; validate_config
read_remote_state_hash
resolve_source_commit

if [[ "$PLAN_ONLY" == true ]]; then show_plan; exit 0; fi
[[ "$OFFLINE" == false ]] || fail "--offline so pode ser usado com --plan."
[[ -n "$CONFIRMED_PLAN_HASH" ]] || fail "Execute primeiro com --plan, confirme no chat e informe --confirmed-plan-hash."
[[ -n "$EXPECTED_REMOTE_STATE_HASH" && "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Use exatamente o comando impresso pelo plano confirmado."
actual_hash="$(plan_hash)"; [[ "$CONFIRMED_PLAN_HASH" == "$actual_hash" ]] || fail "O hash informado nao corresponde ao plano atual. Gere e confirme um novo plano."
run_remote "$actual_hash"; fetch_remote_env
