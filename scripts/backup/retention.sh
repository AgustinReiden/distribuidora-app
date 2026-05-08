#!/usr/bin/env bash
# Aplica politica de retencion sobre backups en rclone remote.
#
# Politica:
#   daily/   -> mantener ultimos 7 archivos
#   weekly/  -> mantener ultimos 4 archivos
#   monthly/ -> mantener ultimos 12 archivos
#
# Uso:
#   ./retention.sh gdrive:Backups/distribuidora-app
#
# Requiere: rclone configurado con el remote indicado.

set -euo pipefail

REMOTE="${1:-}"
if [ -z "$REMOTE" ]; then
  echo "Uso: $0 <rclone-remote-path>" >&2
  echo "Ejemplo: $0 gdrive:Backups/distribuidora-app" >&2
  exit 1
fi

prune_tier() {
  local tier="$1"
  local keep="$2"
  local path="$REMOTE/$tier"

  echo "[retention] Tier=$tier keep=$keep path=$path"

  # Listar archivos ordenados por nombre (YYYY-MM-DD ordena cronologicamente)
  # Filtrar solo .sql.gpg para no tocar nada mas
  local files
  files=$(rclone lsf "$path" --files-only --include '*.sql.gpg' 2>/dev/null | sort)

  if [ -z "$files" ]; then
    echo "[retention] $tier: sin archivos, skip"
    return
  fi

  local total
  total=$(echo "$files" | wc -l)
  echo "[retention] $tier: $total archivos encontrados"

  if [ "$total" -le "$keep" ]; then
    echo "[retention] $tier: <= $keep, nada que podar"
    return
  fi

  local to_delete
  to_delete=$(echo "$files" | head -n "$((total - keep))")

  echo "[retention] $tier: borrando $((total - keep)) archivos viejos"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    echo "[retention]   delete $tier/$f"
    rclone deletefile "$path/$f"
  done <<< "$to_delete"
}

prune_tier daily 7
prune_tier weekly 4
prune_tier monthly 12

echo "[retention] OK"
