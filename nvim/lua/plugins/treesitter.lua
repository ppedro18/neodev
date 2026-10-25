-- API nueva de nvim-treesitter (rama "main"): ya no existe
-- `nvim-treesitter.configs`. Parsers se instalan con `.install()`, y
-- highlight/indent se activan a mano por FileType (no hay más
-- `highlight = { enable = true }`).
return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").install({
        -- Kotlin / Android: .kt, .kts, build.gradle, layouts/manifest/res, libs.versions.toml
        "kotlin", "java", "groovy", "xml", "toml",
        -- Angular / TypeScript
        "typescript", "tsx", "javascript", "html", "css", "scss",
        -- Compartido
        "json", "yaml", "lua", "vim", "vimdoc", "bash", "markdown",
      })

      vim.api.nvim_create_autocmd("FileType", {
        callback = function()
          local ok = pcall(vim.treesitter.start)
          if ok then
            vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })
    end,
  },
}
