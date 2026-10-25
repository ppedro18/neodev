# NeoDev

Neovim configurado como entorno de desarrollo para **Kotlin / Android**
(prioridad actual) con soporte secundario para **Angular / TypeScript**.
Un solo script instala todo en macOS o Linux.

## Instalación

```bash
git clone <tu-fork> ~/NeoDev
cd ~/NeoDev
./install.sh
```

Esto: instala Homebrew si falta (funciona igual en macOS y Linux), instala
Neovim + JDK 21 + Kotlin + Gradle + Node vía `Brewfile`, respalda tu
`~/.config/nvim` actual si existe, enlaza este repo en su lugar, e instala
plugins y servidores LSP/DAP de forma headless.

Para revertir: `./uninstall.sh` (restaura tu config anterior desde el backup).

## Qué ya existía, y qué elegí

Antes de escribir esto, revisé lo que ya hay para Kotlin/Android en Neovim:

| Proyecto | Qué es | Por qué sí/no |
|---|---|---|
| [fwcd/kotlin-language-server](https://github.com/fwcd/kotlin-language-server) | LSP comunitario, el clásico | En mantenimiento mínimo, menos features que el oficial |
| [Kotlin/kotlin-lsp](https://github.com/Kotlin/kotlin-lsp) | **LSP oficial de JetBrains** (feb. 2026), mismo motor que IntelliJ/Android Studio, JRE incluida | **Elegido** — es el más completo y el que se mantiene activamente |
| [AlexandrosAlexiou/kotlin.nvim](https://github.com/AlexandrosAlexiou/kotlin.nvim) | Capa cliente sobre kotlin-lsp: inlay hints, intentions, refactors, debugging vía nvim-dap | **Elegido** — sin él, kotlin-lsp solo no da paridad con el plugin de VS Code |
| [WarrenBuffering/android-neovim-lsp](https://github.com/WarrenBuffering/android-neovim-lsp) | LSP alternativo standalone, enfocado en import de proyectos Gradle/Android | No elegido: correr dos LSPs de Kotlin a la vez es redundante; kotlin-lsp ya es Gradle-aware y tiene más respaldo (JetBrains) |

Para Angular: `typescript-language-server` + `angular-language-server`
(`angularls`) vía Mason, más [ng.nvim](https://github.com/joeveiga/ng.nvim)
para comandos extra (ir a template del componente, etc).

### kotlin-lsp NO se instala con Mason (bug real, no de este repo)

Al instalar se vio que `kotlin-lsp` fallaba siempre. Investigando el log
(`~/.local/state/nvim/mason.log`) la causa real son dos bugs encadenados:

1. El paquete `kotlin-lsp` del registry de Mason descarga de
   `download-cdn.jetbrains.com`, que da **404** (host roto / build viejo
   retirado del CDN). No depende de este repo, es un bug del registry.
2. `nvim --headless "+MasonToolsInstall" +qa"` (lo que hacía `install.sh`)
   cierra nvim con `+qa` antes de que Mason termine de instalar en segundo
   plano — todo quedaba "Installation aborted". Arreglado: ahora usa
   `+MasonToolsInstallSync`, que sí espera.

**Fix real**: JetBrains mantiene su propio tap de Homebrew que sí funciona:
`brew install jetbrains/utils/kotlin-lsp` — `install.sh` ya lo hace. El
default de `nvim-lspconfig` busca el binario como `intellij-server`, pero
el tap lo deja en el PATH como `kotlin-lsp` (mismo binario, symlink con otro
nombre); por eso `lsp/kotlin_lsp.lua` fija `cmd` a mano.

**Limitación real para Linux**: la fórmula de JetBrains lo dice en su propio
código — *"we don't want to support brew packages on Linux"* — y solo
publican artefactos macOS (x64/arm64). Hoy no hay forma oficial de instalar
`kotlin-lsp` en Linux; `install.sh` te avisa y sugiere
[fwcd/kotlin-language-server](https://github.com/fwcd/kotlin-language-server)
(JVM puro) como alternativa mientras tanto.

### nvim-treesitter cambió de API (otro bug real, no de este repo)

Al probar en una instalación real salió `module 'nvim-treesitter.configs' not
found`. La rama `main` de nvim-treesitter (la que trae por defecto ahora)
reescribió su API: ya no existe `require('nvim-treesitter.configs').setup()`
con `highlight = { enable = true }`. Ahora es `require('nvim-treesitter').install({...})`
para los parsers, y el highlighting/indent se prenden a mano con un autocmd
de `FileType` (`vim.treesitter.start()`), como documenta el propio README
del plugin. Ya está así en `plugins/treesitter.lua`.

Además, esa rama nueva necesita el CLI `tree-sitter` para compilar los
parsers (antes no hacía falta). **Ojo con el nombre del formula de
Homebrew**: `brew install tree-sitter` instala solo la librería C, no el
CLI — el correcto es `tree-sitter-cli` (ya está en el `Brewfile`).

### Build/run/emulador, Compose preview y GitHub

También revisé qué existe para correr la app, ver el logcat, manejar
emuladores, previsualizar Jetpack Compose y trabajar con GitHub sin salir
de nvim:

| Necesidad | Proyecto | Por qué sí/no |
|---|---|---|
| Build + run + logcat + devices/AVD + Gradle tasks | [iamironz/android-nvim-plugin](https://github.com/iamironz/android-nvim-plugin) | **Elegido** (revisado oct. 2026) — build variant-aware (lee `isDefault` de `buildTypes`/`productFlavors`), Gradle task browser con cache, logcat con filtros/regex/stack-trace-jump/auto-reconnect, device manager + AVD, menú interactivo (`:AndroidMenu`). Suite de tests propia, CI, docs estructuradas. El propio autor lo describe como joven ("buggy and probably leaks memory" en su README), pero verificado vía API de GitHub tiene 92★/5 forks y sigue recibiendo commits — mucho más uso real que la alternativa anterior |
| Elegido antes, reemplazado | [AntoineGagnon/android.nvim](https://github.com/AntoineGagnon/android.nvim) | Usado hasta oct. 2026: cubría 4 comandos básicos, pero verificando fechas reales vía API de GitHub resultó tener **1 estrella** y quedó sin tocar a los 2 días de creado. Todo lo variant-aware se tuvo que reimplementar a mano encima (parcheando sus módulos internos). Esa config y sus parches quedan en [legacy/android-nvim-antoinegagnon/](legacy/android-nvim-antoinegagnon/) por si hace falta volver |
| Solo Gradle+AVD+ADB | [Marfien/astudio.nvim](https://github.com/Marfien/astudio.nvim) | No elegido: menos features que android-nvim-plugin y explícitamente no toca Kotlin (ya resuelto con kotlin-lsp) |
| Compose `@Preview` | [ntsk/compose-preview.nvim](https://github.com/ntsk/compose-preview.nvim) | **Elegido** — único plugin real para esto: renderiza con layoutlib (Google) vía Gradle, sin Android Studio ni emulador. Primer uso descarga ~300MB. Tiene issues abiertos (sep. 2026) con configuration cache y `@Preview` sin argumentos; úsalo sabiendo que es joven. Su detección de variantes además **no funciona en módulos `com.android.library`** (solo `application`) — confirmado reproduciendo su Gradle task a mano; arreglado con un override local, ver abajo |
| GitHub (PRs/issues) | [pwntester/octo.nvim](https://github.com/pwntester/octo.nvim) | **Elegido** — el mantenido activamente; usa `gh` CLI, que ya está en el `Brewfile` |

**Por qué ya no se parchea un plugin de terceros**: con
`AntoineGagnon/android.nvim`, para variant-aware builds y accesos a
scrcpy/android-cli hubo que *parchear* módulos internos del plugin instalado
(un script copiaba `.lua` propios encima de `lua/android/` dentro de
`~/.local/share/nvim/lazy/android.nvim/`) — frágil: dependía de que el
plugin de turno expusiera justo esos módulos internos, y cualquier cambio
de versión podía romperlo en silencio. Al revisar `iamironz/android-nvim-plugin`
(que no expone una API pública pensada para esto) se aprovechó para sacar
esa lógica de la órbita de cualquier plugin: ahora vive en
`nvim/lua/android_tools/` (mismo patrón que `lua/lsp/<nombre>.lua`), módulos
propios de esta config, sin parches ni scripts post-instalación. Lo
variant-aware/Gradle-tasks ya no se reimplementa: lo da
`iamironz/android-nvim-plugin` directo.

**Override del init-script de Gradle de `compose-preview.nvim`**: su detección
de variantes (`nvim/gradle/compose-preview.init.gradle` original, dentro del
plugin) busca tasks `process<Variante>Resources` — eso solo existe en
módulos `com.android.application`. En un módulo `com.android.library` esa
task no existe (confirmado reproduciendo `./gradlew :modulo:composePreviewInfo`
a mano); lo único que matchea el patrón ahí son las tasks de Navigation Safe
Args (`processDebugNavigationResources`), sin `compile*Kotlin` equivalente,
así que la lista de variantes quedaba siempre vacía (`variant nil not found`).
El plugin busca ese archivo con `nvim_get_runtime_file` (primer match del
runtimepath gana), así que [nvim/gradle/compose-preview.init.gradle](nvim/gradle/compose-preview.init.gradle)
en este repo lo pisa sin tocar los archivos instalados del plugin (sobrevive
a updates) — misma idea que `android_tools/`, usar el punto de extensión que
el propio plugin ya expone en vez de parchear sus internals. Cambios reales:

1. Detectar variantes desde `compile<Variante>Kotlin`/`...JavaWithJavac`
   (existen igual en `library` y `application`) en vez de
   `process<Variante>Resources`.
2. En un módulo `library`, AGP nunca linkea un APK de recursos
   (`intermediates/linked_resources_binary_format/`, confirmado reproduciendo
   la task a mano) — eso lo genera solo un módulo `application`. El renderer
   (`compose-preview-renderer`, binario de Google/JetBrains, no Lua) lo
   necesita sí o sí. Fix: si el módulo es `library`, el script busca un módulo
   `application` hermano en el mismo build que lo tenga como dependencia
   (`implementation`/`api`) y le **presta** su `.ap_` ya linkeado —
   auto-detect por grafo de dependencias, o `-PcomposePreviewHostProject=:app`
   si hay más de un candidato o ninguno. El namespace/classpath del preview
   siguen siendo los del propio módulo library; solo el `.ap_` viene prestado.
3. Con el `.ap_` prestado, aparece un segundo problema, más sutil: el R class
   propio de la library (`compile_r_class_jar`) es de solo-compilación —
   confirmado con `javap`, sus campos son `public static int` (sin `final`),
   simples placeholders de build, nunca los valores reales que terminan
   linkeados en un APK. Al no ser `final` el compilador no los inlinea, así
   que el bytecode del `@Preview` hace un read real del campo en runtime — si
   el classloader carga ese R class placeholder en vez del R class final del
   host, cualquier `painterResource`/recurso puede romper con errores sin
   relación aparente (se vio como `Resources$NotFoundException:
   Window_backgroundDimAmount`, un styleable de Android, nada que ver con el
   recurso real). Fix: cuando se presta el `.ap_`, el R.jar propio de la
   library se excluye del classpath del preview — se usa únicamente el
   R.jar del host (`compile_and_runtime_*_r_class_jar`, que agrega el de
   *todas* las dependencias con los valores reales, incluida esta library).
   Confirmado end-to-end: `MGStatusBadge.kt` y `MGSwipeableButton.kt`
   (ambos en el módulo library, con íconos vía `painterResource`) renderizan
   limpio directo desde su archivo original, sin wrapper ni duplicado en
   ningún módulo `application`.

Límite real que queda: si el build tiene más de un módulo `application`
consumiendo la misma library (o ninguno), el auto-detect no adivina —
hace falta `-PcomposePreviewHostProject`. Y si el composable solo lo
consume un módulo que a su vez no es `application` (p. ej. otra library),
no hay de dónde prestar un `.ap_` — ahí sigue sin arreglo liviano, hace
falta Android Studio.

El buscador (`<leader>ff`/`<leader>fg`, Telescope) ya estaba desde el primer
commit — lo usan tanto `android-nvim-plugin` (picker de device/AVD) como
`octo.nvim` (listas de PRs/issues).

### Qué faltaba para Android (y ya se agregó)

- **XML** (layouts, `AndroidManifest.xml`, `res/values/*.xml`): no tenía ni
  treesitter ni LSP. Agregado: parser `xml` + [lemminx](https://github.com/redhat-developer/vscode-xml)
  (vía Mason) en `lsp/lemminx.lua`. Solo importa si tu proyecto usa Views
  además de (o en vez de) Compose.
- **Formato y lint reales de Kotlin**: antes solo formateaba con el LSP
  (el motor de IntelliJ); le falta el estándar de facto en CI/Android,
  [ktlint](https://github.com/pinterest/ktlint). Agregado en
  `plugins/quality.lua`: [conform.nvim](https://github.com/stevearc/conform.nvim)
  formatea `.kt` con ktlint al guardar (`<leader>f` o automático), y
  [nvim-lint](https://github.com/mfussenegger/nvim-lint) muestra sus
  warnings como diagnósticos mientras escribes.
- **TOML** (`gradle/libs.versions.toml`, version catalogs): agregado el
  parser de treesitter para que al menos resalte bien la sintaxis.
- **Comandos `:Droid*`**: lo que no cubre ningún plugin — originalmente visto
  en [rizukirr/droid-nvim](https://github.com/rizukirr/droid-nvim) y portado
  primero como parches y ahora a `nvim/lua/android_tools/`, módulos propios
  de esta config, independientes de cualquier plugin de terceros (ver "Por
  qué ya no se parchea un plugin de terceros" más arriba).
  - **Mirror** (`android_tools.adb`, sin dependencias nuevas): `<leader>av`
    (`:DroidMirror`) espeja la pantalla con
    [scrcpy](https://github.com/Genymobile/scrcpy) (`brew install scrcpy`,
    ya en el `Brewfile`, no viene con el SDK). Elegir/crear/borrar AVD y
    elegir device ahora lo da el Device Manager de `android-nvim-plugin`
    (`<leader>ao`); `:DroidSelectDevice` queda solo para apuntar estas
    herramientas custom (mirror, inspector de red, `:Droid*` de android-cli)
    a un device distinto cuando hay más de uno conectado.
  - **Acción rápida de ADB**: `:DroidForceStop` (clear-data y uninstall ya
    los da el Device Manager de `android-nvim-plugin`, `<leader>ao`).
  - **`:DroidLogcatClearHistory`**: `android-nvim-plugin` no tiene forma de
    borrar una entrada del historial de filtros de logcat desde su picker
    (peor, cancelar el picker vuelve a guardar el filtro activo igual —
    ver `logcat/session/controls.lua` de ese plugin). Esto limpia el
    historial *y* el filtro activo editando directo su archivo de estado
    (`stdpath("state")/android/<workspace>.json`), sin depender de ningún
    módulo interno del plugin. Hace falta cerrar y reabrir nvim después:
    el plugin solo relee ese archivo al arrancar.
  - **Navegación de Gradle**: `:DroidGradleModule` / `:DroidGradleProject` /
    `:DroidGradleSettings` / `:DroidGradleVersion` saltan al `build.gradle(.kts)`
    del módulo actual, al de la raíz, al `settings.gradle(.kts)` o al
    `gradle/libs.versions.toml` (agregá `:vert` adelante para abrir en split).
  - **`:DroidLayout`, `:DroidScreenshot`, `:DroidDocs`, `:DroidCreate`,
    `:DroidSdk`, `:DroidLint`, `:DroidDeclaration`, `:DroidUsages`,
    `:DroidVersions`, `:DroidStudioOpen`**: necesitan
    [android-cli](https://developer.android.com/tools/agents), la CLI oficial
    de Google (binario `android`, no está en Homebrew — se instala aparte).
    Sin instalarla, cada comando avisa claro en vez de fallar en silencio;
    los últimos cinco además necesitan Android Studio corriendo con el
    proyecto abierto y sincronizado.

### Que se vea y se sienta como un IDE

- **Explorador lateral**: [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)
  (`<leader>e`) — iconos, estado de git por archivo, y pestañas
  File/Buffers/Git dentro del propio panel. Es lo que trae AstroNvim/LazyVim
  por defecto; no hace falta todo el framework para tenerlo, es este plugin
  suelto (reemplazó a nvim-tree, que era más simple pero menos "IDE").
- **Cmdline/mensajes flotantes**: [noice.nvim](https://github.com/folke/noice.nvim)
  — al tocar `:` sale un input flotante arriba en vez de la línea de abajo
  de siempre; mismo look de AstroNvim/LazyVim.
- **"Recientes"**: [project.nvim](https://github.com/DrKJeff16/project.nvim)
  (`<leader>fp`) — detecta la raíz del proyecto (Gradle, Angular, git...) y
  guarda historial, para saltar de proyecto sin cerrar nvim ni abrir otra
  terminal. Usé el fork `DrKJeff16` porque el original (`ahmedkhalf`) está
  sin mantenimiento.
- **"Open Folder"** (proyectos que todavía no abriste ninguna vez, no están
  en "recientes"): `<leader>fo` — abre yazi.nvim (ya instalado, ver abajo)
  arrancando en `~/Documents`; navegás con el file manager real. No agregué
  ningún plugin nuevo para esto.
- **"Acá mismo" o "ventana nueva"**: tanto `<leader>fp` (recientes) como
  `<leader>fo`/`<leader>-`/`<leader>cw` (yazi) preguntan, al elegir un
  proyecto, si seguir en esta misma ventana de nvim o abrir una Ghostty
  nueva aparte (sin cerrar la actual) — como "Open in New Window" de
  cualquier IDE. Usa los hooks reales de cada plugin (`ProjectAttachPre`/
  `Post` de project.nvim, `yazi_closed_successfully` de yazi.nvim), no
  `change_neovim_cwd_on_close` a ciegas.
- **Pestañas de archivos abiertos arriba**: [bufferline.nvim](https://github.com/akinsho/bufferline.nvim)
  (`<S-h>`/`<S-l>` para moverte, `<leader>bd` para cerrar).
- **Gestor de archivos completo**: [yazi.nvim](https://github.com/mikavilpas/yazi.nvim)
  (`<leader>-`) — el yazi real (terminal file manager) en una ventana
  flotante: previews, iconos, git status, cortar/pegar/renombrar sin salir
  de nvim. Complementa a neo-tree (panel fijo liviano) para cuando necesitas
  operar archivos de verdad, no solo navegar.

**Nerd Font obligatoria**: todo lo anterior (+ lualine, which-key) usa
glifos de [Nerd Font](https://www.nerdfonts.com/). Sin ella ves `?` en vez
de íconos. `install.sh` instala JetBrainsMono Nerd Font sola.

**Terminal recomendada: [Ghostty](https://ghostty.org/)**. En Terminal.app
(la nativa de macOS) elegir la fuente es un clic manual en sus
Preferencias — no hay forma de automatizar eso. Ghostty en cambio se
configura por archivo de texto (`ghostty.config` en este repo, que
`install.sh` copia solo a `~/.config/ghostty/config`), así que queda
andando con los íconos correctos sin que toques nada. Elegí Ghostty sobre
Kitty por ser más simple de configurar (menos perillas) con el mismo
rendimiento GPU; si preferís Kitty u otra, el mismo `font-family =
JetBrainsMono Nerd Font Mono` aplica en su config.

**Importante**: una sesión de nvim que ya tenías abierta ANTES de correr
`install.sh` no ve los plugins nuevos — nvim no recarga su config en
caliente. Cerrala del todo (`:qa`) y abrí una nueva.

### Espaciado (indentación)

Antes todo el proyecto usaba 4 espacios fijos. Ahora hay tres capas, de
más a menos prioridad:

1. **`.editorconfig` del proyecto** — Neovim lo lee nativo desde la 0.9
   (`vim.g.editorconfig = true` en `core/options.lua`), sin plugin. Si el
   repo donde trabajas tiene uno, gana siempre.
2. **Por filetype** (`core/autocmds.lua`): Angular/TS/HTML/CSS/JSON/YAML
   quedan en 2 espacios (su convención real); todo lo demás, incluido
   Kotlin, se queda en el default de `core/options.lua`.
3. **Default global** (`core/options.lua`): 4 espacios (convención
   Kotlin/IntelliJ).

Para *ver* el espaciado agregué guías verticales de indentación
([indent-blankline.nvim](https://github.com/lukas-reineke/indent-blankline.nvim),
en `plugins/ui.lua`).

### Velocidad de edición y snippets

- **Autopairs, surround y text objects**: en vez de tres plugins sueltos,
  un solo repo con módulos independientes —
  [mini.nvim](https://github.com/nvim-mini/mini.nvim) (`mini.pairs`,
  `mini.surround`, `mini.ai`) en `plugins/editing.lua`. Cierra paréntesis
  solo, y `ys)` / `cs"'` (etc.) para agregar/cambiar comillas, paréntesis,
  tags...
- **Salto rápido**: [flash.nvim](https://github.com/folke/flash.nvim) —
  `s` + 2 letras salta a cualquier palabra visible en pantalla; `S` salta
  por nodos de treesitter (útil para moverte entre funciones/composables
  sin contar líneas).
- **Tags HTML/Angular**: [nvim-ts-autotag](https://github.com/windwp/nvim-ts-autotag)
  cierra y renombra automáticamente al editar templates (`plugins/angular.lua`).
- **Snippets listos**: [friendly-snippets](https://github.com/rafamadriz/friendly-snippets)
  cargado en LuaSnip (`plugins/completion.lua`) — cubre bien TS/JS/HTML/CSS/JSON,
  que es justo donde Angular no tiene nada parecido al punto 2.
- **Snippets de Kotlin, a propósito NO agregué un paquete dedicado.**
  Revisé [franckrasolo/luasnip4k.nvim](https://github.com/franckrasolo/luasnip4k.nvim):
  cubre Kotlin core + la librería http4k (framework HTTP server-side), nada
  de Android/Compose/coroutines — no aplica a este repo. Lo "inteligente"
  en Kotlin ya lo da **kotlin-lsp** (motor de IntelliJ) vía `kotlin.nvim`:
  completado semántico, postfix templates e inspecciones — eso es
  estrictamente mejor que un snippet de texto estático, porque entiende el
  tipo real en el que estás parado.

### Que los errores se vean bien

- **Diagnósticos con íconos y popup prolijo** (`plugins/lsp.lua`):
  `✘`/`▲`/`●`/`○` por severidad en el margen, y `vim.diagnostic.open_float()`
  (`<leader>de`) con borde redondeado y la fuente del error (de qué linter/LSP
  viene: kotlin-lsp, ktlint, eslint...).
- **Inlay hints activados automáticamente** cuando el servidor los soporta
  (tipos inferidos, nombres de parámetros) — antes estaban disponibles pero
  no encendidos.
- **[trouble.nvim](https://github.com/folke/trouble.nvim)** (`plugins/quality.lua`):
  panel con *todos* los diagnósticos del proyecto o del buffer actual,
  navegable, en vez de ir error por error con `]d`.

### Bug real: las notificaciones (`vim.notify`) no se veían en ningún lado

Con `noice.nvim` instalado, `vim.notify()` (lo que usan `android-nvim-plugin`,
mason, y casi todos los plugins para avisar "listo"/"falló") quedaba
interceptado por noice pero sin mostrarse — ni como toast, ni en
`:messages`. Encima `snacks.nvim` *también* debería haberlo manejado
(`notifier.enabled`), pero como con `ui_select`, su wiring interno no se
dispara solo en esta versión. Arreglado en `plugins/ui.lua`:
`notify = { enabled = false }` en noice, y `vim.notify =
require("snacks").notifier.notify` seteado a mano. Ahora cualquier
`vim.notify()` de cualquier plugin aparece como toast arriba a la derecha.

### Lo que queda fuera a propósito (opcional, pídelo si lo necesitas)

- **detekt**: análisis estático más pesado que ktlint; se corre normalmente
  como task de Gradle (`./gradlew detekt`) o en CI, no en cada guardado.
  No lo conecté al editor por eso — si lo quieres en tiempo real, se agrega
  a `linters_by_ft` en `quality.lua`.
- **Snippets de Compose/Android** (plantillas para `@Composable`,
  `ViewModel`, etc.): no agregué ninguno; LuaSnip ya está instalado
  (dependencia de `nvim-cmp`) así que es solo escribir los `.lua` de
  snippets si los quieres.
- **Correr tests** (`./gradlew test` / `connectedAndroidTest`): no hay
  comando dedicado; úsalo desde la terminal flotante de LazyGit (`<leader>gg`)
  o `:terminal ./gradlew test`.

## Arquitectura

Cada archivo tiene una sola responsabilidad y los lenguajes son puntos de
extensión, no lógica hardcodeada (Clean Architecture / SOLID aplicado a un
dotfiles repo):

```
nvim/
├── init.lua                 # bootstrap de lazy.nvim + carga de core/
├── lua/core/                # opciones, keymaps globales y autocmds (sin plugins)
├── lua/plugins/             # un archivo por plugin/concepto (ui, treesitter,
│                             # completion, editing, quality, git, mason, lsp,
│                             # kotlin, angular, android, compose, dap)
├── lua/lsp/                 # un archivo por servidor LSP (kotlin_lsp, angularls,
│                             # ts_ls, eslint, lemminx) — agregar lenguaje =
│                             # agregar archivo
└── lua/android_tools/       # herramientas Android 100% propias (mirror,
                              # android-cli, nav de Gradle) — sin parches ni
                              # dependencia de ningún plugin de terceros
```

- **SRP**: `plugins/kotlin.lua` no sabe nada de Angular, ni viceversa.
- **OCP**: `plugins/lsp.lua` solo itera una lista de nombres de servidor y
  `require`s el archivo correspondiente en `lsp/`; soportar un lenguaje
  nuevo es agregar un archivo ahí, sin tocar el motor.
- **DIP**: el motor LSP (`lsp.lua`) depende de la convención
  `lsp.<nombre>.lua -> tabla de config`, no de ningún lenguaje concreto.

Usa la API nativa de Neovim 0.11+ (`vim.lsp.config` / `vim.lsp.enable`), no
el patrón viejo `require('lspconfig').x.setup{}`.

### Cómo distinguir qué es de Kotlin y qué es de Angular

No hay una carpeta separada por lenguaje porque el nombre del archivo ya
es la etiqueta:

| Lenguaje | Plugin(s) | LSP(s) |
|---|---|---|
| Kotlin / Android | `plugins/kotlin.lua`, `plugins/android.lua`, `plugins/compose.lua` | `lsp/kotlin_lsp.lua`, `lsp/lemminx.lua` |
| Angular / TypeScript | `plugins/angular.lua` | `lsp/angularls.lua`, `lsp/ts_ls.lua`, `lsp/eslint.lua` |
| Compartido (no es de ningún lenguaje) | `ui.lua`, `treesitter.lua`, `completion.lua`, `editing.lua`, `git.lua`, `mason.lua`, `lsp.lua`, `quality.lua`, `dap.lua` | — |

Los archivos "Kotlin" y "Angular" además tienen un `ft = {...}` (filetype):
es lo que hace que, por ejemplo, `plugins/angular.lua` ni siquiera cargue
en memoria si nunca abres un `.ts`/`.html` — y viceversa con `.kt` para
Kotlin. No es solo organización en el repo, es el gatillo real de carga.

Para verlo en caliente dentro de nvim, sin leer código:
- `:LspInfo` — con el buffer activo, dice qué servidor LSP está adjunto
  ahí mismo (ej. abre un `.ts` y verás `ts_ls`/`angularls`; abre un `.kt`
  y verás `kotlin_lsp`).
- `:Lazy` — lista todos los plugins y si están cargados o no (y por qué
  trigger: `ft`, `cmd`, `keys`...).
- `treesitter.lua` y `mason.lua` sí mezclan ambos lenguajes en una sola
  lista, pero con comentarios que agrupan cada bloque (`-- Kotlin / Android`
  / `-- Angular / TypeScript` / `-- Compartido`).

## Requisitos

- macOS o Linux
- Android SDK ya instalado (de Android Studio, o `sdkmanager`), con `adb` y
  `emulator` en el PATH — `<leader>ao` (Device Manager de
  `android-nvim-plugin`) lista los AVDs que ya existen, y también puede
  crear uno nuevo o borrar uno.
- `ANDROID_HOME`/`ANDROID_SDK_ROOT` apuntando al SDK — ver mensaje final de
  `install.sh`.
- [scrcpy](https://github.com/Genymobile/scrcpy) (`brew install scrcpy`,
  ya en el `Brewfile`) para espejar la pantalla con `<leader>av` /
  `:DroidMirror`.
- Opcional, para `:DroidLayout`/`:DroidScreenshot`/`:DroidDocs`/`:DroidCreate`/
  `:DroidSdk`/`:DroidLint`/`:DroidDeclaration`/`:DroidUsages`/`:DroidVersions`/
  `:DroidStudioOpen`: [android-cli](https://developer.android.com/tools/agents)
  (binario `android` en el PATH). No está en Homebrew, así que no va en el
  `Brewfile`; sin instalarla, esos comandos simplemente avisan que falta.
- Para GitHub (`octo.nvim`): `gh auth login` una vez (ya viene `gh` en el
  `Brewfile`).

## Keymaps principales

| Tecla | Acción |
|---|---|
| `<leader>ff` / `<leader>fg` | Buscar archivos / texto (Telescope) |
| `<leader>e` | Explorador de archivos (neo-tree) |
| `<leader>-` / `<leader>cw` | Yazi: en el archivo actual / en el directorio del proyecto |
| `<S-h>` / `<S-l>` | Buffer anterior / siguiente |
| `<leader>bd` | Cerrar buffer |
| `<leader>gg` | LazyGit (ventana flotante) |
| `gd` / `gr` / `K` | Ir a definición / referencias / hover (LSP) |
| `<leader>rn` / `<leader>ca` | Renombrar / code action (LSP) |
| `<leader>f` | Formatear buffer (ktlint en `.kt`, también al guardar) |
| `<F5>` `<F10>` `<F11>` `<F12>` | Debug: continue / step over / into / out |
| `<leader>db` / `<leader>du` | Debug: breakpoint / toggle UI |
| `<leader>am` | Android: menú principal (`:AndroidMenu`) |
| `<leader>at` | Android: build variants / Gradle tasks (`:AndroidTargets`) |
| `<leader>ao` | Android: device manager / ADB (`:AndroidTools`) |
| `<leader>aa` | Android: acciones (`:AndroidActions`) |
| `<leader>ab` / `<leader>aB` | Android: build con la variante guardada / eligiendo módulo y variante |
| `<leader>al` | Android: logcat (filtra por tu app automáticamente) |
| `<leader>ah` | Android: limpiar historial/filtro de logcat (`:DroidLogcatClearHistory`) |
| `<leader>av` | Android: espejar pantalla con scrcpy (`:DroidMirror`) |
| `<leader>cp` | Compose: renderizar `@Preview` (abre en el navegador) |
| `<leader>go` / `<leader>gi` | GitHub: listar PRs / issues (octo.nvim) |
| `<leader>tt` | Terminal integrado (toggle, no abre uno nuevo cada vez) |
| `<leader>an` | Android: inspector de red (lee logcat de OkHttp, sin proxy ni certificados) |
| `<leader>de` | Ver el error de la línea actual en detalle |
| `<leader>xx` / `<leader>xb` | Panel de diagnósticos: proyecto / buffer (trouble.nvim) |
| `s` / `S` | Flash: saltar a cualquier texto visible / a un nodo de treesitter |
| `ys)` `cs"'` `ds"` (etc.) | mini.surround: agregar / cambiar / quitar comillas, paréntesis... |

## Roadmap

Angular queda con lo esencial (LSP + lint); si el foco cambia hacia
frontend, lo siguiente sería snippets de componentes y DAP para Node/Chrome.
