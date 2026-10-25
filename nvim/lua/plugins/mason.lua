return {
  {
    "mason-org/mason.nvim",
    build = ":MasonUpdate",
    opts = {},
  },

  {
    "mason-org/mason-lspconfig.nvim",
    dependencies = { "mason-org/mason.nvim", "neovim/nvim-lspconfig" },
    opts = {},
  },

  {
    -- Garantiza que los servidores/herramientas de lsp.lua estén instalados
    -- tras `nvim --headless "+MasonToolsInstallSync" +qa` (install.sh).
    -- kotlin-lsp NO está acá: el paquete de Mason está roto (descarga de
    -- un host que da 404) — install.sh lo instala aparte, vía Homebrew.
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    dependencies = { "mason-org/mason.nvim" },
    opts = {
      ensure_installed = {
        -- Kotlin / Android (prioridad)
        "ktlint", -- formatter + linter, ver plugins/quality.lua
        -- XML (layouts, AndroidManifest.xml, res/*.xml) — compartido pero
        -- solo relevante si tu proyecto Android usa Views además de Compose
        "lemminx",
        -- Angular / TypeScript (secundario)
        "typescript-language-server",
        "angular-language-server",
        "eslint-lsp",
      },
    },
  },
}
