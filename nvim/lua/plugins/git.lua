-- LazyGit en una ventana flotante usando :terminal nativo (sin plugin de
-- terminal extra). Requiere el binario `lazygit` del Brewfile.
--
-- cwd explícito, no el de Neovim: en un monorepo con muchos módulos (este),
-- el cwd de Neovim fácilmente termina siendo una carpeta contenedora (ej.
-- después de un <leader>fo a una carpeta que no es ningún repo puntual) en
-- vez del repo del archivo que estás mirando — ahí LazyGit tira "Not in a
-- git repository" aunque el archivo SÍ esté en un repo real. Buscamos el
-- .git más cercano al archivo actual y abrimos LazyGit ahí directo.
local function open_lazygit()
  local file = vim.api.nvim_buf_get_name(0)
  local start = file ~= "" and vim.fs.dirname(file) or vim.fn.getcwd()
  local git_root = vim.fs.root(start, ".git") or vim.fn.getcwd()

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.9)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.fn.termopen("lazygit", {
    cwd = git_root,
    on_exit = function() vim.cmd.close() end,
  })
  vim.cmd.startinsert()
  vim.keymap.set("t", "<Esc>", "<cmd>close<CR>", { buffer = buf })
end

vim.keymap.set("n", "<leader>gg", open_lazygit, { desc = "LazyGit" })

return {
  {
    "lewis6991/gitsigns.nvim",
    event = "VeryLazy",
    opts = {},
  },

  {
    -- Diff de verdad por archivo (como el "Changes" de un IDE o un PR en
    -- GitHub), no el diff en línea de gitsigns. :DiffviewClose para
    -- cerrarlo.
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<CR>", desc = "Diff (cambios sin commitear)" },
    },
  },

  {
    -- PRs e issues de GitHub sin salir de nvim. Usa `gh` (Brewfile) para
    -- autenticarse: corre `gh auth login` una vez por tu cuenta.
    "pwntester/octo.nvim",
    cmd = "Octo",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
      "nvim-tree/nvim-web-devicons",
    },
    opts = { picker = "telescope" },
    keys = {
      { "<leader>go", "<cmd>Octo pr list<CR>", desc = "GitHub: listar PRs" },
      { "<leader>gi", "<cmd>Octo issue list<CR>", desc = "GitHub: listar issues" },
    },
  },
}
