-- Preview interactivo (<leader>ci / :ComposePreviewInteractive): NO es parte
-- de compose-preview.nvim (ese renderiza PNG y listo, sin gancho para esto).
-- Mantiene vivo el mismo RenderTask que usa Android Studio para su
-- Interactive/Animation Preview (com.android.tools.rendering, layoutlib real)
-- y lo pinta en una ventana Swing nativa, mismo proceso — igual que hace
-- Studio, sin HTTP/PNG/navegador para los frames (esa vía con HTTP+PNG
-- también existe en el mismo directorio — InteractiveServer — pero este
-- comando ya no la usa: medido, ~4-10ms de touch a frame nuevo contra
-- ~18-20ms de la vía HTTP ya optimizada).
--
-- Desde acá habla con InteractiveDaemon (no InteractiveWindow, que sigue
-- existiendo como vía de un solo uso): un único proceso Java persistente que
-- sobrevive entre <leader>ci sucesivos y entre reinicios de nvim. Medido:
-- bootstrapear el Renderer (Bridge.init de layoutlib + primer render) cuesta
-- ~1.8-2.0s, igual para cualquier componente — no es por-componente, es
-- por-JVM. Sin daemon, cada <leader>ci paga eso de nuevo. Con daemon, solo lo
-- paga el primer open del proceso; abrir otro @Preview distinto después (con
-- el mismo módulo/variant Gradle) reusa el Renderer ya vivo: ~40-100ms medido
-- contra componentes distintos (botón, badge, avatar, swipe), no una mejora
-- puntual de un solo caso. `:ComposePreviewInteractiveStop` es lo único que
-- de verdad mata el proceso — cerrar la ventana (la X) solo la oculta, y
-- nvim no lo mata al salir (VimLeavePre ya no lo toca): matar el daemon
-- volvería a pagar el cold start en el próximo <leader>ci, justo lo que esto
-- existe para evitar. Ver el README del directorio para el detalle.
--
-- El Java vive en nvim/compose-preview-interactive/ (ver su README para
-- compilarlo). Reusa los módulos Lua públicos de compose-preview.nvim
-- (gradle/scanner/toolchain/params/renderer) en vez de reimplementar la
-- detección de módulo/variant o el manejo del toolchain/JDK.
local daemon_job = nil

local function interactive_classes_dir()
  return vim.fs.joinpath(vim.fn.stdpath("config"), "compose-preview-interactive", "classes")
end

-- Mismo cache dir que ya usa compose-preview.nvim (confirmado:
-- ~/.cache/nvim/compose-preview/) — el daemon Java escribe ahí su puerto con
-- un path fijo (no conoce stdpath de nvim), esto tiene que coincidir.
local function daemon_port_file()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "compose-preview", "interactive-daemon.port")
end

local function daemon_read_port()
  local path = daemon_port_file()
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local port = tonumber(vim.trim(table.concat(vim.fn.readfile(path), "")))
  return port
end

local function daemon_ping(port, callback)
  vim.system({ "curl", "-s", "-m", "1", ("http://127.0.0.1:%d/ping"):format(port) }, { text = true }, function(res)
    vim.schedule(function()
      callback(res.code == 0 and vim.trim(res.stdout or "") == "ok")
    end)
  end)
end

local function daemon_open(port, config_path, callback)
  vim.system({
    "curl", "-s", "-m", "60", "-X", "POST",
    "--data-binary", "@" .. config_path,
    ("http://127.0.0.1:%d/open"):format(port),
  }, { text = true }, function(res)
    vim.schedule(function()
      callback(res.code == 0 and vim.trim(res.stdout or "") == "ok", res.stderr)
    end)
  end)
end

local function interactive_pick_preview(previews, cursor_line)
  local best, best_dist = previews[1], math.huge
  for _, preview in ipairs(previews) do
    local dist = math.abs((preview.line or 0) - cursor_line)
    if dist < best_dist then
      best, best_dist = preview, dist
    end
  end
  return best
end

local function interactive_notify(message, level)
  vim.notify("[compose-preview-interactive] " .. message, level or vim.log.levels.INFO)
end

local function interactive_stop()
  local port = daemon_read_port()
  if port then
    -- POST /stop es lo que de verdad termina el proceso (ver nota de arriba);
    -- no esperamos la respuesta, no hace falta para esto.
    vim.system({ "curl", "-s", "-m", "2", "-X", "POST", ("http://127.0.0.1:%d/stop"):format(port) })
  elseif daemon_job and daemon_job.id then
    pcall(vim.fn.jobstop, daemon_job.id)
  end
  daemon_job = nil
end

-- Lanza InteractiveDaemon (puerto 0 = que elija uno) y espera la línea "PORT n"
-- en stdout (mismo contrato que ya usaba InteractiveServer) antes de mandarle el
-- primer /open. on_stdout corre en el contexto "fast" de libuv — nada de vim.*
-- ahí sin vim.schedule (encontrado a mano en esta misma sesión).
local function launch_daemon_and_open(java, classpath, send_open)
  local opened = false
  local job = {}
  job.id = vim.fn.jobstart({ java, "-cp", classpath, "InteractiveDaemon", "0" }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local port = line:match("^PORT (%d+)")
        if port and not opened then
          opened = true
          vim.schedule(function()
            send_open(tonumber(port))
          end)
        end
      end
    end,
    on_exit = function()
      if daemon_job == job then
        daemon_job = nil
      end
    end,
  })
  daemon_job = job
end

local function interactive_open()
  local gradle = require("compose-preview.gradle")
  local scanner = require("compose-preview.scanner")
  local toolchain = require("compose-preview.toolchain")
  local params = require("compose-preview.params")
  local renderer = require("compose-preview.renderer")

  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if not file:match("%.kt$") then
    return interactive_notify("no es un archivo Kotlin", vim.log.levels.ERROR)
  end

  local source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local previews, scan_err = scanner.scan(source, file)
  if not previews or #previews == 0 then
    return interactive_notify(scan_err or "no se encontró ningún @Preview", vim.log.levels.ERROR)
  end

  local root = gradle.find_project_root(file)
  local module = root and gradle.find_module(root, file)
  if not root or not module then
    return interactive_notify("gradlew/build.gradle no encontrado", vim.log.levels.ERROR)
  end

  -- Con más de un @Preview en el archivo, usa el más cercano al cursor.
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local preview = interactive_pick_preview(previews, cursor_line)
  local resolved, unresolvable = params.normalize(preview.params)
  if #unresolvable > 0 then
    interactive_notify("atributos sin resolver: " .. table.concat(unresolvable, ", "), vim.log.levels.WARN)
  end

  -- Sin interactive_stop() acá: con daemon, abrir otro @Preview no mata el anterior,
  -- lo reemplaza en la misma ventana (ver nota de arriba) — matar el proceso en cada
  -- open sería pagar el cold start de nuevo cada vez, justo lo que el daemon evita.

  local java = renderer.find_java()
  if not java then
    return interactive_notify("Java 21+ no encontrado", vim.log.levels.ERROR)
  end

  interactive_notify(("building %s..."):format(module == "" and ":" or module))

  local work = vim.fs.joinpath(vim.fn.stdpath("cache"), "compose-preview-interactive")
  vim.fn.mkdir(work, "p")

  toolchain.install({}, function(install_err, paths)
    if install_err then
      return interactive_notify(install_err, vim.log.levels.ERROR)
    end

    gradle.build_and_inspect({
      root = root,
      module = module,
      info_path = vim.fs.joinpath(work, "gradle-info.json"),
      fallback_java_home = renderer.java_home(java),
    }, function(gradle_err, info)
      if gradle_err then
        return interactive_notify(gradle_err, vim.log.levels.ERROR)
      end

      local config_path = vim.fs.joinpath(work, "config.json")
      vim.fn.writefile({
        vim.json.encode({
          namespace = info.namespace,
          resourceApkPath = info.resourceApkPath,
          layoutlibPath = paths.layoutlib_dir,
          classPath = info.classPath,
          projectClassPath = info.projectClassPath,
          methodFQN = preview.method_fqn,
          previewId = preview.method_fqn .. "_interactive",
          previewParams = resolved,
        }),
      }, config_path)

      local classpath = table.concat({ interactive_classes_dir(), paths.renderer_jar, paths.layoutlib_jar }, ":")

      local function send_open(port)
        daemon_open(port, config_path, function(ok, err)
          if ok then
            interactive_notify("preview actualizado — arrastrá el componente")
          else
            interactive_notify("fallo abriendo el preview: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end

      local existing_port = daemon_read_port()
      if existing_port then
        return daemon_ping(existing_port, function(alive)
          if alive then
            return send_open(existing_port)
          end
          -- Port file viejo de un daemon que ya no corre (p.ej. la máquina se
          -- reinició) — cae al camino de lanzarlo de nuevo, abajo.
          daemon_job = nil
          launch_daemon_and_open(java, classpath, send_open)
        end)
      end

      launch_daemon_and_open(java, classpath, send_open)
    end)
  end)
end

return {
  {
    -- Renderiza los @Preview de Jetpack Compose sin Android Studio (layoutlib
    -- vía Gradle, resultado en PNG abierto en el navegador). Primer uso
    -- descarga ~300MB en ~/.cache/nvim/compose-preview. Requiere JDK 21+
    -- (ya viene en el Brewfile) y el proyecto debe compilar con Gradle.
    -- Su init-script de Gradle está pisado por nvim/gradle/compose-preview.init.gradle
    -- (el plugin lo busca con nvim_get_runtime_file, primer match gana): el
    -- original no detecta variantes en módulos com.android.library, solo en
    -- application, y además AGP no linkea APK de recursos para library —
    -- el override lo presta de un módulo application hermano. Ver ese
    -- archivo y el README para el detalle.
    "ntsk/compose-preview.nvim",
    ft = "kotlin",
    cmd = { "ComposePreview", "ComposePreviewLog", "ComposePreviewInteractive", "ComposePreviewInteractiveStop" },
    opts = {},
    config = function(_, opts)
      require("compose-preview").setup(opts)
      vim.api.nvim_create_user_command(
        "ComposePreviewInteractive",
        interactive_open,
        { desc = "Compose: preview interactivo (touch real sobre layoutlib vivo)" }
      )
      vim.api.nvim_create_user_command(
        "ComposePreviewInteractiveStop",
        interactive_stop,
        { desc = "Compose: detener el preview interactivo" }
      )
      -- Sin VimLeavePre -> interactive_stop: el daemon sobrevive a salir de nvim a
      -- propósito (ver nota grande de arriba) — matarlo acá volvería a pagar el cold
      -- start en la próxima sesión de nvim, justo lo que el daemon existe para evitar.
    end,
    keys = {
      { "<leader>cp", "<cmd>ComposePreview<CR>", desc = "Compose: preview" },
      { "<leader>ci", "<cmd>ComposePreviewInteractive<CR>", desc = "Compose: preview interactivo" },
    },
  },
}
