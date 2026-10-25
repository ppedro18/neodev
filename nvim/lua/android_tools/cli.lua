-- android-cli wrapper: detects the `android` binary on PATH (Google's
-- official CLI, https://developer.android.com/tools/agents) and exposes the
-- subset of commands DroidLayout/DroidScreenshot/DroidDocs/DroidSdk/
-- DroidCreate/studio.lua need. Everything else in this repo's android.lua
-- keeps using plain adb (android_tools.adb), so this is optional: when
-- `android` isn't installed, these commands just say so.
-- Trimmed down from rizukirr/droid-nvim (lua/droid/backends/android_cli.lua):
-- no config toggle (always auto-detect), no emulator/run_apks helpers
-- (android-nvim-plugin's own Device Manager covers those).

local M = {}

---@type boolean|nil
local _cached_available = nil
---@type string|nil
local _cached_version = nil

--- Reset detection cache (e.g. after installing android-cli mid-session).
function M.reset_cache()
  _cached_available = nil
  _cached_version = nil
end

--- Is the `android` binary on PATH, and does it behave like android-cli?
--- Cached after the first call.
---@return boolean
function M.is_available()
  if _cached_available ~= nil then return _cached_available end

  local exe = vim.fn.exepath("android")
  if exe == "" then
    _cached_available = false
    return false
  end

  -- The SDK's long-removed `tools/android` script shares the name, so also
  -- require that the output carries a version number.
  local result = vim.system({ exe, "-V" }, { text = true }):wait(5000)
  if result.code ~= 0 or not (result.stdout or ""):match("%d+%.%d+") then
    _cached_available = false
    return false
  end

  _cached_version = vim.trim(result.stdout or "")
  _cached_available = true
  return true
end

--- Detected version string (output of `android -V`), or nil if unavailable.
---@return string|nil
function M.version()
  if _cached_available == nil then M.is_available() end
  return _cached_version
end

--- The argv for `android <args>`, or nil when android-cli is unavailable.
--- The SDK android_tools.adb detected goes along as `--sdk`, so the CLI and
--- the SDK tools always agree on which SDK to use.
---@param args string[]
---@return string[]|nil
function M.argv(args)
  local exe = vim.fn.exepath("android")
  if exe == "" then return nil end
  local sdk = require("android_tools.adb").sdk_root()
  local argv = sdk and { exe, "--sdk=" .. sdk } or { exe }
  return vim.list_extend(argv, args)
end

local function notify_failure(action, result)
  local stderr = vim.trim(result.stderr or "")
  local msg = ("android-cli %s failed (exit %d)"):format(action, result.code or -1)
  if #stderr > 0 then msg = msg .. ": " .. stderr end
  vim.notify(msg, vim.log.levels.ERROR)
end

--- Run `android <args>` and pass the finished process to `on_ok`. On a
--- nonzero exit the failure is notified and `on_fail` gets the process, or
--- nil when the binary is unavailable. Both run on the main loop.
---@param args string[]
---@param action string names the command in the failure message
---@param on_ok fun(result: vim.SystemCompleted)
---@param on_fail fun(result: vim.SystemCompleted|nil)
local function run(args, action, on_ok, on_fail)
  local cmd = M.argv(args)
  if not cmd then
    on_fail(nil)
    return
  end
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        notify_failure(action, result)
        on_fail(result)
        return
      end
      on_ok(result)
    end)
  end)
end

--- Write the UI tree of the screen a device is showing, as pretty-printed
--- JSON, via `android layout`.
---@param opts { output: string, device?: string, full?: boolean } `full` adds non-interactive and hidden elements
---@param callback fun(ok: boolean)
function M.layout(opts, callback)
  local args = { "layout", "--pretty", "--output=" .. opts.output }
  if opts.device then table.insert(args, "--device=" .. opts.device) end
  if opts.full then table.insert(args, "--full") end
  run(args, "layout", function() callback(true) end, function() callback(false) end)
end

--- Capture a screenshot of the connected device via `android screen capture`.
---@param opts { output: string, annotate: boolean }
---@param callback fun(ok: boolean, output_path: string)
function M.screen_capture(opts, callback)
  local args = { "screen", "capture", "--output=" .. opts.output }
  if opts.annotate then table.insert(args, "--annotate") end
  run(args, "screen capture", function() callback(true, opts.output) end, function() callback(false, opts.output) end)
end

--- Parse `android docs search` output. Progress lines come first, then
--- numbered results, each a title line followed by `URL: kb://…` and a
--- snippet.
---@param stdout string
---@return { title: string, url: string }[]
function M._parse_docs_search(stdout)
  local results, title = {}, nil
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local numbered = line:match("^%s*%d+%.%s+(.+)$")
    local url = line:match("^%s*URL:%s*(kb://%S+)")
    if numbered then
      title = vim.trim(numbered)
    elseif url and title then
      table.insert(results, { title = title, url = url })
      title = nil
    end
  end
  return results
end

--- Search the Android Knowledge Base via `android docs search "<query>"`.
---@param query string
---@param callback fun(results: { title: string, url: string }[])
function M.docs_search(query, callback)
  run({ "docs", "search", query }, "docs search", function(result)
    callback(M._parse_docs_search(result.stdout))
  end, function()
    callback({})
  end)
end

--- The article from `android docs fetch` output, without the progress lines
--- and the Title/URL header that precede it. The title becomes a heading.
---@param stdout string
---@return string
function M._parse_docs_fetch(stdout)
  stdout = stdout or ""
  local title = stdout:match("\nTitle:%s*([^\r\n]+)") or stdout:match("^Title:%s*([^\r\n]+)")
  local body = stdout:match("\n%-%-%-%-+%s*\r?\n(.*)$")
  if not body then return stdout end
  return (title and ("# " .. title .. "\n\n") or "") .. body
end

--- Fetch a single KB document via `android docs fetch <kb-url>`.
---@param url string e.g. "kb://android/topic/performance/overview"
---@param callback fun(ok: boolean, body: string)
function M.docs_fetch(url, callback)
  run({ "docs", "fetch", url }, "docs fetch", function(result)
    callback(true, M._parse_docs_fetch(result.stdout))
  end, function(result)
    callback(false, result and result.stdout or "")
  end)
end

return M
