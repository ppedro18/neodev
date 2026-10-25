-- :DroidLogcatClearHistory: limpia el historial de filtros de logcat de
-- android-nvim-plugin para el workspace actual. El plugin no tiene ninguna
-- tecla para borrar una entrada del historial desde su picker de filtro —
-- peor, `on_cancel` siempre re-persiste el filtro activo al historial (ver
-- su lua/android/logcat/session/controls.lua), así que una entrada vieja
-- puede reaparecer sola con solo abrir y cerrar el picker. Por eso esto
-- también limpia el filtro activo, no solo el historial.
-- Standalone a propósito: edita directo el archivo de estado del plugin en
-- stdpath("state")/android/<workspace>.json, sin requerir ninguno de sus
-- módulos internos (misma razón que el resto de android_tools/).
local M = {}

local SETTINGS_FILES = { "settings.gradle.kts", "settings.gradle" }

local function sanitize(value)
  if not value or value == "" then return nil end
  local cleaned = value:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return cleaned ~= "" and cleaned or nil
end

-- Misma detección de raíz que android_tools.gradle_nav, y la misma
-- sanitización que lua/android/state/path.lua del plugin (reglas simples,
-- duplicarlas es más liviano que depender de su módulo interno).
local function state_file()
  local from = vim.fn.getcwd()
  local root = vim.fs.root(from, SETTINGS_FILES) or vim.fs.root(from, "gradlew") or from
  local key = sanitize(root)
  if not key then return nil end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "android", key .. ".json")
end

function M.clear_history()
  local path = state_file()
  if not path or vim.fn.filereadable(path) ~= 1 then
    vim.notify("No hay estado de android-nvim-plugin guardado para este workspace todavía.", vim.log.levels.WARN)
    return
  end

  local ok_decode, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok_decode or type(decoded) ~= "table" or type(decoded.logcat) ~= "table" then
    vim.notify("No se pudo leer/entender " .. path, vim.log.levels.ERROR)
    return
  end

  local logcat = decoded.logcat
  logcat.filter_history = {}
  logcat.filter = ""
  if type(logcat.sessions) == "table" then
    for _, session in pairs(logcat.sessions) do
      if type(session) == "table" then
        session.filter_history = {}
        session.filter = ""
      end
    end
  end

  local ok_write = pcall(vim.fn.writefile, { vim.json.encode(decoded) }, path)
  if not ok_write then
    vim.notify("No se pudo escribir " .. path, vim.log.levels.ERROR)
    return
  end

  vim.notify(
    "Historial y filtro activo de logcat limpiados (" .. vim.fs.basename(path) .. "). "
      .. "Cerrá y volvé a abrir nvim para que tome el cambio (el plugin solo relee este archivo al arrancar).",
    vim.log.levels.INFO
  )
end

return M
