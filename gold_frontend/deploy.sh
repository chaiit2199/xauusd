#!/usr/bin/env bash
set -euo pipefail
# Run on the VPS inside gold_frontend after git pull.
# Reverse proxy (Caddy/nginx):
#   https://crypto.9nine.tech/     → 127.0.0.1:3003
#   https://crypto.9nine.tech/api/ → 127.0.0.1:5005   (fallback khi API_BASE_URL rỗng)
# Browser luôn gọi same-origin /api. API_BASE_URL chỉ là đích rewrite
# server-side dự phòng nếu /api đi qua Next thay vì Caddy/nginx.

cd "$(dirname "$0")"

# Không cho biến public cũ làm lộ hostname API vào client bundle.
unset NEXT_PUBLIC_API_URL || true

npm ci
npm run build

export PORT=3003
export HOSTNAME=127.0.0.1
exec npm run start
