-- === Inspector de red: lee los logs que tu app YA emite (HttpLoggingInterceptor,
-- tag "OkHttp", nivel BODY — ver NetClientBuilder.kt) y los parsea/formatea
-- bonito. Cero proxy, cero certificados: nunca puede romper la app, porque
-- no toca nada del tráfico real, solo leer logcat. 100% custom: no es parte
-- de ningún plugin, por eso vive sobre android_tools.adb/detect (ver
-- nvim/lua/android_tools/) en vez de la API interna de android-nvim-plugin.

local inspector_buf, inspector_win, inspector_job
local inspector_state = {} -- [tid] = { method, url, phase, req_headers, req_body_lines, resp_headers, resp_body_lines, status, status_text, timing }

-- 'foldtext' se evalúa como expresión Vimscript; v:lua.* es el puente para
-- llamar una función Lua desde ahí. Oculta el marcador {{{ del resumen y
-- agrega cuántas líneas tiene adentro (headers + body) cada request.
function _G.__nvim_kotlin_inspector_foldtext()
  local summary = vim.fn.getline(vim.v.foldstart):gsub("%s*{{{%s*$", "")
  local detail_lines = vim.v.foldend - vim.v.foldstart - 1
  return string.format("%s  [%d líneas]", summary, detail_lines)
end

local function json_pretty(decoded, indent)
  indent = indent or ""
  local t = type(decoded)
  if t == "table" then
    local is_array = decoded[1] ~= nil
    local inner = indent .. "  "
    local parts = {}
    if is_array then
      for _, v in ipairs(decoded) do
        table.insert(parts, inner .. json_pretty(v, inner))
      end
    else
      local keys = {}
      for k in pairs(decoded) do table.insert(keys, k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        table.insert(parts, inner .. '"' .. k .. '": ' .. json_pretty(decoded[k], inner))
      end
    end
    if #parts == 0 then return is_array and "[]" or "{}" end
    local open, close = is_array and "[" or "{", is_array and "]" or "}"
    return open .. "\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. close
  elseif t == "string" then
    return vim.json.encode(decoded)
  elseif decoded == nil or decoded == vim.NIL then
    return "null"
  else
    return tostring(decoded)
  end
end

local function pretty_body(raw)
  if raw == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok then return json_pretty(decoded) end
  return raw
end

local function inspector_append(lines)
  if not (inspector_buf and vim.api.nvim_buf_is_valid(inspector_buf)) then return end
  local mod = vim.bo[inspector_buf].modifiable
  vim.bo[inspector_buf].modifiable = true
  local ok = pcall(function()
    local last = vim.api.nvim_buf_line_count(inspector_buf)
    if last == 1 and vim.api.nvim_buf_get_lines(inspector_buf, 0, 1, false)[1] == "" then
      vim.api.nvim_buf_set_lines(inspector_buf, 0, 1, false, lines)
    else
      vim.api.nvim_buf_set_lines(inspector_buf, last, last, false, lines)
    end
  end)
  vim.bo[inspector_buf].modifiable = mod
  if not ok then return end
  if inspector_win and vim.api.nvim_win_is_valid(inspector_win) then
    vim.api.nvim_win_set_cursor(inspector_win, { vim.api.nvim_buf_line_count(inspector_buf), 0 })
  end
end

local function new_entry(method, url)
  return {
    method = method,
    url = url,
    phase = "req_headers",
    req_headers = {},
    req_body_lines = {},
    resp_headers = {},
    resp_body_lines = {},
  }
end

-- Cada entrada es un fold (foldmethod=marker, {{{/}}}): colapsada se ve
-- una sola línea resumen (método, URL, status, timing); con za/clic en el
-- foldcolumn se expande a Request/Response con sus Headers/Body.
local function emit_entry(st)
  local status_summary
  if st.failed then
    status_summary = "✗ FALLÓ: " .. st.failed
  elseif st.status then
    local text = (st.status_text and st.status_text ~= "") and (" " .. st.status_text) or ""
    status_summary = st.status .. text .. "  (" .. (st.timing or "?") .. ")"
  else
    status_summary = "(sin respuesta todavía)"
  end

  local lines = {}
  table.insert(lines, string.format("▶ %-5s %s  →  %s {{{", st.method, st.url, status_summary))

  table.insert(lines, "  Request:")
  if #st.req_headers > 0 then
    table.insert(lines, "    Headers:")
    for _, h in ipairs(st.req_headers) do table.insert(lines, "      " .. h) end
  end
  local req_body = table.concat(st.req_body_lines, "\n")
  if req_body ~= "" then
    table.insert(lines, "    Body:")
    for _, l in ipairs(vim.split(pretty_body(req_body) or req_body, "\n")) do
      table.insert(lines, "      " .. l)
    end
  end

  table.insert(lines, "  Response:")
  if #st.resp_headers > 0 then
    table.insert(lines, "    Headers:")
    for _, h in ipairs(st.resp_headers) do table.insert(lines, "      " .. h) end
  end
  local resp_body = table.concat(st.resp_body_lines, "\n")
  if resp_body ~= "" then
    table.insert(lines, "    Body:")
    for _, l in ipairs(vim.split(pretty_body(resp_body) or resp_body, "\n")) do
      table.insert(lines, "      " .. l)
    end
  end

  table.insert(lines, "}}}")
  inspector_append(lines)
end

local function handle_line(tid, msg)
  local method, url = msg:match("^%-%-> (%u+) (%S+)")
  if method and method ~= "END" then
    inspector_state[tid] = new_entry(method, url)
    return
  end

  local st = inspector_state[tid]
  if not st then return end

  if st.phase == "req_headers" then
    if msg:match("^%-%-> END") then
      st.phase = "waiting_response"
    elseif msg == "" then
      st.phase = "req_body"
    else
      table.insert(st.req_headers, msg)
    end
    return
  end

  if st.phase == "req_body" then
    if msg:match("^%-%-> END") then
      st.phase = "waiting_response"
    else
      table.insert(st.req_body_lines, msg)
    end
    return
  end

  if st.phase == "waiting_response" then
    if msg:match("^<%-%- HTTP FAILED") then
      st.failed = msg:gsub("^<%-%- HTTP FAILED: ", "")
      emit_entry(st)
      inspector_state[tid] = nil
      return
    end
    -- "<-- 200 OK https://... (123ms)" normalmente, pero HTTP/2 suele no
    -- mandar reason phrase: "<-- 200 https://... (123ms)" sin el "OK". Sin
    -- este segundo intento, code queda nil siempre que el backend sea
    -- HTTP/2 y la respuesta nunca se emite (se queda esperando para siempre).
    local code, text, _, extra = msg:match("^<%-%- (%d+) (.-) (%S+) %((.-)%)")
    if not code then
      code, extra = msg:match("^<%-%- (%d+) %S+ %((.-)%)")
      text = ""
    end
    if code then
      st.status, st.status_text, st.timing = code, text, extra
      st.phase = "resp_headers"
    end
    return
  end

  if st.phase == "resp_headers" then
    if msg:match("^<%-%- END") then
      emit_entry(st)
      inspector_state[tid] = nil
    elseif msg == "" then
      st.phase = "resp_body"
    else
      table.insert(st.resp_headers, msg)
    end
    return
  end

  if st.phase == "resp_body" then
    if msg:match("^<%-%- END") then
      emit_entry(st)
      inspector_state[tid] = nil
    else
      table.insert(st.resp_body_lines, msg)
    end
    return
  end
end

local function inspector_close()
  if inspector_job then
    pcall(vim.fn.jobstop, inspector_job)
    inspector_job = nil
  end
  if inspector_win and vim.api.nvim_win_is_valid(inspector_win) then
    pcall(vim.api.nvim_win_close, inspector_win, true)
  end
  inspector_win = nil
end

local function inspector_open()
  local adb = require("android_tools.adb")
  local detect = require("android_tools.detect")
  local device = adb.ensure_device()
  if not device then return end
  local pkg = detect.get_package_name()
  if not pkg then
    vim.notify("No se pudo detectar el applicationId.", vim.log.levels.WARN)
    return
  end
  local pid = adb.get_pid(pkg, device)
  if not pid then
    vim.notify("La app no está corriendo. Abrila primero con <leader>ab.", vim.log.levels.WARN)
    return
  end

  inspector_state = {}
  if not (inspector_buf and vim.api.nvim_buf_is_valid(inspector_buf)) then
    inspector_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[inspector_buf].filetype = "httpinspector"
  end
  vim.bo[inspector_buf].modifiable = true
  vim.api.nvim_buf_set_lines(inspector_buf, 0, -1, false, {})
  vim.bo[inspector_buf].modifiable = false

  vim.cmd("highlight default link httpInspectorArrow Title")
  vim.cmd("highlight default link httpInspectorStatusOk DiagnosticOk")
  vim.cmd("highlight default link httpInspectorStatusErr DiagnosticError")
  vim.cmd("highlight default link httpInspectorHeaderKey Identifier")
  vim.cmd("highlight default link httpInspectorSection Title")
  vim.cmd("highlight default link httpInspectorLabel Comment")
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "httpinspector",
    callback = function()
      vim.cmd([[
        syntax match httpInspectorArrow /^▶/
        syntax match httpInspectorStatusOk /^▶.*→\s*[23]\d\d\>.*{{{$/
        syntax match httpInspectorStatusErr /^▶.*→\s*\([45]\d\d\>\|.*FALLÓ\).*{{{$/
        syntax match httpInspectorSection /^\s\+\(Request\|Response\):$/
        syntax match httpInspectorLabel /^\s\+\(Headers\|Body\):$/
        syntax match httpInspectorHeaderKey /^\s\+[A-Za-z-]\+:/ contained
      ]])
    end,
  })

  local win = Snacks.win({
    buf = inspector_buf,
    position = "bottom",
    height = 20,
    border = "rounded",
    title = " Inspector de red (" .. pkg .. ") — <CR>/clic en el margen: expandir/colapsar ",
    title_pos = "center",
    wo = {
      wrap = false,
      number = false,
      foldmethod = "marker",
      foldlevel = 0, -- arranca todo colapsado: una línea resumen por request
      foldcolumn = "1", -- +/- clickeable al margen izquierdo
      foldenable = true,
      foldtext = "v:lua.__nvim_kotlin_inspector_foldtext()",
    },
  })
  inspector_win = win.win

  vim.keymap.set("n", "q", inspector_close, { buffer = inspector_buf, silent = true, desc = "Cerrar inspector" })
  vim.keymap.set("n", "<CR>", "za", { buffer = inspector_buf, silent = true, desc = "Expandir/colapsar request" })
  vim.keymap.set("n", "c", function()
    local mod = vim.bo[inspector_buf].modifiable
    vim.bo[inspector_buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, inspector_buf, 0, -1, false, {})
    vim.bo[inspector_buf].modifiable = mod
  end, { buffer = inspector_buf, silent = true, desc = "Limpiar" })

  -- "adb" a secas (sin adb.adb_bin) depende de que el PATH de ESTE proceso
  -- de nvim incluya platform-tools — no siempre cierto (ver nota de
  -- ANDROID_HOME/Ghostty en plugins/ui.lua). Job sin pcall: si jobstart
  -- lanza (binario no encontrado), la ventana ya abierta se queda vacía y
  -- sin ningún aviso.
  local ok, job_or_err = pcall(vim.fn.jobstart,
    { adb.adb_bin, "-s", device, "logcat", "-v", "threadtime", "--pid=" .. pid, "OkHttp:I", "*:S" },
    {
      on_stdout = function(_, data)
        for _, line in ipairs(data or {}) do
          local tid, msg = line:match("^%d%d%-%d%d%s+%d%d:%d%d:%d%d%.%d+%s+%d+%s+(%d+)%s+%a%s+%S+%s*:%s*(.*)$")
          if tid then handle_line(tid, msg) end
        end
      end,
    }
  )
  if not ok or job_or_err <= 0 then
    vim.notify("No se pudo iniciar logcat para el inspector (adb=" .. tostring(adb.adb_bin) .. "): " .. tostring(job_or_err), vim.log.levels.ERROR)
    return
  end
  inspector_job = job_or_err
end

local function inspector_toggle()
  if inspector_win and vim.api.nvim_win_is_valid(inspector_win) then
    inspector_close()
  else
    inspector_open()
  end
end

-- :DroidLayout: árbol de UI de la pantalla como JSON, vía android-cli.
-- Un buffer por device, se refresca si se corre de nuevo.
local function droid_layout(bang)
  local cli = require("android_tools.cli")
  if not cli.is_available() then
    vim.notify("DroidLayout requiere android-cli (`android` no está en el PATH, ver https://developer.android.com/tools/agents)", vim.log.levels.ERROR)
    return
  end
  local adb = require("android_tools.adb")
  local device = adb.ensure_device()
  if not device then return end

  local output = vim.fn.tempname() .. ".json"
  cli.layout({ device = device, full = bang, output = output }, function(ok)
    if not ok then return end
    local lines = vim.fn.readfile(output)
    vim.fn.delete(output)

    local name = "droid-layout://" .. device
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == name then buf = b end
    end
    if not buf then
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, name)
      vim.bo[buf].filetype = "json"
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if vim.fn.bufwinid(buf) == -1 then vim.cmd.sbuffer(buf) end
  end)
end

-- :DroidScreenshot [path]: captura la pantalla del device, vía android-cli.
local function droid_screenshot(path, annotate)
  local cli = require("android_tools.cli")
  if not cli.is_available() then
    vim.notify("DroidScreenshot requiere android-cli (`android` no está en el PATH, ver https://developer.android.com/tools/agents)", vim.log.levels.ERROR)
    return
  end
  if not path or path == "" then
    local stamp = os.date("%Y%m%d-%H%M%S")
    path = vim.fs.joinpath(vim.fn.stdpath("cache"), ("droid-screenshot-%s.png"):format(stamp))
  end
  cli.screen_capture({ output = path, annotate = annotate }, function(ok, saved_path)
    if not ok then return end
    vim.notify("Screenshot guardado: " .. saved_path, vim.log.levels.INFO)
    vim.ui.open(saved_path)
  end)
end

-- :DroidDocs <query>: busca en la Android Knowledge Base, vía android-cli.
local function droid_docs(query)
  local cli = require("android_tools.cli")
  if not cli.is_available() then
    vim.notify("DroidDocs requiere android-cli (`android` no está en el PATH, ver https://developer.android.com/tools/agents)", vim.log.levels.ERROR)
    return
  end
  query = vim.trim(query or "")
  if query == "" then
    vim.notify("Uso: :DroidDocs <query>", vim.log.levels.WARN)
    return
  end
  cli.docs_search(query, function(results)
    if #results == 0 then
      vim.notify("Sin resultados en la KB para: " .. query, vim.log.levels.INFO)
      return
    end
    vim.ui.select(results, {
      prompt = "Resultados Android KB:",
      format_item = function(r) return r.title .. "  " .. r.url end,
    }, function(choice)
      if not choice then return end
      local name = "droid-docs://" .. choice.url
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == name then
          vim.cmd.sbuffer(buf)
          return
        end
      end
      cli.docs_fetch(choice.url, function(ok, body)
        if not ok then return end
        vim.cmd("new")
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_set_name(buf, name)
      end)
    end)
  end)
end

-- Comandos :Droid*, 100% custom (ver nvim/lua/android_tools/): ni
-- android-nvim-plugin ni ningún otro plugin los ofrece. Build/run/logcat/
-- devices/AVD/gradle-tasks los da android-nvim-plugin (abajo); esto cubre
-- lo que queda: scrcpy, android-cli, y navegación de archivos Gradle.
local function register_droid_commands()
  local adb = require("android_tools.adb")

  vim.api.nvim_create_user_command("DroidSelectDevice", adb.select_device, { desc = "Android: elegir device para las herramientas custom (inspector/scrcpy/cli)" })
  vim.api.nvim_create_user_command("DroidMirror", adb.mirror, { desc = "Android: espejar pantalla (scrcpy)" })
  vim.api.nvim_create_user_command("DroidForceStop", adb.force_stop, { desc = "Android: force-stop de la app" })
  vim.api.nvim_create_user_command(
    "DroidLogcatClearHistory",
    function() require("android_tools.logcat_history").clear_history() end,
    { desc = "Android: limpiar historial y filtro activo de logcat (android-nvim-plugin no lo expone en su UI)" }
  )

  -- Navegación de archivos Gradle
  local nav = require("android_tools.gradle_nav")
  vim.api.nvim_create_user_command("DroidGradleModule", function(opts) nav.module(opts.mods) end, { desc = "Android: ir al build.gradle(.kts) del módulo" })
  vim.api.nvim_create_user_command("DroidGradleProject", function(opts) nav.project(opts.mods) end, { desc = "Android: ir al build.gradle(.kts) raíz" })
  vim.api.nvim_create_user_command("DroidGradleSettings", function(opts) nav.settings(opts.mods) end, { desc = "Android: ir al settings.gradle(.kts)" })
  vim.api.nvim_create_user_command("DroidGradleVersion", function(opts) nav.version(opts.mods) end, { desc = "Android: ir al gradle/libs.versions.toml" })

  -- Requieren android-cli (https://developer.android.com/tools/agents); sin
  -- instalarlo, cada uno avisa claro en vez de fallar en silencio.
  vim.api.nvim_create_user_command("DroidLayout", function(opts) droid_layout(opts.bang) end, { bang = true, desc = "Android: árbol de UI de la pantalla (JSON, android-cli)" })
  vim.api.nvim_create_user_command("DroidScreenshot", function(opts) droid_screenshot(opts.fargs[1], opts.bang) end, { nargs = "?", complete = "file", bang = true, desc = "Android: captura de pantalla (android-cli)" })
  vim.api.nvim_create_user_command("DroidDocs", function(opts) droid_docs(opts.args) end, { nargs = "+", desc = "Android: buscar en la Knowledge Base (android-cli)" })
  vim.api.nvim_create_user_command("DroidCreate", function() require("android_tools.create").create() end, { desc = "Android: crear proyecto nuevo desde un template (android-cli)" })
  vim.api.nvim_create_user_command("DroidSdk", function(opts) require("android_tools.sdk").run(opts.fargs) end, {
    nargs = "*",
    desc = "Android: list/install/update/remove de paquetes del SDK (android-cli)",
    complete = function(arg_lead, line)
      if #vim.split(vim.trim(line), "%s+") > (arg_lead == "" and 1 or 2) then return {} end
      return vim.tbl_filter(function(action)
        return action:find(arg_lead, 1, true) == 1
      end, require("android_tools.sdk").ACTIONS)
    end,
  })

  -- Android Studio debe estar corriendo con el proyecto abierto (android-cli)
  local studio = require("android_tools.studio")
  vim.api.nvim_create_user_command("DroidLint", studio.lint, { desc = "Android: lint/inspecciones de Android Studio para este archivo" })
  vim.api.nvim_create_user_command("DroidDeclaration", function(opts) studio.declaration(opts.args) end, { nargs = "?", desc = "Android: ir a la declaración (índice de Android Studio)" })
  vim.api.nvim_create_user_command("DroidUsages", function(opts) studio.usages(opts.args) end, { nargs = "?", desc = "Android: listar usos (índice de Android Studio)" })
  vim.api.nvim_create_user_command("DroidVersions", function(opts) studio.versions(opts.fargs) end, { nargs = "*", desc = "Android: últimas versiones de libs/herramientas" })
  vim.api.nvim_create_user_command("DroidStudioOpen", studio.open, { desc = "Android: abrir este archivo en Android Studio" })
end

return {
  {
    -- Build/run/logcat/devices/AVD/Gradle tasks, con variant picker y cache.
    -- Reemplaza a AntoineGagnon/android.nvim (ver legacy/): esa base tenía 1
    -- estrella y quedó sin tocar a los 2 días de creada, y todo lo variant-
    -- aware (<leader>aa de antes era siempre assembleDebug/installDebug fijo)
    -- lo tuvimos que reimplementar a mano. Este plugin ya lo trae probado
    -- (suite de tests propia, CI, docs), con menú interactivo (:AndroidMenu).
    "iamironz/android-nvim-plugin",
    lazy = false,
    config = function()
      require("android").setup({})
      register_droid_commands()
    end,
    keys = {
      -- Defaults del plugin: am/at/ao/aa/ab para Menu/Targets/Tools/Actions/Build.
      -- Logcat y build-con-prompts (variant picker) no traen keymap propio.
      { "<leader>al", "<cmd>AndroidLogcat<CR>", desc = "Android: logcat (filtra por tu app)" },
      { "<leader>aB", "<cmd>AndroidBuildPrompt<CR>", desc = "Android: build eligiendo módulo/variante" },
      -- 100% custom, no lo da ningún plugin:
      { "<leader>av", "<cmd>DroidMirror<CR>", desc = "Android: espejar pantalla (scrcpy)" },
      { "<leader>an", inspector_toggle, desc = "Android: inspector de red (sin proxy)" },
      { "<leader>ah", "<cmd>DroidLogcatClearHistory<CR>", desc = "Android: limpiar historial/filtro de logcat" },
    },
  },
}
