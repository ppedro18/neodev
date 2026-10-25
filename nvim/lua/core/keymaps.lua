-- Solo mapeos globales que no pertenecen a ningún plugin.
-- Los mapeos de un plugin viven en su propio archivo (lua/plugins/*.lua).
local map = vim.keymap.set

map("i", "jk", "<Esc>", { desc = "Salir de insert mode" })
map("n", "<Esc>", "<cmd>nohlsearch<CR>")

map("n", "<C-h>", "<C-w>h", { desc = "Ventana izquierda" })
map("n", "<C-j>", "<C-w>j", { desc = "Ventana abajo" })
map("n", "<C-k>", "<C-w>k", { desc = "Ventana arriba" })
map("n", "<C-l>", "<C-w>l", { desc = "Ventana derecha" })

map("n", "<leader>w", "<cmd>w<CR>", { desc = "Guardar" })
map("n", "<leader>q", "<cmd>q<CR>", { desc = "Cerrar ventana" })

-- Cheatsheet propio estilo NvChad (nvim/lua/core/cheatsheet.lua), no el
-- popup de which-key: pantalla completa con TODOS los atajos reales
-- agrupados por categoría, auto-generada desde vim.api.nvim_get_keymap()
-- (nunca puede mostrar uno que no exista — a diferencia del spec "a mano"
-- que tenía esta misma entrada antes, sin keymap real detrás).
map("n", "<leader><leader>", function() require("core.cheatsheet").show() end, { desc = "Leader Espacio · Ver todos los atajos" })

map("v", "<", "<gv", { desc = "Indentar izquierda" })
map("v", ">", ">gv", { desc = "Indentar derecha" })
