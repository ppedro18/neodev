#!/usr/bin/env bash
# Instala todo el entorno (macOS o Linux) con un solo comando:
#   ./install.sh
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

echo "==> NeoDev: instalando dependencias"

if ! command -v brew >/dev/null 2>&1; then
  echo "==> Homebrew no encontrado, instalando..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
fi

echo "==> Instalando paquetes del Brewfile (neovim, git, node, jdk, kotlin, gradle...)"
brew bundle --file="$DOTFILES_DIR/Brewfile"

# El paquete "kotlin-lsp" de Mason apunta a download-cdn.jetbrains.com, que
# da 404 (host roto / build viejo retirado del CDN) — no se puede arreglar
# desde este repo, es un bug del registry de Mason. Lo instalamos aparte.
echo "==> Instalando kotlin-lsp"
if [[ "$(uname -s)" == "Darwin" ]]; then
  brew tap jetbrains/utils
  brew install jetbrains/utils/kotlin-lsp
else
  cat <<'EOF'
    AVISO: JetBrains todavía no publica build de kotlin-lsp para Linux (su
    propia fórmula de Homebrew lo deja explícito: "we don't want to support
    brew packages on Linux" — solo hay artefactos para macOS x64/arm64).

    Alternativa mientras tanto: el LSP comunitario
    https://github.com/fwcd/kotlin-language-server (JVM puro, sí corre en
    Linux). Instálalo con ":MasonInstall kotlin-language-server" dentro de
    nvim, crea nvim/lua/lsp/kotlinlanguageserver.lua con "return {}", y
    agrégalo a la lista `servers` de nvim/lua/plugins/lsp.lua.
EOF
fi

# android-cli (binario "android"): la mitad de los comandos :Droid* de
# plugins/android.lua lo necesitan (DroidLayout, DroidScreenshot, DroidDocs,
# DroidCreate, DroidSdk, DroidLint/Declaration/Usages/Versions/StudioOpen).
# Es de Google, no está en Homebrew, así que no va en el Brewfile — su
# propio instalador ya hace su propio uname/arch y deja el binario en
# ~/.local/bin para macOS y Linux por igual, por eso alcanza con un solo
# curl (probado: el install.sh que sirve es idéntico sea cual sea el
# OS/arch del path, solo cambia qué binario descarga según detecte en
# runtime). Idempotente: si ya está, no lo vuelve a bajar.
echo "==> Instalando android-cli (CLI oficial de Android, usada por los comandos :Droid*)"
if command -v android >/dev/null 2>&1; then
  echo "    Ya está instalado: $(command -v android)"
else
  curl -fsSL "https://dl.google.com/android/cli/latest/darwin_arm64/install.sh" | bash
  export PATH="$PATH:$HOME/.local/bin"
fi

# Sin esto, los íconos de bufferline/neo-tree/lualine salen como "?": son
# glifos de Nerd Font, no texto normal.
echo "==> Instalando Nerd Font (íconos de la UI)"
if [[ "$(uname -s)" == "Darwin" ]]; then
  brew install --cask font-jetbrains-mono-nerd-font
else
  mkdir -p "$HOME/.local/share/fonts"
  curl -fsSL -o /tmp/JetBrainsMono.zip \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
  unzip -o -q /tmp/JetBrainsMono.zip -d "$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
  command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$HOME/.local/share/fonts"
fi

# Terminal.app (la nativa de macOS) no deja elegir la fuente por config file,
# solo por GUI — Ghostty sí, así que la dejamos lista sin pasos manuales.
echo "==> Instalando Ghostty (terminal) y configurando su fuente"
mkdir -p "$HOME/.config/ghostty"
cp "$DOTFILES_DIR/ghostty.config" "$HOME/.config/ghostty/config"
if [[ "$(uname -s)" == "Darwin" ]]; then
  brew install --cask ghostty
else
  echo "    (Linux: instala Ghostty desde https://ghostty.org/download — su"
  echo "     config ya quedó en ~/.config/ghostty/config)"
fi

if [[ -L "$NVIM_CONFIG_DIR" ]]; then
  rm "$NVIM_CONFIG_DIR"
elif [[ -e "$NVIM_CONFIG_DIR" ]]; then
  BACKUP="$NVIM_CONFIG_DIR.backup.$(date +%Y%m%d%H%M%S)"
  echo "==> Encontré una config previa, la respaldo en $BACKUP"
  mv "$NVIM_CONFIG_DIR" "$BACKUP"
fi

mkdir -p "$(dirname "$NVIM_CONFIG_DIR")"
ln -s "$DOTFILES_DIR/nvim" "$NVIM_CONFIG_DIR"
echo "==> Enlazado $DOTFILES_DIR/nvim -> $NVIM_CONFIG_DIR"

echo "==> Instalando plugins (lazy.nvim)"
nvim --headless "+Lazy! sync" +qa

echo "==> Instalando LSP/DAP (mason: kotlin-lsp, angular, typescript, eslint)"
# Sync, no Install: la versión async cierra nvim (+qa) antes de que Mason
# termine de descargar en segundo plano y todo queda "Installation aborted".
nvim --headless "+MasonToolsInstallSync" +qa

cat <<'EOF'

==> Listo.

Siguientes pasos:
  1. Abre nvim y corre :checkhealth para confirmar que todo cargó bien.
  2. Para proyectos Android, define ANDROID_HOME apuntando a tu SDK
     existente (el de Android Studio, por ejemplo) en tu shell rc:
       export ANDROID_HOME="$HOME/Library/Android/sdk"   # macOS
       export ANDROID_HOME="$HOME/Android/Sdk"           # Linux
     Asegúrate también de que "$ANDROID_HOME/platform-tools" (adb) y
     "$ANDROID_HOME/emulator" estén en tu PATH, y de tener al menos un AVD
     creado (Android Studio > Device Manager, o `avdmanager create avd`).
  3. `brew info openjdk@21` muestra el export de JAVA_HOME que Homebrew
     recomienda si tu shell no lo detecta solo.
  4. Para GitHub desde nvim (octo.nvim): corre `gh auth login` una vez.
  5. Abre Ghostty (ya instalado y con la fuente/tema configurados solo) y
     usa nvim desde ahí. Si preferís seguir con Terminal.app/iTerm2, elegí
     "JetBrainsMono Nerd Font" a mano en sus preferencias de texto — si no,
     los íconos salen como "?".
  6. IMPORTANTE: los plugins nuevos no aparecen en una sesión de nvim que
     ya tenías abierta. Cerrala del todo (:qa) y abrí una nueva.

Para revertir: ./uninstall.sh
EOF

# android-cli quedó en ~/.local/bin, agregado al PATH en el rc de tu shell
# (paso de arriba) — pero eso solo lo ve una terminal NUEVA: esta misma,
# la que corrió ./install.sh, sigue con el PATH de antes de empezar. En vez
# de pedirte que te acuerdes de abrir otra o hacer `source`, si esto es
# interactivo (hay una terminal real, no CI/un pipe) reemplazamos este shell
# por uno nuevo que relee tu rc solo: `android` (y todo lo demás que tocó
# este script) queda disponible sin que hagas nada más.
if [[ -t 0 && -t 1 ]]; then
  echo "==> Recargando el shell para que el PATH quede listo ya mismo..."
  exec "$SHELL" -l
fi
