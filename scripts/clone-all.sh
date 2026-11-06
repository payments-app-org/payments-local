#!/usr/bin/env bash
# Клонирует все репозитории проекта рядом с payments-local (в общую папку). Уже склонированные пропускает.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit
# shellcheck source=repos.sh
source payments-local/scripts/repos.sh
# CLAUDE.md общей папки: подключает документацию проекта, чтобы она была видна из любого репозитория
[ -f CLAUDE.md ] || printf '@payments-local/CLAUDE.md\n' > CLAUDE.md
for repo in $REPOS; do
  if [ -d "$repo/.git" ]; then
    echo "$repo — уже есть"
  else
    git clone -q "git@github.com:$ORG/$repo.git" && echo "$repo — склонирован"
  fi
done
