#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAZY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"

echo "==> Aplicando parches de nvim-kotlin"

if [[ ! -d "$LAZY_DIR" ]]; then
  echo "==> Carpeta $LAZY_DIR no encontrada. Ejecuta primero :Lazy sync en nvim o instala con ./install.sh"
  exit 0
fi

# android.nvim: copia cada *.lua de patches/android.nvim/ a lua/android/ del
# plugin instalado. Un solo loop en vez de un if por archivo, para que un
# archivo nuevo (ej. cli.lua, sdk.lua) se aplique solo con dejarlo en esa carpeta.
if [[ -d "$LAZY_DIR/android.nvim" ]]; then
  for patch in "$DOTFILES_DIR"/patches/android.nvim/*.lua; do
    cp "$patch" "$LAZY_DIR/android.nvim/lua/android/$(basename "$patch")"
    echo "==> Patch aplicado: android.nvim/lua/android/$(basename "$patch")"
  done
fi

echo "==> Parches aplicados. Cierra y vuelve a abrir nvim para que se carguen."
