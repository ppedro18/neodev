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

map("v", "<", "<gv", { desc = "Indentar izquierda" })
map("v", ">", ">gv", { desc = "Indentar derecha" })
