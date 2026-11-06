#!/usr/bin/env bash
# Обновляет main во всех репозиториях проекта. Репозиторий не на main или с незакоммиченными правками — пропускает.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit
# shellcheck source=repos.sh
source payments-local/scripts/repos.sh
for repo in payments-local $REPOS; do
  [ -d "$repo/.git" ] || { echo "$repo — не склонирован (scripts/clone-all.sh)"; continue; }
  branch=$(git -C "$repo" branch --show-current)
  if [ "$branch" != main ] || [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "$repo — пропущен: ветка $branch$( [ -n "$(git -C "$repo" status --porcelain)" ] && echo ', есть правки')"
  else
    git -C "$repo" pull -q --ff-only && echo "$repo — обновлён"
  fi
done
