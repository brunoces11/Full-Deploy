#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/deploy-full-local.sh"
REMOTE="$ROOT_DIR/deploy-full.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

common=(--plan --offline --project test-app --domain example.test --repo https://example.test/repo.git --branch main --network traknet --certresolver le)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected '$2'"; }
run_plan() { (cd "$1" && bash "$WRAPPER" "${common[@]}"); }

mkdir -p "$WORK_DIR/html"
printf '<!doctype html><title>HTML</title>' > "$WORK_DIR/html/index.html"
html_plan="$(run_plan "$WORK_DIR/html")"
assert_contains "$html_plan" 'DEPLOY_STRATEGY=static'
assert_contains "$html_plan" 'RUNTIME=custom'
assert_contains "$html_plan" 'DIST_DIR=.'

mkdir -p "$WORK_DIR/vite"
printf 'export default {}\n' > "$WORK_DIR/vite/vite.config.ts"
printf '{"scripts":{"build":"vite build"}}\n' > "$WORK_DIR/vite/package.json"
vite_plan="$(run_plan "$WORK_DIR/vite")"
assert_contains "$vite_plan" 'DEPLOY_STRATEGY=static'
assert_contains "$vite_plan" 'DIST_DIR=dist'

mkdir -p "$WORK_DIR/vinext-runtime"
printf '{"dependencies":{"vinext":"latest"},"scripts":{"build":"vinext build","start":"vinext start"}}\n' > "$WORK_DIR/vinext-runtime/package.json"
runtime_plan="$(run_plan "$WORK_DIR/vinext-runtime")"
assert_contains "$runtime_plan" 'DEPLOY_STRATEGY=runtime'
assert_contains "$runtime_plan" 'INTERNAL_PORT=3000'

mkdir -p "$WORK_DIR/vinext-export"
printf '{"dependencies":{"vinext":"latest"},"scripts":{"build":"vinext build"}}\n' > "$WORK_DIR/vinext-export/package.json"
printf 'export default { output: "export" }\n' > "$WORK_DIR/vinext-export/next.config.ts"
export_plan="$(run_plan "$WORK_DIR/vinext-export")"
assert_contains "$export_plan" 'DEPLOY_STRATEGY=static'
assert_contains "$export_plan" 'DIST_DIR=out'

custom_port="$(cd "$WORK_DIR/vinext-runtime" && bash "$WRAPPER" "${common[@]}" --internal-port 4312)"
assert_contains "$custom_port" 'INTERNAL_PORT=4312'

if (cd "$WORK_DIR/html" && bash "$WRAPPER" "${common[@]}" --yes >/dev/null 2>&1); then
  fail '--yes must be rejected'
fi

if bash "$REMOTE" --apply --confirmed-plan-hash invalid --expected-remote-state-hash absent --project test-app --domain example.test --repo-url https://example.test/repo.git --branch main --traefik-network traknet --cert-resolver le --deploy-strategy static --runtime custom --dist-dir . --internal-port 80 >/dev/null 2>&1; then
  fail 'remote must reject a mismatched plan hash before any mutation'
fi

grep -Fq 'test -f "/app/$DIST_DIR/index.html"' "$REMOTE" || fail 'static index.html build guard is missing'
grep -Fq 'Dockerfile.deploy.dockerignore' "$REMOTE" || fail 'deploy-specific dockerignore is missing'

printf 'All full-deploy regression checks passed.\n'
