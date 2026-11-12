#!/usr/bin/env bash
# On-host deploy script, installed to /opt/careguide/deploy.sh by EC2 user data.
# Invoked by CI through SSM Run Command.
#
#   deploy.sh <image-tag>   pull + run <image-tag>, smoke-test /health, auto-rollback on failure
#   deploy.sh --rollback    re-deploy the previously running tag
#   deploy.sh --status      print current/previous tags
#
# Config comes from /etc/careguide/deploy.env (written by user data).
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/careguide/deploy.env}"
STATE_DIR="${STATE_DIR:-/opt/careguide}"
CONTAINER_NAME="careguide-app"
HOST_PORT=80
HEALTH_URL="http://127.0.0.1:${HOST_PORT}/health"
HEALTH_RETRIES=20
HEALTH_INTERVAL=3

# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${AWS_REGION:?}" "${ECR_REGISTRY:?}" "${ECR_REPO:?}" "${ENVIRONMENT:?}" "${LOG_GROUP:?}"

IMAGE_REPO="${ECR_REGISTRY}/${ECR_REPO}"
CURRENT_FILE="${STATE_DIR}/current_tag"
PREVIOUS_FILE="${STATE_DIR}/previous_tag"

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

read_tag() { [[ -s "$1" ]] && cat "$1" || true; }

ecr_login() {
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
}

run_container() {
  local tag="$1"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --publish "${HOST_PORT}:8080" \
    --env "ENVIRONMENT=${ENVIRONMENT}" \
    --env "APP_VERSION=${tag}" \
    --env "LOG_LEVEL=INFO" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --memory 384m --cpus 1 \
    --stop-timeout 25 \
    --log-driver awslogs \
    --log-opt "awslogs-region=${AWS_REGION}" \
    --log-opt "awslogs-group=${LOG_GROUP}" \
    --log-opt "awslogs-stream=${ENVIRONMENT}/$(hostname)/${tag}" \
    --log-opt mode=non-blocking \
    "${IMAGE_REPO}:${tag}" >/dev/null
}

smoke_test() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
      log "health check passed (attempt ${i})"
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  log "health check FAILED after ${HEALTH_RETRIES} attempts"
  docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true
  return 1
}

deploy() {
  local new_tag="$1" current
  current="$(read_tag "$CURRENT_FILE")"

  log "deploying ${IMAGE_REPO}:${new_tag} (current: ${current:-none})"
  ecr_login
  docker pull --quiet "${IMAGE_REPO}:${new_tag}" || die "image pull failed; nothing changed"

  run_container "$new_tag"
  if smoke_test; then
    if [[ -n "$current" && "$current" != "$new_tag" ]]; then
      echo "$current" >"$PREVIOUS_FILE"
    fi
    echo "$new_tag" >"$CURRENT_FILE"
    docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
    log "deploy of ${new_tag} succeeded"
    return 0
  fi

  if [[ -n "$current" && "$current" != "$new_tag" ]]; then
    log "rolling back to ${current}"
    run_container "$current"
    smoke_test || die "ROLLBACK to ${current} ALSO FAILED - manual intervention required"
    die "deploy of ${new_tag} failed; rolled back to ${current}"
  fi
  die "deploy of ${new_tag} failed and there is no previous version to roll back to"
}

rollback() {
  local previous current
  previous="$(read_tag "$PREVIOUS_FILE")"
  current="$(read_tag "$CURRENT_FILE")"
  [[ -n "$previous" ]] || die "no previous tag recorded"
  log "manual rollback: ${current:-none} -> ${previous}"
  ecr_login
  run_container "$previous"
  smoke_test || die "rollback target ${previous} is unhealthy"
  echo "$previous" >"$CURRENT_FILE"
  if [[ -n "$current" ]]; then echo "$current" >"$PREVIOUS_FILE"; fi
  log "rollback complete"
}

main() {
  [[ $# -eq 1 ]] || die "usage: $0 <image-tag> | --rollback | --status"
  mkdir -p "$STATE_DIR"
  # Serialize concurrent deploys on this host.
  exec 9>"${STATE_DIR}/.deploy.lock"
  flock -w 300 9 || die "another deploy is in progress"

  case "$1" in
    --rollback) rollback ;;
    --status)
      echo "current=$(read_tag "$CURRENT_FILE")"
      echo "previous=$(read_tag "$PREVIOUS_FILE")"
      ;;
    -*) die "unknown option $1" ;;
    *)
      [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid image tag: $1"
      deploy "$1"
      ;;
  esac
}

main "$@"
