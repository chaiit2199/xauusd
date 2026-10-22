#!/usr/bin/env bash
set -euo pipefail
# Run in the VPS deploy directory (/home/deploy_user/xauusd). env.sh is a
# trusted, operator-managed shell file.
# Usage:
#   bash deploy.sh registry/image:immutable-tag  # Jenkins/new deployment
#   bash deploy.sh                               # recreate last deployed image
set +x
requested_image="${1:-}"
if [[ ! -r ./env.sh ]]; then
  echo "ERROR: Missing or unreadable $(pwd)/env.sh" >&2
  exit 1
fi
bash -n ./env.sh
set -a
source ./env.sh
set +a

# Compose passes these variables to the container; rel/env.sh.eex is not copied
# into the Docker image. Report missing configuration without printing secrets.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [[ -z "${TELEGRAM_BOT_TOKEN//[[:space:]]/}" || -z "${TELEGRAM_CHAT_ID//[[:space:]]/}" ]]; then
  echo "WARNING: Telegram needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in $PWD/env.sh; notifications will not be sent." >&2
fi

# Jenkins always passes an immutable image. For an operator-triggered recreate,
# reuse the image recorded after the last healthy deployment.
if [[ -z "$requested_image" && -r ./.image.env ]]; then
  while IFS='=' read -r key value; do
    if [[ "$key" == "IMAGE_TAG" && -n "$value" ]]; then
      requested_image="$value"
    fi
  done < ./.image.env
fi

if [[ -z "$requested_image" ]]; then
  requested_image="${IMAGE_TAG:-}"
fi

# A server installed before .image.env was introduced can still be recreated
# safely by reusing the exact image reference of the running API container.
# This fallback is intentionally last so Jenkins, .image.env, and env.sh keep
# their existing precedence.
if [[ -z "$requested_image" ]]; then
  requested_image="$(
    docker inspect --format '{{.Config.Image}}' xauusd-api-1 2>/dev/null || true
  )"
fi

if [[ -z "$requested_image" ]]; then
  echo "ERROR: Pass an image tag; no recorded or running API image was found" >&2
  exit 1
fi

# A Jenkins argument or .image.env must override stale values from env.sh.
export IMAGE_TAG="$requested_image"
exec 9>.deploy.lock
flock -n 9 || { echo 'Another deployment is running'; exit 1; }
docker compose --env-file /dev/null config --quiet
docker compose --env-file /dev/null pull api
docker compose --env-file /dev/null up -d --wait --wait-timeout 120 db
docker compose --env-file /dev/null run --rm --no-deps -T api eval 'GoldBackend.Release.migrate()' < /dev/null
docker compose --env-file /dev/null up -d --no-deps --force-recreate --wait --wait-timeout 180 api
container_id="$(docker compose --env-file /dev/null ps -q api)"
test "$(docker inspect --format '{{.Config.Image}}' "$container_id")" = "$IMAGE_TAG"
code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "http://127.0.0.1:${HTTP_PORT:-5005}/api/health")"
if [[ "$code" != "200" ]]; then
  echo "ERROR: API health check failed (http status $code); expected 200 from /api/health" >&2
  docker compose --env-file /dev/null logs --tail=80 api >&2 || true
  exit 1
fi
printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG" > .image.env.tmp
mv .image.env.tmp .image.env
echo "API healthy: $IMAGE_TAG (http status $code)"
