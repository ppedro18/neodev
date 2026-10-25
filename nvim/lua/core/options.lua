local o = vim.opt

vim.g.mapleader = " "
vim.g.maplocalleader = " "

o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.scrolloff = 8

-- Indentación por defecto: 4 espacios (Kotlin/IntelliJ). Angular/TS la pisa
-- a 2 en core/autocmds.lua, y un .editorconfig en el proyecto pisa a ambos
-- (nativo desde nvim 0.9, sin plugin).
vim.g.editorconfig = true
o.tabstop = 4
o.shiftwidth = 4
o.expandtab = true
o.smartindent = true

o.ignorecase = true
o.smartcase = true

o.splitright = true
o.splitbelow = true

o.undofile = true
o.swapfile = false

o.updatetime = 250
o.timeoutlen = 300

o.termguicolors = true
o.wrap = false
