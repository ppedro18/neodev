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
    home .. "/Android/Sdk/emulator/" .. name,
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

-- SDK root used for avdmanager and for walking system-images/ directly
-- (faster and more reliable than parsing `sdkmanager --list`).
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
local emulator_bin = find_bin("emulator")
local avdmanager_bin = find_bin("avdmanager", (function()
  local root = sdk_root()
  return root and { root .. "/cmdline-tools/latest/bin/avdmanager" } or nil
end)())

-- Ruta absoluta al adb encontrado, para que otros módulos (gradle.lua) puedan
-- lanzarlo aunque "adb" no esté en el PATH de la sesión de Neovim.
M.adb_bin = adb_bin
M.emulator_bin = emulator_bin
-- Expuesto para android.cli (detecta el mismo SDK que este módulo).
M.sdk_root = sdk_root

local function adb_cmd(args)
  local cmd = { adb_bin }
  for _, v in ipairs(args) do
    table.insert(cmd, v)
  end
  return cmd
end

local function adb_string(args)
  local cmd = adb_cmd(args)
  return table.concat(cmd, " ")
end

-- Gets a list of connected devices
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

-- Selects a device using vim.ui.select
function M.select_device()
  local devices = M.get_devices()
  if #devices == 0 then
    vim.notify("No ADB devices found (adb=" .. adb_bin .. "). Ensure a device is connected or emulator is running.", vim.log.levels.WARN)
    return
  end

  local options = {}
  for i, dev in ipairs(devices) do
    table.insert(options, string.format("%d: %s (%s)", i, dev.id, dev.state))
  end

  vim.ui.select(options, { prompt = "Select Android Device:" }, function(choice)
    if not choice then return end
    local index = tonumber(choice:match("^(%d+):"))
    if index and devices[index] then
      M.selected_device = devices[index].id
      vim.notify("Selected Android Device: " .. M.selected_device, vim.log.levels.INFO)
    end
  end)
end

-- Helper to ensure we have a device, if not auto-pick one or fail.
-- Revalidates a previously selected device against the current list: it
-- might have disconnected (phone unplugged, emulator closed) since it was
-- picked, and a stale id here means every "-s <device>" command below
-- fails silently against a device that's no longer there.
function M.ensure_device()
  local devices = M.get_devices()

  if M.selected_device then
    for _, d in ipairs(devices) do
      if d.id == M.selected_device then return M.selected_device end
    end
    M.selected_device = nil -- ya no está conectado, hay que reelegir
  end

  if #devices == 1 then
    M.selected_device = devices[1].id
    vim.notify("Auto-selected only device: " .. M.selected_device, vim.log.levels.INFO)
    return M.selected_device
  elseif #devices > 1 then
    vim.notify("Multiple devices found. Please run :AndroidSelectDevice first.", vim.log.levels.ERROR)
    return nil
  end

  vim.notify("No ADB devices connected (adb=" .. adb_bin .. ").", vim.log.levels.ERROR)
  return nil
end

-- List AVDs
function M.get_avds()
  local handle = io.popen(emulator_bin .. " -list-avds")
  if not handle then return {} end
  local result = handle:read("*a")
  handle:close()

  local avds = {}
  for line in result:gmatch("[^\r\n]+") do
    if line ~= "" then
      table.insert(avds, line)
    end
  end
  return avds
end

-- Installed system images, by walking $SDK/system-images/<api>/<variant>/<arch>
-- instead of parsing `sdkmanager --list` (no sdkmanager dependency, no two
-- output formats to handle).
local function get_installed_system_images()
  local root = sdk_root()
  if not root then return {} end
  local sys_img_dir = root .. "/system-images"
  if vim.fn.isdirectory(sys_img_dir) ~= 1 then return {} end

  local images = {}
  for _, api_dir in ipairs(vim.fn.readdir(sys_img_dir)) do
    local api_path = sys_img_dir .. "/" .. api_dir
    if vim.fn.isdirectory(api_path) == 1 then
      for _, variant_dir in ipairs(vim.fn.readdir(api_path)) do
        local variant_path = api_path .. "/" .. variant_dir
        if vim.fn.isdirectory(variant_path) == 1 then
          for _, arch_dir in ipairs(vim.fn.readdir(variant_path)) do
            if vim.fn.isdirectory(variant_path .. "/" .. arch_dir) == 1 then
              table.insert(images, {
                package = string.format("system-images;%s;%s;%s", api_dir, variant_dir, arch_dir),
                display = string.format("%s | %s | %s", api_dir, variant_dir, arch_dir),
              })
            end
          end
        end
      end
    end
  end
  return images
end

-- Device definition ids known to avdmanager (pixel_7, pixel_6, ...).
local function get_device_definitions()
  local handle = io.popen(avdmanager_bin .. " list device -c 2>/dev/null")
  if not handle then return {} end
  local result = handle:read("*a")
  handle:close()

  local ids = {}
  for line in result:gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line ~= "" then table.insert(ids, line) end
  end
  return ids
end

-- Create a new AVD via android-cli (`android emulator create <profile>`),
-- for machines with the SDK's emulator/platform-tools/system-images but not
-- the separate "SDK command-line tools" package (no avdmanager) — common
-- when the SDK was set up from Android Studio's own AVD Manager, which
-- doesn't need avdmanager itself. The CLI picks the AVD name and system
-- image for the profile, so there's no image/device-definition picker here.
local function create_avd_via_cli()
  local cli = require("android.cli")
  local list_cmd = cli.argv({ "emulator", "create", "--list-profiles" })
  vim.system(list_cmd, { text = true }, function(result)
    vim.schedule(function()
      local profiles = {}
      for line in (result.stdout or ""):gmatch("[^\r\n]+") do
        local p = vim.trim(line)
        if p ~= "" then table.insert(profiles, p) end
      end
      if #profiles == 0 then
        vim.notify("android-cli returned no emulator profiles", vim.log.levels.WARN)
        return
      end
      vim.ui.select(profiles, { prompt = "Select emulator profile:" }, function(profile)
        if not profile then return end
        -- Panel visible, igual que el resto de comandos :Droid* con avdmanager/gradle.
        Snacks.terminal(cli.argv({ "emulator", "create", profile }), {
          win = { position = "bottom", height = 15, title = " Crear emulador: " .. profile .. " " },
          on_exit = function(_, code)
            if code == 0 then
              vim.notify("Emulator created from profile " .. profile .. ". Start it with :DroidEmulator.", vim.log.levels.INFO)
            else
              vim.notify("Failed to create emulator from profile " .. profile .. ", ver panel", vim.log.levels.ERROR)
            end
          end,
        })
      end)
    end)
  end)
end

-- Create a new AVD: system image -> device definition -> name -> avdmanager.
-- Only when avdmanager is actually available; android-cli is the fallback
-- (create_avd_via_cli) for SDKs without the command-line tools package.
local function create_avd_via_avdmanager()
  local images = get_installed_system_images()
  if #images == 0 then
    vim.notify("No installed system images found. Install one from Android Studio's SDK Manager.", vim.log.levels.WARN)
    return
  end

  vim.ui.select(images, {
    prompt = "Select system image:",
    format_item = function(item) return item.display end,
  }, function(image)
    if not image then return end

    local devices = get_device_definitions()
    if #devices == 0 then
      vim.notify("avdmanager returned no device definitions", vim.log.levels.WARN)
      return
    end

    vim.ui.select(devices, { prompt = "Select device definition:" }, function(device_id)
      if not device_id then return end

      local default_name = device_id .. "_" .. (image.package:match("android%-(%w+)") or "api")
      vim.ui.input({ prompt = "AVD name: ", default = default_name }, function(name)
        if not name or name == "" then return end
        name = name:gsub("%s+", "_"):gsub("[^%w_%-.]", "")

        -- Panel visible (igual que Gradle Build/Clean en gradle.lua): avdmanager
        -- puede tardar y conviene ver su salida, no solo un notify al final.
        local term = Snacks.terminal(
          { avdmanager_bin, "create", "avd", "-n", name, "-k", image.package, "-d", device_id },
          {
            win = { position = "bottom", height = 15, title = " Crear emulador: " .. name .. " " },
            on_exit = function(_, code)
              if code == 0 then
                vim.notify("Emulator created: " .. name .. ". Start it with :DroidEmulator.", vim.log.levels.INFO)
              else
                vim.notify("Failed to create emulator " .. name .. ", ver panel", vim.log.levels.ERROR)
              end
            end,
          }
        )
        -- Responde al "Do you wish to create a custom hardware profile?" de avdmanager.
        vim.schedule(function()
          local job_id = term and term.buf and vim.b[term.buf].terminal_job_id
          if job_id then vim.fn.chansend(job_id, "no\n") end
        end)
      end)
    end)
  end)
end

-- avdmanager when available, else android-cli, else tell the user what's missing.
function M.create_avd()
  if vim.fn.executable(avdmanager_bin) == 1 then
    create_avd_via_avdmanager()
    return
  end
  if require("android.cli").is_available() then
    create_avd_via_cli()
    return
  end
  vim.notify(
    "Need avdmanager (SDK command-line tools) or android-cli (https://developer.android.com/tools/agents) to create an AVD",
    vim.log.levels.ERROR
  )
end

-- Delete an AVD after confirming ("No" first so a stray Enter keeps it).
-- avdmanager when available, else `android emulator remove` (android-cli).
local function delete_avd(avd)
  vim.ui.select({ "No", "Yes" }, { prompt = "Delete emulator " .. avd .. "? Its data is lost" }, function(answer)
    if answer ~= "Yes" then return end

    if vim.fn.executable(avdmanager_bin) ~= 1 then
      local cli = require("android.cli")
      if not cli.is_available() then
        vim.notify("Need avdmanager or android-cli to delete an AVD", vim.log.levels.ERROR)
        return
      end
      vim.system(cli.argv({ "emulator", "remove", avd }), { text = true }, function(result)
        vim.schedule(function()
          if result.code == 0 then
            vim.notify("Emulator deleted: " .. avd, vim.log.levels.INFO)
          else
            vim.notify("Failed to delete emulator: " .. avd, vim.log.levels.ERROR)
          end
        end)
      end)
      return
    end

    vim.fn.jobstart({ avdmanager_bin, "delete", "avd", "-n", avd }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.notify("Emulator deleted: " .. avd, vim.log.levels.INFO)
        else
          vim.notify("Failed to delete emulator: " .. avd, vim.log.levels.ERROR)
        end
      end,
    })
  end)
end

local CREATE_EMULATOR_SENTINEL = "+ Create New Emulator"
local DELETE_EMULATOR_SENTINEL = "- Delete Emulator"

-- Start emulator asynchronously, or create/delete an AVD from the same picker.
function M.start_emulator()
  local avds = M.get_avds()

  local options = vim.list_slice(avds)
  table.insert(options, CREATE_EMULATOR_SENTINEL)
  if #avds > 0 then
    table.insert(options, DELETE_EMULATOR_SENTINEL)
  end

  vim.ui.select(options, { prompt = "Select AVD to Start:" }, function(choice)
    if not choice then return end

    if choice == CREATE_EMULATOR_SENTINEL then
      M.create_avd()
      return
    end
    if choice == DELETE_EMULATOR_SENTINEL then
      vim.ui.select(avds, { prompt = "Select emulator to delete:" }, function(avd)
        if avd then delete_avd(avd) end
      end)
      return
    end

    vim.notify("Starting emulator: " .. choice, vim.log.levels.INFO)
    vim.fn.jobstart({ emulator_bin, "-avd", choice }, {
      detach = true,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.notify("Emulator " .. choice .. " exited with code " .. code, vim.log.levels.WARN)
        end
      end
    })
  end)
end

-- Stop a running emulator (adb emu kill), picking from the emulator-* devices.
function M.stop_emulator()
  local emulators = {}
  for _, d in ipairs(M.get_devices()) do
    if d.id:match("^emulator%-") then
      table.insert(emulators, d)
    end
  end

  if #emulators == 0 then
    vim.notify("No running emulators found", vim.log.levels.WARN)
    return
  end

  vim.ui.select(emulators, {
    prompt = "Select emulator to stop:",
    format_item = function(e) return e.id end,
  }, function(choice)
    if not choice then return end
    vim.notify("Stopping emulator: " .. choice.id, vim.log.levels.INFO)
    vim.fn.jobstart(adb_cmd({ "-s", choice.id, "emu", "kill" }), {
      on_exit = function(_, code)
        if code == 0 then
          vim.notify("Emulator stopped: " .. choice.id, vim.log.levels.INFO)
        else
          vim.notify("Failed to stop emulator: " .. choice.id, vim.log.levels.ERROR)
        end
      end,
    })
  end)
end

-- Mirror the current device's screen with scrcpy (zero setup beyond the binary).
function M.mirror()
  if vim.fn.executable("scrcpy") ~= 1 then
    vim.notify("scrcpy not found. Install it: brew install scrcpy", vim.log.levels.ERROR)
    return
  end

  local device = M.ensure_device()
  if not device then return end

  vim.notify("Starting scrcpy for " .. device, vim.log.levels.INFO)
  vim.fn.jobstart({ "scrcpy", "-s", device }, {
    detach = true,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.notify("scrcpy exited with code " .. code, vim.log.levels.WARN)
      end
    end,
  })
end

-- ADB quick actions on the app this project builds (applicationId via
-- android.detect), on the ensured/selected device.
local function run_on_app(args_fn, success_msg, error_msg)
  local package = require("android.detect").get_package_name()
  if not package then
    vim.notify("Could not detect applicationId", vim.log.levels.ERROR)
    return
  end
  local device = M.ensure_device()
  if not device then return end

  vim.fn.jobstart(args_fn(device, package), {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify(success_msg .. ": " .. package, vim.log.levels.INFO)
      else
        vim.notify(error_msg .. ": " .. package, vim.log.levels.ERROR)
      end
    end,
  })
end

function M.clear_app_data()
  run_on_app(function(device, package)
    return adb_cmd({ "-s", device, "shell", "pm", "clear", package })
  end, "App data cleared", "Failed to clear app data")
end

function M.force_stop()
  run_on_app(function(device, package)
    return adb_cmd({ "-s", device, "shell", "am", "force-stop", package })
  end, "App force stopped", "Failed to force stop app")
end

function M.uninstall_app()
  run_on_app(function(device, package)
    return adb_cmd({ "-s", device, "uninstall", package })
  end, "App uninstalled", "Failed to uninstall app")
end

-- Get process ID for a package on the selected device
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

  local handle2 = io.popen(adb_string({ "-s", device_id, "shell", "ps" }) .. " | grep " .. package_name)
  if not handle2 then return nil end
  local res2 = handle2:read("*a")
  handle2:close()
  pid = res2:match("(%d+)%s+" .. package_name)
  return pid
end

return M
