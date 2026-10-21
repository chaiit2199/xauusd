#!/usr/bin/env bash
set -euo pipefail
# Run in the VPS deploy directory (/home/deploy_user/xauusd). env.sh is a
# trusted, operator-managed shell file.
set +x
requested_image="${1:?Pass the immutable image tag}"
if [[ ! -r ./env.sh ]]; then
  echo "ERROR: Missing or unreadable $(pwd)/env.sh" >&2
  exit 1
fi
bash -n ./env.sh
set -a
source ./env.sh
set +a
# Jenkins must override any stale IMAGE_TAG exported by env.sh.
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
code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "http://127.0.0.1:${HTTP_PORT:-5006}/")"
test "$code" != "000"
printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG" > .image.env.tmp
mv .image.env.tmp .image.env
echo "API healthy: $IMAGE_TAG (http status $code)"
