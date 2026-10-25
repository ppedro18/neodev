# compose-preview-interactive

`<leader>ci` / `:ComposePreviewInteractive` — preview de un `@Preview` de
Compose donde el gesto (drag, tap) y la animación que dispara realmente
corren, no un PNG estático. Usa el mismo `RenderTask`
(`com.android.tools.rendering`) que Android Studio usa para su
Interactive/Animation Preview — layoutlib real, no una reimplementación.
No es parte de `compose-preview.nvim` (ese solo renderiza PNG y no tiene
gancho para esto); la integración vive en `nvim/lua/plugins/compose.lua`,
que reusa los módulos Lua públicos de ese plugin
(gradle/scanner/toolchain/params/renderer) para no reimplementar la
detección de módulo/variant ni el manejo del toolchain/JDK.

Tres implementaciones en este directorio, mismo `RenderTask`/setup, distinta
capa de visualización/ciclo de vida:

- **`InteractiveDaemon`** — la que lanza `<leader>ci` hoy. Igual que
  `InteractiveWindow` (ventana Swing nativa, sin HTTP/PNG para los frames),
  pero el proceso Java **sobrevive** entre `<leader>ci` sucesivos: solo el
  primer `open` de la sesión paga el bootstrap de `RenderEnvironmentBootstrapper`
  (~1.8-2.0s); abrir otro `@Preview` después reusa el `Renderer` ya vivo (ver
  "Performance" abajo). Control por HTTP en localhost — pero solo control
  (`/ping`, `/open`, `/stop`); los frames nunca viajan por red, se pintan
  directo en el `JPanel` igual que en `InteractiveWindow`.
- **`InteractiveWindow`** — la versión de un solo uso (un proceso por
  `@Preview`, paga el bootstrap siempre). Ya no es lo que usa `<leader>ci`,
  queda como vía más simple si alguna vez hace falta depurar sin el daemon de
  por medio.
- **`InteractiveServer`** — la versión anterior (HTTP + PNG + página en el
  navegador). Sigue acá y compila igual, pero `<leader>ci` ya no la usa. Queda
  por si alguna vez hace falta tocarlo desde fuera de una ventana nativa
  (remoto, sin display, etc.).

## Compilar

```sh
JDK21=$(/usr/libexec/java_home -v 21+)
CP="$HOME/.cache/nvim/compose-preview/compose-preview-renderer-0.0.1-alpha16.jar:$HOME/.cache/nvim/compose-preview/layoutlib-17.0.0.jar"
"$JDK21/bin/javac" -cp "$CP" -d classes InteractiveDaemon.java InteractiveWindow.java InteractiveServer.java
```

(requiere haber abierto `:ComposePreview` una vez antes, para que esos dos
jars existan en el cache del plugin).

## Alcance v1 — qué hace y qué no

- Reacciona a PRESS/DRAG/RELEASE (mouse y touch) — verificado: mueve el
  composable de verdad, incluyendo el spring-back al soltar.
- Sin controles de scrub/pausa del reloj de animación.
- No soporta más de un `@Preview` renderizado a la vez desde el mismo
  archivo — usa el más cercano al cursor.
- Un solo preview interactivo a la vez, pero con `InteractiveDaemon` "abrir
  otro" ya no significa "matar el proceso y lanzar uno nuevo" — reemplaza el
  contenido de la misma ventana/proceso (ver "Daemon" abajo).
- `:ComposePreviewInteractiveStop` es lo único que mata el proceso del
  daemon. Cerrar la ventana (la X) solo la oculta — no mata el daemon, a
  propósito (ver "Daemon" abajo). Salir de nvim tampoco lo mata.

### Daemon (lo que usa `<leader>ci` hoy)

Medido (mismo Mac, misma JVM entre aberturas, 4 componentes reales distintos
del mismo proyecto — swipe, botón, badge, avatar): el primer `/open` de la
sesión paga el bootstrap completo; cualquier `/open` siguiente dentro del
mismo módulo/variant Gradle lo salta — solo construye un `RenderTask` nuevo
contra el `Renderer` ya vivo:

| apertura | `reuseBootstrap` | tiempo |
|---|---|---|
| 1ra (swipe, frío) | `false` | ~1844ms |
| 2da (botón, distinto componente) | `true` | ~101ms |
| 3ra (badge) | `true` | ~41ms |
| 4ta (avatar) | `true` | ~42ms |

Si el próximo `@Preview` que abrís vive en un módulo/variant Gradle distinto
del que ya está cargado (`namespace`/`classPath`/`resourceApkPath` no
coinciden), el daemon lo detecta y re-bootstrapea completo — correcto, pero
paga el costo de nuevo en ese caso puntual.

Puerto de control: `~/.cache/nvim/compose-preview/interactive-daemon.port`
(mismo cache dir que ya usa `compose-preview.nvim`) — ahí lo busca
`compose.lua` entre invocaciones y entre reinicios de nvim. Si el archivo
apunta a un proceso que ya no corre (la máquina se reinició, por ejemplo),
`compose.lua` lo detecta (`/ping` falla) y lanza uno nuevo.

Decisión de producto: cerrar la ventana no mata el daemon, y nvim tampoco lo
mata al salir — matar el proceso en cualquiera de esos dos momentos volvería
a pagar el cold start en el próximo `<leader>ci`, exactamente lo que esto
existe para evitar. `:ComposePreviewInteractiveStop` es la única vía que de
verdad lo termina.

### Performance (medido, no estimado)

El primer intento se sentía lento. Medido con `System.nanoTime()` alrededor de
cada etapa (`MGSwipeableButtonPreview` real, no un caso de juguete): **el
cuello de botella no era `render()`** (3-4ms en caliente) **sino encodear el
PNG a resolución completa de teléfono** (1080x2400 medido) — 80-130ms por
frame, >85% del tiempo de cada `/touch`, aunque el `<img>` lo muestra achicado
al viewport igual. Esto también explica por qué el loop idle a 100ms
mencionado antes saturaba un core entero: no era el render, era encodear ese
PNG completo 10 veces por segundo.

Fix (en `InteractiveServer.renderNow`/`downscale`): bajar a `TARGET_WIDTH =
480` antes de encodear — corta el encode a ~10ms. Además, `/touch` devuelve
el frame nuevo en la misma respuesta (antes el cliente hacía un segundo GET a
`/frame.png` después), y el JS ya no encola un POST por cada `mousemove` —
solo manda la última posición conocida una vez que el anterior vuelve
(`inFlight`/`pending` en `indexHtml()`).

Antes/después (steady-state, mismo fixture):

| | antes | después |
|---|---|---|
| `/touch` handler total | ~92-96ms | ~18-20ms |
| encode PNG | ~80-85ms | ~9-10ms |
| round-trip real (curl) | ~100ms | ~20-30ms |

### InteractiveWindow (lo que usa `<leader>ci` hoy)

Sin HTTP ni PNG: el touch pasa por `triggerTouchEvent` + `executeCallbacks` +
`render()` y el resultado se pinta directo en el `JPanel` — nada que
codificar, nada que mandar por red, nada que decodificar en un navegador.
Medido (mismo fixture, `MGSwipeableButtonPreview`, ventana nativa real sobre
este mismo Mac — `java.awt.Robot` no tiene permiso de Accessibility en este
shell, así que la verificación de gesto real usó `MouseEvent` sintéticos
despachados directo al panel, no al sistema operativo; el resultado —cambios
de píxeles reales entre reposo→arrastrado→soltado— es el mismo que verificar
con el mouse real):

| | HTTP (antes) | HTTP (optimizado) | **ventana nativa** |
|---|---|---|---|
| touch → frame visible | ~92-96ms | ~18-20ms | **~4-10ms** |

**Sin animación idle** sigue sin estar, en ninguna de las dos vías — es una
feature separada, a decidir aparte, no algo que faltó por descuido. Para
`InteractiveServer` ya no aplicaría tan fuerte el motivo original ("saturaba
un core") ahora que el encode es barato; para `InteractiveWindow` el
argumento es todavía más fuerte — sin encode en absoluto, un loop idle sería
trivial de sostener — pero sigue sin construirse en ninguna de las dos.

Queda en stderr un `PERF ...` por cada render/touch (costo de un `printf`,
no afecta nada) — útil si hace falta volver a medir esto.
