#!/usr/bin/env bash
# Reaplica la config y los parches sin reinstalar Homebrew/fuentes/etc.
# Uso: ./refresh.sh
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

echo "==> NeoDev: refresh"

if [[ -L "$NVIM_CONFIG_DIR" ]]; then
  TARGET="$(readlink "$NVIM_CONFIG_DIR")"
  if [[ "$TARGET" == "$DOTFILES_DIR/nvim" ]]; then
    echo "==> Symlink OK: $NVIM_CONFIG_DIR -> $TARGET"
  else
    echo "==> AVISO: $NVIM_CONFIG_DIR apunta a $TARGET (no a este repo)"
  fi
elif [[ -e "$NVIM_CONFIG_DIR" ]]; then
  BACKUP="$NVIM_CONFIG_DIR.backup.$(date +%Y%m%d%H%M%S)"
  echo "==> Config física detectada, respaldando en $BACKUP"
  mv "$NVIM_CONFIG_DIR" "$BACKUP"
  ln -s "$DOTFILES_DIR/nvim" "$NVIM_CONFIG_DIR"
  echo "==> Enlazado $DOTFILES_DIR/nvim -> $NVIM_CONFIG_DIR"
else
  mkdir -p "$(dirname "$NVIM_CONFIG_DIR")"
  ln -s "$DOTFILES_DIR/nvim" "$NVIM_CONFIG_DIR"
  echo "==> Enlazado $DOTFILES_DIR/nvim -> $NVIM_CONFIG_DIR"
fi

echo "==> Sincronizando plugins (Lazy)"
nvim --headless "+Lazy! sync" +qa

echo "==> Listo. Cierra y abre nvim de nuevo."
