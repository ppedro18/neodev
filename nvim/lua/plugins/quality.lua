-- Formato y lint por lenguaje, separado del motor LSP (lsp.lua): kotlin-lsp
-- ya ofrece un formatter vía LSP, pero ktlint es el estándar real en
-- proyectos Android/CI, así que lo usamos para .kt y dejamos el LSP como
-- fallback para cualquier otro filetype.
return {
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = "ConformInfo",
    keys = {
      {
        "<leader>f",
        function() require("conform").format({ async = true, lsp_fallback = true }) end,
        desc = "Formatear",
      },
    },
    opts = {
      formatters_by_ft = {
        kotlin = { "ktlint" },
      },
      format_on_save = { timeout_ms = 1000, lsp_fallback = true },
    },
  },

  {
    "mfussenegger/nvim-lint",
    event = { "BufWritePost", "InsertLeave" },
    opts = {
      linters_by_ft = {
        kotlin = { "ktlint" },
      },
    },
    config = function(_, opts)
      local lint = require("lint")
      lint.linters_by_ft = opts.linters_by_ft
      vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
        callback = function() lint.try_lint() end,
      })
    end,
  },

  {
    -- Lista navegable de todos los diagnósticos del proyecto/buffer (no solo
    -- el de la línea actual). Responde directo a "que me indiquen bien los
    -- errores": un solo panel con todo, en vez de ir de error en error.
    "folke/trouble.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    cmd = "Trouble",
    keys = {
      { "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", desc = "Diagnósticos (proyecto)" },
      { "<leader>xb", "<cmd>Trouble diagnostics toggle filter.buf=0<CR>", desc = "Diagnósticos (pestaña)" },
    },
    opts = {},
  },
}
