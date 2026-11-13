#!/usr/bin/env bash
# Поднимает всё приложение. Токен для скачивания payments-platform: GITHUB_TOKEN из .env, иначе — из gh.
# Аргументы передаются в docker compose up (например: scripts/up.sh payment — пересобрать только payment).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${GITHUB_TOKEN:-}" ] && ! grep -q '^GITHUB_TOKEN=.' .env 2>/dev/null; then
  GITHUB_TOKEN=$(gh auth token) || { echo "Нет токена: задайте GITHUB_TOKEN в .env или войдите в gh (gh auth login)"; exit 1; }
  export GITHUB_TOKEN
fi
# Пароли Keycloak (админ и демо-пользователь): нет в .env — сгенерировать и дописать один раз
for name in KEYCLOAK_ADMIN_PASSWORD DEMO_PASSWORD; do
  if ! grep -q "^$name=." .env 2>/dev/null; then
    sed -i.bak "/^$name=/d" .env 2>/dev/null && rm -f .env.bak
    echo "$name=$(openssl rand -hex 16)" >> .env
    echo "В .env добавлен $name"
  fi
done
docker compose up -d --build "$@"
