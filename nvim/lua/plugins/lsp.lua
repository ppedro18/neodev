-- Motor LSP genérico: no conoce detalles de ningún lenguaje en particular.
-- Cada servidor se declara en lua/lsp/<nombre>.lua; añadir un lenguaje nuevo
-- es añadir un archivo ahí + su nombre en la lista de abajo (OCP).
local servers = {
  "kotlin_lsp", -- prioridad: Kotlin / Android
  "lemminx", -- Kotlin / Android: layouts XML, AndroidManifest.xml, res/*.xml
  "angularls", -- secundario: Angular
  "ts_ls", -- secundario: TypeScript plano
  "eslint",
}

return {
  {
    "neovim/nvim-lspconfig",
    dependencies = { "mason-org/mason-lspconfig.nvim" },
    config = function()
      for _, name in ipairs(servers) do
        local ok, server_opts = pcall(require, "lsp." .. name)
        vim.lsp.config(name, ok and server_opts or {})
        vim.lsp.enable(name)
      end

      vim.diagnostic.config({
        virtual_text = { spacing = 2, source = "if_many", prefix = "●" },
        severity_sort = true,
        underline = true,
        float = { border = "rounded", source = true },
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = "✘",
            [vim.diagnostic.severity.WARN] = "▲",
            [vim.diagnostic.severity.INFO] = "●",
            [vim.diagnostic.severity.HINT] = "○",
          },
        },
      })

      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local map = function(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, { buffer = args.buf, desc = desc })
          end
          map("n", "gd", vim.lsp.buf.definition, "Ir a definición")
          map("n", "gr", vim.lsp.buf.references, "Referencias")
          map("n", "K", vim.lsp.buf.hover, "Documentación")
          map("n", "<leader>rn", vim.lsp.buf.rename, "Renombrar")
          map("n", "<leader>ca", vim.lsp.buf.code_action, "Code action")
          -- <leader>f (formatear) lo define plugins/quality.lua: usa ktlint
          -- en .kt y cae a este LSP si el filetype no tiene formatter propio.
          map("n", "[d", vim.diagnostic.goto_prev, "Diagnóstico anterior")
          map("n", "]d", vim.diagnostic.goto_next, "Diagnóstico siguiente")
          map("n", "<leader>de", function() vim.diagnostic.open_float() end, "Ver error en detalle")

          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client and client:supports_method("textDocument/inlayHint") then
            vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
          end
        end,
      })
    end,
  },
}
