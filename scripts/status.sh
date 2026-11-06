#!/usr/bin/env bash
# Где что: ветка и есть ли незакоммиченные правки в каждом репозитории
cd "$(dirname "$0")/../.." || exit
# shellcheck source=repos.sh
source payments-local/scripts/repos.sh
for repo in payments-local $REPOS; do
  [ -d "$repo/.git" ] || { printf '%-24s не склонирован\n' "$repo"; continue; }
  changes=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')
  printf '%-24s %-28s %s\n' "$repo" "$(git -C "$repo" branch --show-current)" "$( [ "$changes" = 0 ] && echo чисто || echo "правок: $changes")"
done
