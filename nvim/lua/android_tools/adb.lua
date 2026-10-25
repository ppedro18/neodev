-- ADB mínimo para las herramientas custom de este repo (inspector de red,
-- scrcpy, comandos :Droid* de android-cli): encontrar el binario, elegir
-- device y resolver PID. Standalone a propósito — nada de esto depende de
-- ningún plugin de terceros (ni AntoineGagnon/android.nvim antes, ni
-- iamironz/android-nvim-plugin ahora), que ya cubre build/run/logcat/AVD
-- por su cuenta (ver plugins/android.lua).
local M = {}

M.selected_device = nil

local function find_bin(name, extra_paths)
  if vim.fn.executable(name) == 1 then
    return name
  end

  local home = vim.loop.os_homedir()
  local candidates = {
    os.getenv("ANDROID_HOME") and (os.getenv("ANDROID_HOME") .. "/platform-tools/" .. name) or nil,
    os.getenv("ANDROID_SDK_ROOT") and (os.getenv("ANDROID_SDK_ROOT") .. "/platform-tools/" .. name) or nil,
    home .. "/Library/Android/sdk/platform-tools/" .. name,
    home .. "/Android/Sdk/platform-tools/" .. name,
    "/usr/local/bin/" .. name,
    "/opt/homebrew/bin/" .. name,
  }
  for _, p in ipairs(extra_paths or {}) do
    table.insert(candidates, p)
  end

  for _, path in ipairs(candidates) do
    if path and vim.fn.executable(path) == 1 then
      return path
    end
  end
  return name
end

-- SDK root, expuesto para android_tools.cli (`android --sdk=...`).
local function sdk_root()
  local home = vim.loop.os_homedir()
  local candidates = {
    os.getenv("ANDROID_HOME"),
    os.getenv("ANDROID_SDK_ROOT"),
    home .. "/Library/Android/sdk",
    home .. "/Android/Sdk",
  }
  for _, path in ipairs(candidates) do
    if path and vim.fn.isdirectory(path) == 1 then
      return path
    end
  end
  return nil
end

local adb_bin = find_bin("adb")

-- Ruta absoluta al adb encontrado, para lanzarlo aunque "adb" no esté en el
-- PATH de la sesión de Neovim (ver nota de ANDROID_HOME/Ghostty).
M.adb_bin = adb_bin
M.sdk_root = sdk_root

local function adb_cmd(args)
  local cmd = { adb_bin }
  for _, v in ipairs(args) do
    table.insert(cmd, v)
  end
  return cmd
end

local function adb_string(args)
  return table.concat(adb_cmd(args), " ")
end

function M.get_devices()
  local handle = io.popen(adb_string({ "devices" }))
  if not handle then return {} end
  local result = handle:read("*a")
  handle:close()

  local devices = {}
  for line in result:gmatch("[^\r\n]+") do
    if not line:match("List of devices") and line ~= "" and not line:match("^%s*$") then
      local parts = {}
      for part in line:gmatch("%S+") do
        table.insert(parts, part)
      end
      if #parts >= 2 then
        if parts[2] == "unauthorized" then
          vim.notify("Dispositivo " .. parts[1] .. " sin autorizar. Acepta el prompt en el móvil.", vim.log.levels.WARN)
        else
          table.insert(devices, { id = parts[1], state = parts[2] })
        end
      end
    end
  end
  return devices
end

-- Picker manual, para cuando hay más de un device y las herramientas custom
-- (inspector de red, scrcpy, :Droid*) necesitan saber a cuál apuntar — el
-- device manager de android-nvim-plugin (<leader>ao) es independiente de
-- esta selección.
function M.select_device()
  local devices = M.get_devices()
  if #devices == 0 then
    vim.notify("No hay devices ADB (adb=" .. adb_bin .. "). Conectá uno o iniciá un emulador.", vim.log.levels.WARN)
    return
  end

  local options = {}
  for i, dev in ipairs(devices) do
    table.insert(options, string.format("%d: %s (%s)", i, dev.id, dev.state))
  end

  vim.ui.select(options, { prompt = "Elegir device Android:" }, function(choice)
    if not choice then return end
    local index = tonumber(choice:match("^(%d+):"))
    if index and devices[index] then
      M.selected_device = devices[index].id
      vim.notify("Device seleccionado: " .. M.selected_device, vim.log.levels.INFO)
    end
  end)
end

-- Revalida el device elegido contra la lista actual: puede haberse
-- desconectado desde que se eligió, y un id viejo acá hace fallar en
-- silencio cualquier "-s <device>" de más abajo.
function M.ensure_device()
  local devices = M.get_devices()

  if M.selected_device then
    for _, d in ipairs(devices) do
      if d.id == M.selected_device then return M.selected_device end
    end
    M.selected_device = nil
  end

  if #devices == 1 then
    M.selected_device = devices[1].id
    return M.selected_device
  elseif #devices > 1 then
    vim.notify("Hay varios devices conectados. Elegí uno con :DroidSelectDevice.", vim.log.levels.ERROR)
    return nil
  end

  vim.notify("No hay devices ADB conectados (adb=" .. adb_bin .. ").", vim.log.levels.ERROR)
  return nil
end

-- Espeja la pantalla del device actual con scrcpy (cero setup más allá del binario).
function M.mirror()
  if vim.fn.executable("scrcpy") ~= 1 then
    vim.notify("scrcpy no encontrado. Instalalo: brew install scrcpy", vim.log.levels.ERROR)
    return
  end

  local device = M.ensure_device()
  if not device then return end

  vim.notify("Iniciando scrcpy para " .. device, vim.log.levels.INFO)
  vim.fn.jobstart({ "scrcpy", "-s", device }, {
    detach = true,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.notify("scrcpy terminó con código " .. code, vim.log.levels.WARN)
      end
    end,
  })
end

function M.force_stop()
  local package = require("android_tools.detect").get_package_name()
  if not package then
    vim.notify("No se pudo detectar el applicationId", vim.log.levels.ERROR)
    return
  end
  local device = M.ensure_device()
  if not device then return end

  vim.fn.jobstart(adb_cmd({ "-s", device, "shell", "am", "force-stop", package }), {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("App detenida (force-stop): " .. package, vim.log.levels.INFO)
      else
        vim.notify("Falló force-stop: " .. package, vim.log.levels.ERROR)
      end
    end,
  })
end

-- PID de `package_name` en `device_id`, para el inspector de red.
function M.get_pid(package_name, device_id)
  if not device_id or not package_name then return nil end
  local handle = io.popen(adb_string({ "-s", device_id, "shell", "pidof", package_name }))
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  local pid = result:match("%d+")
  if pid and pid ~= "" then
    return pid
  end

  local handle2 = io.popen(adb_string({ "-s", device_id, "shell", "ps" }) .. " | grep " .. vim.fn.shellescape(package_name))
  if not handle2 then return nil end
  local res2 = handle2:read("*a")
  handle2:close()
  return res2:match("(%d+)%s+" .. package_name)
end

return M
