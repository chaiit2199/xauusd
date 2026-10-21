#!/usr/bin/env bash
set -euo pipefail
# Run on the VPS inside gold_frontend after git pull.
# Nginx must proxy:
#   https://crypto.9nine.tech/     → 127.0.0.1:3003
#   https://crypto.9nine.tech/api/ → 127.0.0.1:5005
#
# Same-origin /api = no browser CORS. Never bake api-crypto into the client.

cd "$(dirname "$0")"

# .env.local overrides .env.production during `next build` — move it aside.
if [[ -f .env.local ]]; then
  mv .env.local ".env.local.bak.$(date +%s)"
  echo "Moved .env.local aside so production build stays same-origin."
fi

unset NEXT_PUBLIC_API_URL || true
unset API_BASE_URL || true

# Explicit empty for this shell (belt and suspenders).
export NEXT_PUBLIC_API_URL=

npm ci
npm run build

export PORT=3003
export HOSTNAME=127.0.0.1
exec npm run start
