local M = {}
local adb = require("android.adb")
local detect = require("android.detect")
local config = require("android.config")

local build_term = nil
local last_term = nil
local run_seq = 0

local function get_gradlew()
  local cwd = vim.fn.getcwd()
  if vim.fn.filereadable(cwd .. "/gradlew") == 1 then
    return "./gradlew"
  end
  return "gradle"
end

local function shellescape(s)
  return vim.fn.shellescape(s)
end

local function install_and_launch_cmd(device, pkg)
  local adb_bin = adb.adb_bin or "adb"
  local cwd = vim.fn.getcwd()
  local gradlew = get_gradlew()

  local build = string.format("cd %s && %s :app:assembleDebug", shellescape(cwd), shellescape(gradlew))

  local apk1 = shellescape(cwd .. "/app/build/outputs/apk/debug/app-debug.apk")

  local install = string.format(
    "if [ -f %s ]; then echo '[ANDROID] installing APK'; %s -s %s install -r -d %s; else echo '[ANDROID] APK not found at %s'; exit 1; fi",
    apk1, shellescape(adb_bin), shellescape(device), apk1, apk1
  )

  local resolve = string.format(
    "%s -s %s shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER %s 2>/dev/null | tr -d '\\r' | awk '/\\//{gsub(/^[ \\t]+|[ \\t]+$/, \"\"); print; exit}'",
    shellescape(adb_bin), shellescape(device), shellescape(pkg)
  )

  local am_start = string.format("%s -s %s shell am start -W -n \"$COMP\"", shellescape(adb_bin), shellescape(device))
  local monkey   = string.format("%s -s %s shell monkey -p %s -c android.intent.category.LAUNCHER 1", shellescape(adb_bin), shellescape(device), shellescape(pkg))

  return string.format(
    "%s && echo '[ANDROID] build ok' && sleep 2 && %s && echo '[ANDROID] install finished' && sleep 1 && COMP=$(%s) && echo \"[ANDROID] component: $COMP\" && if [ -n \"$COMP\" ] && echo \"$COMP\" | grep -q '/'; then %s || %s; else echo '[ANDROID] fallback monkey'; %s; fi",
    build, install, resolve, am_start, monkey, monkey
  )
end

function M.build()
  local cmd = { get_gradlew() }
  for _, arg in ipairs(config.options.build_args) do
    table.insert(cmd, arg)
  end

  if build_term and build_term.buf and vim.api.nvim_buf_is_valid(build_term.buf) then
    build_term:toggle()
    return
  end

  build_term = Snacks.terminal(cmd, {
    win = { position = "bottom", height = 15, title = " Gradle Build " },
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("Android build completed successfully!", vim.log.levels.INFO)
      else
        vim.notify("Android build failed with code " .. code, vim.log.levels.ERROR)
      end
    end
  })
end

function M.install_and_run()
  local device = adb.ensure_device()
  if not device then return end

  local pkg = detect.get_package_name()
  if not pkg then
    vim.notify("Could not detect package name to run.", vim.log.levels.ERROR)
    return
  end

  local full_cmd = install_and_launch_cmd(device, pkg)

  if last_term and last_term.buf and vim.api.nvim_buf_is_valid(last_term.buf) then
    pcall(function() last_term:close() end)
  end

  run_seq = run_seq + 1
  last_term = Snacks.terminal({ "/bin/sh", "-c", full_cmd }, {
    count = run_seq,
    cwd = vim.fn.getcwd(),
    win = { position = "bottom", height = 16, title = " Gradle Assemble + Install + Run " },
    interactive = false,
    auto_close = false,
  })
end

function M.clean()
  local cmd = { get_gradlew(), "clean" }
  if build_term and build_term.buf and vim.api.nvim_buf_is_valid(build_term.buf) then
    build_term:toggle()
    return
  end
  build_term = Snacks.terminal(cmd, {
    win = { position = "bottom", height = 15, title = " Gradle Clean " },
  })
end

return M
