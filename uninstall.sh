#!/usr/bin/env bash
# Quita el symlink creado por install.sh y restaura el backup más reciente
# de tu config anterior de nvim, si existía.
set -euo pipefail

NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

if [[ -L "$NVIM_CONFIG_DIR" ]]; then
  rm "$NVIM_CONFIG_DIR"
  echo "==> Symlink eliminado: $NVIM_CONFIG_DIR"
else
  echo "==> $NVIM_CONFIG_DIR no es un symlink de este repo, no se tocó."
  exit 0
fi

LATEST_BACKUP=$(ls -dt "$NVIM_CONFIG_DIR".backup.* 2>/dev/null | head -1 || true)
if [[ -n "$LATEST_BACKUP" ]]; then
  mv "$LATEST_BACKUP" "$NVIM_CONFIG_DIR"
  echo "==> Restaurado: $LATEST_BACKUP -> $NVIM_CONFIG_DIR"
else
  echo "==> No había backup; $NVIM_CONFIG_DIR queda vacío."
fi
