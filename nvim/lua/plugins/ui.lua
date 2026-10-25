-- Abre `path` en una ventana nueva de Ghostty. "-e nvim" a secas ejecuta
-- nvim directo, sin pasar por el shell de login: tu .zshrc (ANDROID_HOME,
-- PATH de platform-tools, etc.) nunca se carga ahí, y cosas como `adb`
-- dejan de encontrarse en esa ventana. "zsh -ic 'nvim'" sí sourcea .zshrc
-- antes de abrir nvim.
local function open_new_window(path)
  vim.fn.jobstart(
    { "open", "-na", "Ghostty", "--args", "--working-directory=" .. path, "-e", "zsh", "-ic", "nvim" },
    { detach = true }
  )
end

-- Usado por yazi.nvim y Snacks.picker.projects más abajo: al abrir un
-- proyecto, pregunta si seguir en esta ventana o abrir una nueva de Ghostty
-- aparte (sin cerrar la actual).
local function ask_open_window(path, cb)
  cb = cb or {}
  vim.ui.select({ "Acá mismo", "Ventana nueva" }, {
    prompt = 'Abrir "' .. vim.fn.fnamemodify(path, ":t") .. '"',
  }, function(choice)
    if choice == "Ventana nueva" then
      open_new_window(path)
      if cb.on_new_window then cb.on_new_window() end
    elseif choice == "Acá mismo" and cb.on_same_window then
      cb.on_same_window(path)
    end
  end)
end

-- "Acá mismo" de ask_open_window: antes esto era solo `vim.cmd.cd(p)` en
-- los 3 call-sites de abajo (dashboard, <leader>fp, <leader>fo) — cambiaba
-- el cwd pero no abría nada visible, así que elegir "Acá mismo" parecía no
-- hacer nada. Abrimos el explorer ahí para que se vea el proyecto nuevo.
local function open_project_here(path)
  vim.cmd.cd(path)
  Snacks.explorer({ cwd = path })
end

-- Usado por <leader>fp y por la sección "p" del dashboard — mismo picker,
-- misma config, para no mantenerla duplicada en dos lugares.
local function open_projects_picker()
  Snacks.picker.projects({
    dev = { vim.fn.expand("~/Documents/Azure") },
    max_depth = 4,
    patterns = {
      ".git", "settings.gradle.kts", "settings.gradle", "build.gradle.kts",
      "angular.json", "package.json",
    },
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      ask_open_window(item.file, { on_same_window = open_project_here })
    end,
  })
end

return {
  {
    -- Fondo cálido casi negro (#32302f) con contraste "soft", como en la
    -- captura de referencia (Zed con Gruvbox) — no el catppuccin anterior.
    "ellisonleao/gruvbox.nvim",
    priority = 1000,
    opts = { contrast = "soft" },
    config = function(_, opts)
      require("gruvbox").setup(opts)
      vim.o.background = "dark"
      vim.cmd.colorscheme("gruvbox")
      -- El dashboard de snacks (más abajo) linkea desc/icon/file de sus
      -- items a "Special", y gruvbox mapea Special -> naranja (ver
      -- gruvbox.lua: `Special = { link = "GruvboxOrange" }`) — por eso
      -- "Buscar archivo" y compañía salían naranjas sin que lo hayamos
      -- pedido. Lo pisamos a GruvboxBlue (ya existe, mismo theme, no es un
      -- color inventado) solo para esos tres grupos.
      for _, group in ipairs({ "SnacksDashboardDesc", "SnacksDashboardIcon", "SnacksDashboardFile" }) do
        vim.api.nvim_set_hl(0, group, { link = "GruvboxBlue" })
      end
    end,
  },

  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    opts = {
      options = { theme = "gruvbox", globalstatus = true },
      -- Barra inferior estilo IDE (como la de la captura): rama + diffs +
      -- diagnósticos a la izquierda, LSP activo a la derecha (equivalente
      -- al "No Active Lsp" de Zed).
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { "filename" },
        lualine_x = {
          {
            function()
              local clients = vim.lsp.get_clients({ bufnr = 0 })
              if #clients == 0 then return "No Active Lsp" end
              local names = {}
              for _, c in ipairs(clients) do table.insert(names, c.name) end
              return table.concat(names, ", ")
            end,
          },
          "filetype",
        },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
  },

  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "modern",
      win = { border = "rounded", title = true, title_pos = "center" },
      layout = { spacing = 4 },
      icons = { breadcrumb = "»", separator = "➜", group = "+" },
      -- which-key ya trae auto-detección de íconos por patrón en la
      -- descripción (which-key/icons.lua: "git", "debug", "terminal",
      -- "format", "diagnostic", etc. → ícono + color solos, sin declarar
      -- nada acá) — por eso la mayoría de los grupos de abajo NO tienen
      -- icon=. Antes esta config ponía icon="" (string vacío) en TODOS,
      -- que en Lua es truthy: eso pisaba la auto-detección y dejaba todo
      -- sin ícono a propósito sin querer. Los pocos grupos con icon=
      -- explícito son los que el patrón en inglés no matchea por estar en
      -- español (Pestañas/Código/Diagnósticos no contienen "tab"/"code"/
      -- "diagnostic") o porque conviene uno puntual (Refactor, Cerrar
      -- ventana ~ "quit").
      spec = {
        { "<leader>a", group = "Android" },
        { "<leader>am", desc = "Menú principal (AndroidMenu)" },
        { "<leader>at", desc = "Build variants / Gradle tasks" },
        { "<leader>ao", desc = "Device manager / ADB" },
        { "<leader>aa", desc = "Acciones" },
        { "<leader>ab", desc = "Build (variante guardada)" },
        { "<leader>aB", desc = "Build eligiendo módulo/variante" },
        { "<leader>al", desc = "Logcat (filtra por tu app)" },
        { "<leader>av", desc = "Espejar pantalla (scrcpy)" },
        { "<leader>an", desc = "Inspector de red" },
        { "<leader>ah", desc = "Limpiar historial/filtro de logcat" },

        { "<leader>b", group = "Pestañas", icon = "󰓩 " },
        { "<leader>bd", desc = "Cerrar pestaña" },

        { "<leader>c", group = "Código", icon = " " },
        { "<leader>ca", desc = "Code action (LSP)" },
        { "<leader>cp", desc = "Preview de Compose" },
        { "<leader>cw", desc = "Yazi en el directorio del proyecto" },

        { "<leader>d", group = "Debug" },
        { "<leader>db", desc = "Toggle breakpoint" },
        { "<leader>de", desc = "Ver error en detalle" },
        { "<leader>du", desc = "Toggle UI" },

        { "<leader>f", group = "Buscar / Formatear" },
        { "<leader>ff", desc = "Archivos" },
        { "<leader>fg", desc = "Texto" },
        { "<leader>fb", desc = "Pestañas" },
        { "<leader>fr", desc = "Reemplazar en el proyecto" },
        { "<leader>fh", desc = "Ayuda" },
        { "<leader>fp", desc = "Proyectos recientes" },
        { "<leader>fo", desc = "Abrir carpeta (\"Open Folder\")" },

        { "<leader>g", group = "Git" },
        { "<leader>gg", desc = "LazyGit" },
        { "<leader>gd", desc = "Diff (cambios sin commitear)" },
        { "<leader>go", desc = "Listar PRs" },
        { "<leader>gi", desc = "Listar issues" },

        { "<leader>r", group = "Refactor", icon = " " },
        { "<leader>rn", desc = "Renombrar símbolo" },

        { "<leader>t", group = "Terminal" },
        { "<leader>tt", desc = "Terminal (toggle)" },

        { "<leader>x", group = "Diagnósticos", icon = "󱖫 " },
        { "<leader>xx", desc = "Proyecto" },
        { "<leader>xb", desc = "Pestaña" },

        { "<leader><leader>", desc = "Leader Espacio · Ver todos los atajos" },
        { "<leader>e", desc = "Explorador de archivos" },
        { "<leader>u", desc = "Historial de cambios (undo tree)" },
        { "<leader>-", desc = "Yazi: archivo actual" },
        { "<leader>w", desc = "Guardar" },
        { "<leader>q", desc = "Cerrar ventana", icon = "󰈆 " },
      },
    },
  },

  {
    -- El cmdline/mensajes flotantes de LazyVim/AstroNvim: al tocar ":" sale
    -- un input flotante arriba en vez de la línea de abajo de siempre.
    "folke/noice.nvim",
    event = "VeryLazy",
    dependencies = { "MunifTanjim/nui.nvim" },
    opts = {
      -- Los toasts (vim.notify) los maneja snacks.nvim de abajo, no noice:
      -- entre los dos se pisaban y vim.notify() de plugins como
      -- android-nvim-plugin no se veía en ningún lado.
      notify = { enabled = false },
      presets = {
        command_palette = true, -- esto es justo el cmdline flotante
        bottom_search = true,
        long_message_to_split = true,
        lsp_doc_border = true,
      },
    },
  },

  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    dependencies = { "nvim-lua/plenary.nvim" },
    -- Este setup() no se llamaba en ningún lado de esta config — Telescope
    -- necesita su propio setup() (no basta con configurar sus extensiones,
    -- como telescope-undo, por separado) para inicializar su config
    -- interna. Sin él, los mappings de restore de telescope-undo quedaban
    -- mal armados (encontrado diagnosticando <leader>u).
    config = function()
      require("telescope").setup({})
    end,
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<CR>", desc = "Buscar archivos" },
      { "<leader>fg", "<cmd>Telescope live_grep<CR>", desc = "Buscar texto" },
      {
        "<leader>fb",
        function() require("telescope.builtin").buffers({ prompt_title = "Pestañas" }) end,
        desc = "Buscar pestañas",
      },
      { "<leader>fh", "<cmd>Telescope help_tags<CR>", desc = "Buscar ayuda" },
    },
  },

  {
    -- Lo más parecido a "Local History" de JetBrains que existe en nvim:
    -- no es snapshot por archivo, es el undofile persistente (ya activo en
    -- core/options.lua) con un árbol navegable + diff + Enter/clic para
    -- revertir a cualquier estado pasado, aunque nunca lo hayas commiteado.
    "debugloop/telescope-undo.nvim",
    dependencies = { "nvim-telescope/telescope.nvim" },
    keys = {
      { "<leader>u", "<cmd>Telescope undo<CR>", desc = "Historial de cambios (undo tree)" },
    },
    config = function()
      -- Pisa <cr> (Enter/clic, que por defecto solo copia las adiciones)
      -- para que pida confirmación y recién ahí restaure — nada de
      -- <C-cr>/<C-r>: son justo las teclas que más problemas dan según
      -- terminal. Enter no tiene esa ambigüedad en ningún terminal.
      local actions = require("telescope.actions")
      local actions_state = require("telescope.actions.state")

      local function confirm_restore(prompt_bufnr)
        return function()
          local entry = actions_state.get_selected_entry()
          if not entry then return end
          -- Cerramos el picker nosotros (no llamamos a la acción real de
          -- restore, que también cierra — cerrar dos veces el mismo picker
          -- tira error). Guardamos bufnr/seq ahora porque después de cerrar
          -- ya no hay de dónde volver a pedirlos.
          local bufnr, seq = entry.value.bufnr, entry.value.seq
          actions.close(prompt_bufnr)
          -- vim.schedule: mismo motivo que <leader>fo (yazi) — si el modal
          -- abre en medio de la transición de cierre, una tecla que ya
          -- estaba en cola puede colársele sin que lo veas.
          vim.schedule(function()
            vim.ui.select({ "Sí, deshacer este cambio", "Cancelar" }, {
              -- "Restaurar state #N" = pedido explícito: no es "saltar a la
              -- foto de ese estado" (eso deja las líneas que borró ESE
              -- cambio, borradas) sino deshacer específicamente lo que pasó
              -- en ese cambio — si #N borró una línea, confirmar la trae de
              -- vuelta.
              prompt = ("Deshacer el cambio de state #%d"):format(seq),
            }, function(choice)
              if choice ~= "Sí, deshacer este cambio" then return end
              local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
              vim.api.nvim_buf_call(bufnr, function()
                -- Saltar AL cambio y de ahí retroceder un paso (en vez de
                -- restar 1 al número) respeta el árbol real de Neovim: el
                -- padre de un seq en una rama no es necesariamente seq-1.
                vim.cmd("undo " .. seq)
                vim.cmd("undo")
              end)
              local after_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
              if vim.deep_equal(before_lines, after_lines) then
                vim.notify(("El cambio de state #%d no tenía nada antes que deshacer (es el primero)."):format(seq), vim.log.levels.WARN)
              else
                vim.notify(("Deshecho el cambio de state #%d."):format(seq), vim.log.levels.INFO)
              end
            end)
          end)
        end
      end

      require("telescope").setup({
        extensions = {
          undo = {
            mappings = {
              n = { ["<cr>"] = confirm_restore },
              i = { ["<cr>"] = confirm_restore },
            },
          },
        },
      })
      require("telescope").load_extension("undo")
    end,
  },

  {
    -- Pestañas de archivos abiertos arriba, como en cualquier IDE.
    "akinsho/bufferline.nvim",
    event = "VeryLazy",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      { "<S-l>", "<cmd>BufferLineCycleNext<CR>", desc = "Pestaña siguiente" },
      { "<S-h>", "<cmd>BufferLineCyclePrev<CR>", desc = "Pestaña anterior" },
      {
        "<leader>bd",
        function() require("mini.bufremove").delete(0, false) end,
        desc = "Cerrar pestaña",
      },
    },
    opts = {
      options = { diagnostics = "nvim_lsp", separator_style = "slant" },
    },
  },

  {
    -- En un monorepo como este (varios módulos Android + Angular) es fácil
    -- terminar con 30+ pestañas abiertas de solo navegar referencias/
    -- definiciones — cada una con su propio diagnóstico/highlight de LSP en
    -- memoria. hbac cierra solas las que nunca editaste (entrar a insert o
    -- modificarlas las "fija") una vez que pasás el umbral — no las que
    -- estás usando de verdad.
    "axkirillov/hbac.nvim",
    event = "VeryLazy",
    opts = {
      threshold = 10,
      -- Mismo motivo que <leader>bd: el default de hbac es
      -- nvim_buf_delete a secas, que puede romper el layout si la pestaña
      -- que autocierra está en un split.
      close_command = function(bufnr) require("mini.bufremove").delete(bufnr, false) end,
    },
  },

  {
    -- Autoguarda la sesión (ventanas/buffers, por directorio) al salir y
    -- la deja lista para "Restaurar sesión" del dashboard de snacks de
    -- abajo — ese botón ya estaba, pero sin un plugin de sesión soportado
    -- (persistence/persisted/posession/mini.sessions) snacks simplemente
    -- no lo mostraba. No le agrego keymaps <leader>q* propios (son los que
    -- sugiere su README) porque <leader>q ya es "Cerrar ventana" en
    -- core/keymaps.lua — chocarían con eso.
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {},
  },

  {
    -- Gestor de archivos flotante (el yazi real, no una reimplementación):
    -- previews, íconos, git status, renombrar/mover/borrar sin salir de nvim.
    -- Requiere el binario `yazi` del Brewfile.
    "mikavilpas/yazi.nvim",
    event = "VeryLazy",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    keys = {
      { "<leader>-", "<cmd>Yazi<CR>", desc = "Yazi: en el archivo actual" },
      { "<leader>cw", "<cmd>Yazi cwd<CR>", desc = "Yazi: en el directorio del proyecto" },
      {
        "<leader>fo",
        function()
          -- "Open Folder" es para abrir OTRO proyecto: modal "Acá mismo /
          -- Ventana nueva" para no pisar la que ya tenés abierta sin
          -- preguntar. vim.schedule: on_yazi_exited llama este hook
          -- SINCRÓNICAMENTE en medio del cierre de la ventana de yazi — sin
          -- el schedule, la tecla que usaste para salir (p.ej. "q") todavía
          -- puede quedar en el input queue y filtrarse al vim.ui.select que
          -- se abre acá, autoseleccionando una opción (o varias, si quedó
          -- más de una tecla en cola) → el modal "no se veía" o disparaba
          -- "Ventana nueva" solo, abriendo varias ventanas de golpe.
          require("yazi").yazi({
            hooks = {
              -- chosen_file viene seteado tanto si elegiste un ARCHIVO como
              -- si elegiste (no solo "saliste sobre") una CARPETA — yazi.nvim
              -- no distingue. Si es carpeta, el ask-modal de abajo es quien
              -- tiene que abrirla, no el opener por defecto de más abajo.
              yazi_closed_successfully = function(chosen_file, _, state)
                if chosen_file and vim.fn.isdirectory(chosen_file) == 0 then
                  return -- es un archivo de verdad, que lo abra el opener normal
                end
                local dir = chosen_file or state.last_directory.filename
                vim.schedule(function()
                  ask_open_window(dir, { on_same_window = open_project_here })
                end)
              end,
            },
            -- Sin esto, on_yazi_exited llama SIEMPRE open_file_function
            -- cuando chosen_file está seteado — el default (openers.open_file)
            -- hace `:edit <carpeta>` sin chequear si es directorio, abriéndola
            -- ahí mismo con netrw y saltándose el ask-modal de arriba entero.
            -- Para una carpeta no hacemos nada acá (ya la abrió el hook); para
            -- un archivo de verdad, delegamos al opener real.
            open_file_function = function(chosen_file, config, state)
              if vim.fn.isdirectory(chosen_file) == 1 then return end
              require("yazi.openers").open_file(chosen_file, config, state)
            end,
          }, vim.fn.expand("~/Documents"))
        end,
        desc = "Abrir carpeta (\"Open Folder\")",
      },
    },
    -- Nada de hooks acá: <leader>-/<leader>cw son para elegir un archivo
    -- para abrir, nada más. yazi.nvim llama yazi_closed_successfully igual
    -- cuando elegís un archivo (chosen_file != nil, lo abre solo) que cuando
    -- salís con "q" sin elegir nada (chosen_file == nil) — no hay forma de
    -- distinguir "salí sin elegir" de "confirmé una carpeta" desde acá, así
    -- que un hook acá terminaba mostrando el modal "Open Folder" al cerrar
    -- sin elegir, aunque estas dos teclas no son para abrir proyectos. Esa
    -- lógica vive solo en <leader>fo, que sí es para eso.
    opts = {},
  },

  {
    -- Guías verticales de indentación: ayuda a "ver" el espaciado
    -- (4 en Kotlin, 2 en Angular/TS) en archivos anidados.
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
  },

  {
    -- Las herramientas custom de android_tools/ (DroidLayout, DroidCreate,
    -- DroidSdk, el inspector de red) usan Snacks.win/Snacks.terminal
    -- directo, sin declararlo como dependencia de ningún plugin. Sin esto,
    -- cualquier vim.ui.select (pickers de android-nvim-plugin incluidos)
    -- usa el de fábrica: una lista numerada en el área de mensajes donde
    -- hay que TIPEAR el número y Enter, no navegar — con noice.nvim encima
    -- es facilísimo que pase desapercibida.
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    init = function()
      -- Reemplaza neo-tree: mismo motivo para apagar netrw (si no, un
      -- `nvim .` lo agarra netrw ANTES de que cargue cualquier explorador
      -- lazy) y mismo hack de abrir el explorador solo si el arg es un
      -- directorio.
      vim.g.loaded_netrw = 1
      vim.g.loaded_netrwPlugin = 1
      if vim.fn.argc(-1) == 1 then
        local arg = vim.fn.argv(0)
        local stat = vim.uv.fs_stat(arg)
        if stat and stat.type == "directory" then
          -- cwd explícito: nvim no hace :cd al directorio pasado como
          -- argumento, así que sin esto el explorer abriría en el cwd del
          -- shell, no en el directorio que realmente pediste.
          vim.api.nvim_create_autocmd("VimEnter", {
            once = true,
            callback = function() Snacks.explorer({ cwd = vim.fn.fnamemodify(arg, ":p") }) end,
          })
        end
      end
    end,
    keys = {
      -- Terminal integrado tipo VS Code: lo abre/oculta, no abre uno nuevo
      -- cada vez.
      { "<leader>tt", function() Snacks.terminal() end, desc = "Terminal (toggle)", mode = { "n", "t" } },
      -- Reemplaza project.nvim: Snacks.picker.projects ya detecta proyectos
      -- (dev dirs + patterns + recientes) sin el workaround de
      -- ProjectAttachPre/Post que project.nvim necesitaba (hacía el cd ANTES
      -- de poder preguntar). confirm corre ANTES de cualquier cd, así que
      -- ask_open_window decide primero y recién después cambia de directorio
      -- si corresponde.
      { "<leader>fp", open_projects_picker, desc = "Proyectos recientes" },
      -- Reemplaza neo-tree: explorer nativo de snacks, mismo toggle que ya
      -- tenías en <leader>e. Menos un plugin (y sus 3 dependencias propias:
      -- plenary, nui, devicons ya los traía snacks/otros plugins igual).
      { "<leader>e", function() Snacks.explorer() end, desc = "Explorador de archivos" },
    },
    opts = {
      picker = {
        ui_select = true,
        -- El explorer (abajo) usa "l" para abrir (estilo vim/netrw: h/l
        -- colapsa/entra) y no mapea <CR> en su lista de archivos por
        -- defecto — lo agregamos acá para que Enter también funcione,
        -- que es lo esperable viniendo de cualquier otro picker/Telescope.
        sources = {
          explorer = {
            win = { list = { keys = { ["<CR>"] = "confirm" } } },
          },
        },
      },
      explorer = {},
      -- Toasts de verdad (vim.notify) para TODO, incluido android-nvim-plugin
      -- y las herramientas :Droid* — antes no se veían en ningún lado (noice
      -- se los comía sin mostrarlos).
      notifier = { enabled = true },
      -- Dashboard al abrir nvim sin archivo: reemplaza alpha-nvim por el
      -- dashboard nativo de snacks (menos un plugin, y trae de fábrica las
      -- secciones Recent Files/Projects que antes armábamos a mano).
      -- Layout copiado de los ejemplos oficiales (docs/dashboard.md,
      -- preset "files"/"compact_files") — iconos y acciones por defecto
      -- tal cual los documenta el plugin, sin reinventarlos.
      dashboard = {
        preset = {
          -- Sin padding manual en la línea de ~ ni en "Android · Angular": el
          -- format "header" (abajo, align="center") ya centra cada línea solo,
          -- contra el ancho real del dashboard (lo fija el logo, 72). Espacios
          -- a mano acá se centran DE NUEVO encima de eso — quedaba corrido a
          -- la derecha por partida doble (snacks/dashboard.lua, D:align).
          header = [[

██      ██  ██████████    ██████    ████████    ██████████  ██      ██
████    ██  ██          ██      ██  ██      ██  ██          ██      ██
██  ██  ██  ████████    ██      ██  ██      ██  ████████    ██      ██
██    ████  ██          ██      ██  ██      ██  ██            ██  ██
██      ██  ██████████    ██████    ████████    ██████████      ██

]] .. string.rep("~", 66) .. [[

Android · Angular]],
          keys = {
            { icon = " ", key = "f", desc = "Buscar archivo", action = ":lua Snacks.dashboard.pick('files')" },
            { icon = " ", key = "n", desc = "Nuevo archivo", action = ":ene | startinsert" },
            { icon = " ", key = "g", desc = "Buscar texto", action = ":lua Snacks.dashboard.pick('live_grep')" },
            { icon = " ", key = "r", desc = "Archivos recientes", action = ":lua Snacks.dashboard.pick('oldfiles')" },
            { icon = " ", key = "p", desc = "Proyectos recientes", action = open_projects_picker },
            { icon = " ", key = "c", desc = "Config", action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})" },
            { icon = " ", key = "s", desc = "Restaurar sesión", section = "session" },
            { icon = "󰒲 ", key = "L", desc = "Lazy", action = ":Lazy", enabled = package.loaded.lazy ~= nil },
            { icon = " ", key = "q", desc = "Salir", action = ":qa" },
          },
        },
        sections = {
          { section = "header" },
          { section = "keys", gap = 1, padding = 1 },
          { icon = " ", title = "Archivos recientes", section = "recent_files", indent = 2, padding = { 2, 2 } },
          {
            icon = " ",
            title = "Proyectos",
            section = "projects",
            indent = 2,
            padding = 2,
            action = function(dir)
              ask_open_window(dir, { on_same_window = open_project_here })
            end,
          },
          { section = "startup" },
        },
      },
    },
    config = function(_, opts)
      require("snacks").setup(opts)
      -- opts.picker.ui_select=true debería bastar, pero en esta versión
      -- snacks.picker nunca llama a su propio setup() interno (bug del
      -- plugin, confirmado leyendo su código) y vim.ui.select se queda con
      -- el de fábrica. Lo seteamos nosotros para no depender de que lo
      -- arreglen upstream. Mismo trato para notify, por las dudas.
      vim.ui.select = require("snacks.picker").select
      vim.notify = require("snacks").notifier.notify
    end,
  },

}
