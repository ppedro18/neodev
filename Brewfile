# Funciona igual en macOS y Linux (Homebrew soporta ambos).
# Ejecutado por install.sh vía `brew bundle`.

brew "neovim"
brew "git"
brew "gh"        # GitHub CLI, usado por octo.nvim (PRs/issues)
brew "ripgrep"   # usado por Telescope (live grep)
brew "fd"        # usado por Telescope (find files)
brew "lazygit"   # TUI de git, se abre desde nvim
brew "wget"      # el instalador de Mason para kotlin-lsp lo necesita (no
                 # viene de fábrica en macOS) para bajar el .sit de JetBrains
brew "yazi"      # gestor de archivos flotante (plugins/ui.lua, yazi.nvim)
brew "tree-sitter-cli" # compila los parsers (plugins/treesitter.lua, rama
                 # "main" de nvim-treesitter lo necesita; OJO: el formula
                 # "tree-sitter" a secas es solo la librería, no el CLI
brew "scrcpy"    # espejar pantalla del emulador/device (plugins/android.lua,
                 # <leader>am / :DroidMirror)
# La Nerd Font (íconos de bufferline/neo-tree/lualine) NO va acá: los cask
# de Homebrew son solo-macOS y este Brewfile tiene que andar en Linux
# también. install.sh la instala aparte, condicionada al SO.

# Angular / TypeScript
brew "node"

# Kotlin / Android (JVM toolchain)
brew "openjdk@21"
brew "kotlin"
brew "gradle"
