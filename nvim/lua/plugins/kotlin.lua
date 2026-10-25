return {
  {
    -- Capa cliente sobre kotlin-lsp: inlay hints, intentions, refactors y
    -- debugging (via nvim-dap) con paridad respecto al plugin de VS Code.
    "AlexandrosAlexiou/kotlin.nvim",
    ft = { "kotlin" },
    dependencies = {
      "mason-org/mason.nvim",
      "mason-org/mason-lspconfig.nvim",
      "mfussenegger/nvim-dap",
    },
    init = function()
      -- kotlin.nvim busca kotlin-lsp vía Mason primero, y ahí nunca está
      -- (su paquete está roto, instalamos vía Homebrew en install.sh — ver
      -- lsp/kotlin_lsp.lua). Sin esto tira "KOTLIN_LSP_DIR... not set".
      if vim.env.KOTLIN_LSP_DIR == nil and vim.fn.executable("brew") == 1 then
        local prefix = vim.fn.system({ "brew", "--prefix", "kotlin-lsp" }):gsub("%s+$", "")
        if vim.v.shell_error == 0 and prefix ~= "" then
          vim.env.KOTLIN_LSP_DIR = prefix .. "/libexec"
        end
      end
    end,
    opts = {},
  },
}
