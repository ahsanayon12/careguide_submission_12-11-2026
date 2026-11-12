#!/usr/bin/env bash
#
# Demonstrates a zero-downtime rolling update (1.0.0 -> 1.1.0) and a rollback with
# `kubectl rollout undo`, while a background loop hits the Service continuously and
# counts failed requests. Output is meant to be pasted into the README.
#
# Prereqs: `make kind-up k8s-deploy` (cluster, ingress, image 1.0.0 loaded, manifests applied).
#
set -euo pipefail

NS="${NS:-careguide}"
CLUSTER="${KIND_CLUSTER:-careguide}"
IMAGE="${IMAGE:-careguide-api}"
OLD="${OLD_VERSION:-1.0.0}"
NEW="${NEW_VERSION:-1.1.0}"
URL="${URL:-http://careguide.localtest.me/}"
LOG="$(mktemp)"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

cleanup() {
  [[ -n "${LOAD_PID:-}" ]] && kill "$LOAD_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

traffic() {
  # One request every 100 ms; record HTTP code + reported version.
  while true; do
    curl -s -m 2 -o /dev/null -w '%{http_code}\n' "$URL" >>"$LOG" || echo "000" >>"$LOG"
    sleep 0.1
  done
}

summary() {
  local total ok failed
  total=$(wc -l <"$LOG")
  ok=$(grep -c '^200$' "$LOG" || true)
  failed=$((total - ok))
  printf 'requests: %d  ok: %d  failed: %d\n' "$total" "$ok" "$failed"
  : >"$LOG"
}

step "Build ${IMAGE}:${NEW} and load it into kind"
docker build -q --target runtime --build-arg APP_VERSION="$NEW" -t "${IMAGE}:${NEW}" .
kind load docker-image "${IMAGE}:${NEW}" --name "$CLUSTER"

step "Current state"
kubectl -n "$NS" get deploy,pods,hpa -o wide
curl -s "$URL"; echo

step "Start background traffic against ${URL}"
traffic &
LOAD_PID=$!
sleep 2

step "Rolling update to ${NEW}"
kubectl -n "$NS" set image deployment/careguide-api api="${IMAGE}:${NEW}"
kubectl -n "$NS" annotate deployment/careguide-api kubernetes.io/change-cause="upgrade to ${NEW}" --overwrite
kubectl -n "$NS" rollout status deployment/careguide-api --timeout=180s
sleep 2
curl -s "$URL"; echo
summary

step "Rollout history"
kubectl -n "$NS" rollout history deployment/careguide-api

step "Rollback with kubectl rollout undo"
kubectl -n "$NS" rollout undo deployment/careguide-api
kubectl -n "$NS" rollout status deployment/careguide-api --timeout=180s
sleep 2
curl -s "$URL"; echo
summary

step "Final state"
kubectl -n "$NS" get pods -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready'
kubectl -n "$NS" rollout history deployment/careguide-api
echo "Expected: failed: 0 in both summaries (zero downtime), version back to ${OLD}."
