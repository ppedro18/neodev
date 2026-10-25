-- Cheatsheet estilo NvChad (ver NvChad/ui, lua/nvchad/cheatsheet/{init,grid}.lua
-- — el layout tipo masonry de ahí es la referencia real, no una copia a ojo).
-- Dos diferencias a propósito, no por limitación:
--   1. NvChad arma el título de cada tarjeta leyendo la primera palabra del
--      `desc` (asume que vas a escribir en inglés "Git commit", "LSP
--      rename"...). Acá se agrupa por el prefijo real del <leader>, los
--      mismos grupos que ya declara which-key en plugins/ui.lua.
--   2. Los datos salen 100% de vim.api.nvim_get_keymap(): nunca puede
--      mostrar un atajo que no exista de verdad (a diferencia de un spec "a
--      mano" aparte, que es justo lo que causó el bug de <leader><leader>
--      sin keymap real detrás). Se filtra por `sid > 0` para sacar los
--      keymaps que trae Neovim de fábrica (gra, [d, Y, gO... — son decenas)
--      y mostrar solo lo que configuramos nosotros o un plugin instalado.
local M = {}
local api = vim.api

-- Mismos grupos que las entradas `group = "..."` de which-key en
-- plugins/ui.lua. Es la única lista "a mano" de todo este archivo — si
-- agregás un grupo de leader nuevo allá, agregalo acá también.
local GROUPS = {
  a = "Android",
  b = "Pestañas",
  c = "Código",
  d = "Debug",
  f = "Buscar / Formatear",
  g = "Git",
  r = "Refactor",
  t = "Terminal",
  x = "Diagnósticos",
}

local PALETTE = { "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#fe8019" }
local CARD_BG = "#3c3836" -- gruvbox dark1, un paso más claro que el fondo (#32302f)

local function setup_highlights()
  api.nvim_set_hl(0, "CheatsheetCard", { bg = CARD_BG })
  for i, hex in ipairs(PALETTE) do
    api.nvim_set_hl(0, "CheatsheetHead" .. i, { fg = "#282828", bg = hex, bold = true })
  end
end

local function format_keybind(lhs)
  if not lhs:match("^ ") then return lhs end -- sin <leader>, se muestra tal cual (gd, K, <F5>...)
  local rest = lhs:sub(2)
  return "<leader>" .. (rest == " " and "<leader>" or rest)
end

local function truncate(s, max)
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

--- Junta los atajos reales, agrupados por categoría.
---@return table<string, {[1]:string,[2]:string}[]>
local function collect()
  local sections = {}
  for _, mode in ipairs({ "n", "i", "v", "t" }) do
    for _, km in ipairs(api.nvim_get_keymap(mode)) do
      local desc = km.desc
      if desc and desc ~= "" and km.sid and km.sid > 0 and not km.lhs:find("<Plug>", 1, true) then
        local rest = km.lhs:match("^ (.)")
        local heading = rest and (GROUPS[rest] or "General") or "Editor"
        if mode ~= "n" then heading = heading .. " (" .. mode .. ")" end
        sections[heading] = sections[heading] or {}
        table.insert(sections[heading], { truncate(desc, 44), format_keybind(km.lhs) })
      end
    end
  end
  return sections
end

-- Layout tipo masonry (misma idea que nvchad.cheatsheet.grid: cada línea es
-- un buffer en blanco relleno de espacios, y las "tarjetas" de colores se
-- pintan encima con extmarks de virt_text en overlay, posicionados por
-- columna). A diferencia de nvchad, que reparte las tarjetas round-robin,
-- acá cada una va a la columna más corta: con grupos de tamaño muy distinto
-- (Android con 10 atajos, Terminal con 1) el round-robin deja una columna
-- mucho más alta que las demás.
local function render(buf, win)
  local sections = collect()
  local win_width = api.nvim_win_get_width(win) - 2

  local item_width = 0
  for _, items in pairs(sections) do
    for _, item in ipairs(items) do
      item_width = math.max(item_width, vim.fn.strdisplaywidth(item[1] .. item[2]))
    end
  end
  -- 10 = separación entre desc/keybind + padding a los costados (misma cuenta
  -- que nvchad.cheatsheet.grid)
  local column_width = item_width + 10
  local columns_qty = math.max(1, math.floor(win_width / column_width))
  column_width = math.floor(win_width / columns_qty)

  local cards = {}
  for name, items in pairs(sections) do
    local card = {}
    local title = " " .. name .. " "
    local pad_l = math.max(math.floor((column_width - api.nvim_strwidth(title)) / 2), 0)
    local pad_r = math.max(column_width - api.nvim_strwidth(title) - pad_l, 0)
    table.insert(card, {
      { string.rep(" ", pad_l), "CheatsheetCard" },
      { title, "CheatsheetHead" .. ((#cards % #PALETTE) + 1) },
      { string.rep(" ", pad_r), "CheatsheetCard" },
    })
    for _, item in ipairs(items) do
      local gap = math.max(column_width - 4 - vim.fn.strdisplaywidth(item[1] .. item[2]), 1)
      local text = "  " .. item[1] .. string.rep(" ", gap) .. item[2] .. "  "
      table.insert(card, { { text, "CheatsheetCard" } })
    end
    table.insert(card, { { string.rep(" ", column_width), "CheatsheetCard" } })
    table.insert(cards, card)
  end
  table.sort(cards, function(a, b) return #a > #b end)

  local columns, col_height = {}, {}
  for i = 1, columns_qty do
    columns[i], col_height[i] = {}, 0
  end
  for _, card in ipairs(cards) do
    local shortest = 1
    for i = 2, columns_qty do
      if col_height[i] < col_height[shortest] then shortest = i end
    end
    table.insert(columns[shortest], card)
    col_height[shortest] = col_height[shortest] + #card
  end

  local max_height = math.max(unpack(col_height))
  local blank_line = string.rep(" ", win_width)
  local blank = {}
  for _ = 1, max_height do
    table.insert(blank, blank_line)
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, blank)

  local ns = api.nvim_create_namespace("cheatsheet")
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for col_i, column in ipairs(columns) do
    local row = 0
    local col_start = (col_i - 1) * column_width
    for _, card in ipairs(column) do
      for _, line in ipairs(card) do
        api.nvim_buf_set_extmark(buf, ns, row, col_start, { virt_text = line, virt_text_pos = "overlay" })
        row = row + 1
      end
    end
  end
  vim.bo[buf].modifiable = false
end

function M.show()
  setup_highlights()
  local width = math.floor(vim.o.columns * 0.92)
  local height = math.floor(vim.o.lines * 0.85)
  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Cheatsheet ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.wo[win].wrap = false
  render(buf, win)

  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })

  -- clear=true: si quedó un grupo de una apertura anterior (no debería,
  -- pero WinClosed lo borra solo al cerrar), lo pisa en vez de acumular.
  local group = api.nvim_create_augroup("Cheatsheet", { clear = true })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if api.nvim_win_is_valid(win) then render(buf, win) end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function() api.nvim_del_augroup_by_id(group) end,
  })
end

return M
