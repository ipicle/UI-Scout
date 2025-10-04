#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://127.0.0.1:18080"
SCENARIO_FILE="$(dirname "$0")/scenarios/basic.json"
SIM_PID=""

usage() {
  echo "Usage: $0 [--base <url>] [--no-sim]" >&2
}

start_simulator() {
  node "$(dirname "$0")/simulator/server.js" --scenario "$SCENARIO_FILE" --port 18080 &
  SIM_PID=$!
  echo "Simulator started (pid=$SIM_PID) on $BASE_URL"
  # wait for server
  for i in {1..30}; do
    if curl -sSf "$BASE_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "Simulator failed to start in time" >&2
  exit 1
}

stop_simulator() {
  if [[ -n "$SIM_PID" ]] && kill -0 "$SIM_PID" >/dev/null 2>&1; then
    kill "$SIM_PID" || true
    wait "$SIM_PID" 2>/dev/null || true
  fi
}

trap stop_simulator EXIT

NO_SIM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      shift; BASE_URL="${1:-$BASE_URL}";;
    --no-sim)
      NO_SIM=1;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
  shift || true
done

if [[ $NO_SIM -eq 0 ]]; then
  start_simulator
fi

fail() { echo "[E2E] FAIL: $*" >&2; exit 1; }
ok() { echo "[E2E] OK: $*"; }

# 1) Health
curl -sSf "$BASE_URL/health" | grep -q '"status":' || fail "health endpoint missing status"
ok "health"

# 2) Find
resp=$(curl -sSf -X POST "$BASE_URL/api/v1/find" \
  -H 'Content-Type: application/json' \
  -d '{"appBundleId":"com.example.app","elementType":"reply"}')
echo "$resp" | grep -q '"confidence":' || fail "find missing confidence"
ok "find"

# 3) After-send diff
resp=$(curl -sSf -X POST "$BASE_URL/api/v1/after-send-diff" \
  -H 'Content-Type: application/json' \
  -d '{"appBundleId":"com.example.app","preSignature":{"appBundleId":"com.example.app","elementType":"reply","role":"Group","subroles":[],"frameHash":"w400-h300-x0-y0@sha1","pathHint":[],"siblingRoles":[],"readOnly":true,"scrollable":true,"attrs":{},"stability":0.8,"lastVerifiedAt":0}}')
echo "$resp" | grep -q '"evidence":' || fail "after-send-diff missing evidence"
ok "after-send-diff"

# 4) Snapshot
resp=$(curl -sSf -X POST "$BASE_URL/api/v1/snapshot" \
  -H 'Content-Type: application/json' \
  -d '{"appBundleId":"com.example.app","signature":{"appBundleId":"com.example.app","elementType":"reply","role":"Group","subroles":[],"frameHash":"w400-h300-x0-y0@sha1","pathHint":[],"siblingRoles":[],"readOnly":true,"scrollable":true,"attrs":{},"stability":0.8,"lastVerifiedAt":0}}')
echo "$resp" | grep -q '"success": true' || fail "snapshot failed"
ok "snapshot"

# 5) Learn
resp=$(curl -sSf -X POST "$BASE_URL/api/v1/learn" \
  -H 'Content-Type: application/json' \
  -d '{"signature":{"appBundleId":"com.example.app","elementType":"reply","role":"Group","subroles":[],"frameHash":"w400-h300-x0-y0@sha1","pathHint":[],"siblingRoles":[],"readOnly":true,"scrollable":true,"attrs":{},"stability":0.8,"lastVerifiedAt":0},"pin":false,"decay":false}')
echo "$resp" | grep -q '"success": true' || fail "learn failed"
ok "learn"

# 6) Status
resp=$(curl -sSf "$BASE_URL/api/v1/status")
echo "$resp" | grep -q '"canOperate":' || fail "status missing canOperate"
ok "status"

# 7) Signatures
resp=$(curl -sSf "$BASE_URL/api/v1/signatures")
echo "$resp" | grep -q '"count":' || fail "signatures missing count"
ok "signatures"

# 8) Observe (SSE) – read a couple of events
out=$(curl -sS "$BASE_URL/api/v1/observe" \
  -H 'Content-Type: application/json' \
  -d '{"appBundleId":"com.example.app","signature":{"appBundleId":"com.example.app","elementType":"reply","role":"Group","subroles":[],"frameHash":"w400-h300-x0-y0@sha1","pathHint":[],"siblingRoles":[],"readOnly":true,"scrollable":true,"attrs":{},"stability":0.8,"lastVerifiedAt":0},"durationSeconds":1}') || true
echo "$out" | head -n 5 | grep -q '^data:' || fail "observe SSE did not stream data"
ok "observe (SSE)"

# 9) Send (AX-safe): ensure actions and diff are present
resp=$(curl -sSf -X POST "$BASE_URL/api/v1/send" \
  -H 'Content-Type: application/json' \
  -d '{"appBundleId":"com.example.app","text":"hello"}')
echo "$resp" | grep -q '"actions"' || fail "send missing actions"
echo "$resp" | grep -q '"diff"' || fail "send missing diff"
echo "$resp" | grep -q '"success": true' || fail "send not successful"
ok "send"

echo "[E2E] All checks passed against $BASE_URL"
