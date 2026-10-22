#!/usr/bin/env bash
set -euo pipefail
# Run on the VPS inside gold_frontend after git pull.
# Reverse proxy (Caddy/nginx):
#   https://crypto.9nine.tech/     → 127.0.0.1:3003
#   https://crypto.9nine.tech/api/ → 127.0.0.1:5005   (fallback khi API_BASE_URL rỗng)
# API base được đọc từ API_BASE_URL (đặt trong .env.local của VPS hoặc export
# trước khi chạy deploy.sh); để trống = same-origin /api, không cần CORS.

cd "$(dirname "$0")"

# Giữ nguyên .env.local của VPS: nó chứa API_BASE_URL cho `next build`.
unset NEXT_PUBLIC_API_URL || true

npm ci
npm run build

export PORT=3003
export HOSTNAME=127.0.0.1
exec npm run start
