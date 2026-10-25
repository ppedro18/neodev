// Preview interactivo de un @Preview de Compose: mantiene vivo el mismo RenderTask
// (com.android.tools.rendering) que usa Android Studio para su Interactive/Animation
// Preview — layoutlib real, no una reimplementación — y lo expone por HTTP para
// tocarlo desde el navegador. Probado a mano antes de escribir esto (ver sesión):
// triggerTouchEvent + executeCallbacks + render() sobre el mismo RenderTask mueve el
// composable de verdad (gesto + spring-back), no es un render estático reetiquetado.
//
// Un solo preview por proceso, sin controles de scrub/pausa — ver README de este
// directorio para el alcance de v1.
import com.android.ide.common.rendering.api.RenderSession;
import com.android.resources.ResourceFolderType;
import com.android.tools.configurations.Configuration;
import com.android.tools.preview.ConfigurablePreviewElement;
import com.android.tools.preview.PreviewConfigurationKt;
import com.android.tools.render.RenderEnvironmentBootstrapper;
import com.android.tools.render.Renderer;
import com.android.tools.render.common.ScreenshotPreviewElement;
import com.android.tools.render.compose.ComposeScreenshot;
import com.android.tools.rendering.RenderLogger;
import com.android.tools.rendering.RenderResult;
import com.android.tools.rendering.RenderService;
import com.android.tools.rendering.RenderTask;
import com.android.tools.rendering.parsers.RenderXmlFileSnapshot;
import com.google.gson.Gson;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.intellij.openapi.util.CheckedDisposable;
import com.intellij.openapi.util.Disposer;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import kotlin.jvm.functions.Function1;

import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.FileReader;
import java.io.IOException;
import java.lang.reflect.Field;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import javax.imageio.ImageIO;

public class InteractiveServer {
    // Todas las llamadas al RenderTask (tick de idle + touch) pasan por este único
    // executor: no porque RenderTask lo necesite (ya serializa internamente — probado
    // en el spike), sino para no encolarle renders más rápido de lo que puede sacarlos.
    static final ExecutorService renderExecutor = Executors.newSingleThreadExecutor();
    static RenderTask task;
    static CheckedDisposable disposable;
    static Renderer renderer;
    static volatile byte[] currentFramePng;
    static long clockNanos = 1_000_000L;
    // Tamaño real del render (antes de downscale) — el JS necesita esto para mapear
    // coordenadas de la imagen mostrada (achicada) al espacio real que usa
    // triggerTouchEvent; img.naturalWidth/Height ya no sirve porque apunta al PNG chico.
    static volatile int origWidth;
    static volatile int origHeight;

    public static void main(String[] args) throws Exception {
        JsonObject cfg = new Gson().fromJson(new FileReader(args[0]), JsonObject.class);

        String namespace = cfg.get("namespace").getAsString();
        String resourceApkPath = cfg.get("resourceApkPath").getAsString();
        String layoutlibPath = cfg.get("layoutlibPath").getAsString();
        List<String> classPath = toStringList(cfg.getAsJsonArray("classPath"));
        List<String> projectClassPath = toStringList(cfg.getAsJsonArray("projectClassPath"));
        String methodFQN = cfg.get("methodFQN").getAsString();
        String previewId = cfg.get("previewId").getAsString();
        int requestedPort = cfg.has("port") ? cfg.get("port").getAsInt() : 0;

        Map<String, String> previewParams = new LinkedHashMap<>();
        if (cfg.has("previewParams")) {
            for (Map.Entry<String, JsonElement> e : cfg.getAsJsonObject("previewParams").entrySet()) {
                previewParams.put(e.getKey(), e.getValue().getAsString());
            }
        }

        RenderEnvironmentBootstrapper bootstrapper = new RenderEnvironmentBootstrapper(
                null, resourceApkPath, namespace, classPath, projectClassPath, layoutlibPath,
                Collections.emptyList(), Collections.emptyList());
        renderer = bootstrapper.bootstrap();

        ComposeScreenshot screenshot = new ComposeScreenshot(
                methodFQN, Collections.emptyList(), previewParams, previewId, null);
        ScreenshotPreviewElement previewElement = screenshot.toPreviewElement(renderer.getModule());
        String xmlLayout = (String) previewElement.resolveXmlLayouts().iterator().next();

        Field baseConfigField = Renderer.class.getDeclaredField("baseConfiguration");
        baseConfigField.setAccessible(true);
        Configuration baseConfiguration = (Configuration) baseConfigField.get(renderer);
        Configuration configuration = baseConfiguration.clone();
        // applyTo tiene un overload $default generado por Kotlin que javac no puede
        // resolver desde Java; se llama el real pasando explícitamente un no-op. Tipo
        // raw a propósito (como en el spike): el generic real (Function1<? super
        // Configuration, Device>) no es expresable limpio desde Java aquí.
        Function1 noDeviceProvider = new Function1() {
            public Object invoke(Object p0) { return null; }
        };
        PreviewConfigurationKt.applyTo((ConfigurablePreviewElement) previewElement, configuration, noDeviceProvider);

        RenderService renderService = new RenderService(b -> {});
        RenderLogger logger = new RenderLogger();
        disposable = Disposer.newCheckedDisposable();

        task = (RenderTask) renderService.taskBuilder(renderer.getModule(), configuration, logger)
                .build(disposable).get(60, TimeUnit.SECONDS);
        if (task == null) {
            System.err.println("RenderTask build failed: " + logger.getMessages());
            System.exit(1);
        }
        task.setXmlFile(new RenderXmlFileSnapshot(renderer.getProject(), "layout.xml", ResourceFolderType.LAYOUT, xmlLayout));

        renderNow();

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", requestedPort), 0);
        server.createContext("/", InteractiveServer::handleIndex);
        server.createContext("/frame.png", InteractiveServer::handleFrame);
        server.createContext("/touch", InteractiveServer::handleTouch);
        server.createContext("/stop", exchange -> {
            sendEmpty(exchange, 200);
            new Thread(() -> { server.stop(0); System.exit(0); }).start();
        });
        // Thread propio para el dispatch HTTP: con el default (null => un solo thread
        // interno) un render lento/GC pesado del renderExecutor alcanzaba a bloquear
        // hasta /frame.png (probado: idle-tick a 100ms saturaba la CPU con el server
        // colgado). Nada que ver con el touch — ese responde rápido siempre.
        server.setExecutor(Executors.newFixedThreadPool(2));
        server.start();

        // La línea "PORT <n>" es el contrato con compose-preview-interactive.lua: lee
        // stdout hasta verla para saber a qué puerto abrir el navegador.
        System.out.println("PORT " + server.getAddress().getPort());
        System.out.flush();

        Runtime.getRuntime().addShutdownHook(new Thread(InteractiveServer::disposeQuietly));

        // ponytail: re-renderiza solo en respuesta a un touch, no hay loop de
        // animación idle. Se probó un loop a 100ms (chevron/animate*AsState sin
        // gesto) y el render de layoutlib resultó demasiado pesado para sostenerlo:
        // saturaba un core y la presión de GC llegaba a colgar el propio server HTTP.
        // Gap conocido de v1: una animación que corre sola sin touch no avanza hasta
        // el próximo touch. Subir esto a un loop sostenible (más lento + solo con
        // cliente conectado) si hace falta.
    }

    static List<String> toStringList(com.google.gson.JsonArray array) {
        List<String> list = new ArrayList<>();
        if (array != null) {
            for (JsonElement e : array) list.add(e.getAsString());
        }
        return list;
    }

    // El device real renderiza a resolución completa de teléfono (1080x2400 medido) pero
    // el <img> de la página lo muestra achicado al viewport igual — medido: encodear ese
    // PNG a tamaño completo costaba 80-130ms, >85% del tiempo de cada touch (render() en
    // sí tarda 3-4ms). Bajar a este ancho antes de encodear corta el costo ~ (TARGET/orig)².
    static final int TARGET_WIDTH = 480;

    static void renderNow() throws Exception {
        long t0 = System.nanoTime();
        RenderResult result = (RenderResult) task.render().get(30, TimeUnit.SECONDS);
        long t1 = System.nanoTime();
        Object recyclable = result.getRenderedImage();
        BufferedImage image = (BufferedImage) recyclable.getClass().getMethod("getCopy").invoke(recyclable);
        origWidth = image.getWidth();
        origHeight = image.getHeight();
        long t2 = System.nanoTime();
        BufferedImage scaled = downscale(image, TARGET_WIDTH);
        long t3 = System.nanoTime();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(scaled, "png", out);
        currentFramePng = out.toByteArray();
        long t4 = System.nanoTime();
        System.err.printf("PERF render=%.1fms copy=%.1fms scale=%.1fms encode=%.1fms bytes=%d%n",
                (t1 - t0) / 1e6, (t2 - t1) / 1e6, (t3 - t2) / 1e6, (t4 - t3) / 1e6, currentFramePng.length);
    }

    static BufferedImage downscale(BufferedImage src, int targetWidth) {
        if (src.getWidth() <= targetWidth) return src;
        int targetHeight = Math.round(src.getHeight() * (targetWidth / (float) src.getWidth()));
        BufferedImage out = new BufferedImage(targetWidth, targetHeight, BufferedImage.TYPE_INT_ARGB);
        java.awt.Graphics2D g = out.createGraphics();
        g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION,
                java.awt.RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        g.drawImage(src, 0, 0, targetWidth, targetHeight, null);
        g.dispose();
        return out;
    }

    static void disposeQuietly() {
        try {
            if (task != null) task.releaseRender();
            if (disposable != null) Disposer.dispose(disposable);
            if (renderer != null) renderer.close();
        } catch (Throwable ignored) {
        }
    }

    // Sin poll de intervalo: cada /touch ya devuelve el frame nuevo en la misma
    // respuesta (ver handleTouch), así que no hace falta un segundo GET a /frame.png
    // para verlo. coords() escala contra ORIG_W/ORIG_H (tamaño real del render, inyectado
    // acá) en vez de img.naturalWidth/Height, que ahora es el PNG achicado (ver
    // TARGET_WIDTH) y daría coordenadas equivocadas a triggerTouchEvent. inFlight/pending
    // evita encolar un POST por cada mousemove: mientras uno está en vuelo, solo se
    // guarda la última posición y se manda apenas el anterior vuelve.
    static String indexHtml() {
        return "<!doctype html><html><head><meta charset=\"utf-8\">" +
                "<title>Compose Preview (interactive)</title>" +
                "<style>body{margin:0;background:#1e1e1e;display:flex;justify-content:center;align-items:center;" +
                "height:100vh}img{max-width:100vw;max-height:100vh;cursor:pointer;touch-action:none}</style></head>" +
                "<body><img id=\"frame\" src=\"/frame.png\"><script>" +
                "const img=document.getElementById('frame');" +
                "const ORIG_W=" + origWidth + ",ORIG_H=" + origHeight + ";" +
                "let inFlight=false,pending=null;" +
                "function coords(ev){const r=img.getBoundingClientRect();" +
                "const sx=ORIG_W/r.width,sy=ORIG_H/r.height;" +
                "const cx=(ev.touches?ev.touches[0].clientX:ev.clientX)-r.left;" +
                "const cy=(ev.touches?ev.touches[0].clientY:ev.clientY)-r.top;" +
                "return {x:Math.round(cx*sx),y:Math.round(cy*sy)};}" +
                "function flush(){if(!pending){inFlight=false;return;}" +
                "const req=pending;pending=null;" +
                "fetch('/touch',{method:'POST',body:JSON.stringify(req)})" +
                ".then(r=>r.blob()).then(b=>{img.src=URL.createObjectURL(b);flush();})" +
                ".catch(()=>{inFlight=false;});}" +
                "function send(type,ev){const c=coords(ev);pending={type:type,x:c.x,y:c.y};" +
                "if(!inFlight){inFlight=true;flush();}" +
                "ev.preventDefault();}" +
                "img.addEventListener('mousedown',e=>send('PRESS',e));" +
                "img.addEventListener('mousemove',e=>{if(e.buttons===1)send('DRAG',e);});" +
                "img.addEventListener('mouseup',e=>send('RELEASE',e));" +
                "img.addEventListener('touchstart',e=>send('PRESS',e));" +
                "img.addEventListener('touchmove',e=>send('DRAG',e));" +
                "img.addEventListener('touchend',e=>send('RELEASE',e));" +
                "</script></body></html>";
    }

    static void handleIndex(HttpExchange exchange) throws IOException {
        byte[] html = indexHtml().getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "text/html; charset=utf-8");
        exchange.sendResponseHeaders(200, html.length);
        exchange.getResponseBody().write(html);
        exchange.close();
    }

    static void handleFrame(HttpExchange exchange) throws IOException {
        byte[] png = currentFramePng;
        exchange.getResponseHeaders().add("Content-Type", "image/png");
        exchange.getResponseHeaders().add("Cache-Control", "no-store");
        exchange.sendResponseHeaders(200, png.length);
        exchange.getResponseBody().write(png);
        exchange.close();
    }

    static void handleTouch(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            sendEmpty(exchange, 405);
            return;
        }
        String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        JsonObject json = new Gson().fromJson(body, JsonObject.class);
        String type = json.get("type").getAsString();
        int x = json.get("x").getAsInt();
        int y = json.get("y").getAsInt();

        long handlerT0 = System.nanoTime();
        try {
            renderExecutor.submit(() -> {
                try {
                    long touchT0 = System.nanoTime();
                    clockNanos += 16_000_000L;
                    task.triggerTouchEvent(RenderSession.TouchEventType.valueOf(type), x, y, clockNanos)
                            .get(10, TimeUnit.SECONDS);
                    long touchT1 = System.nanoTime();
                    clockNanos += 16_000_000L;
                    task.executeCallbacks(clockNanos).get(10, TimeUnit.SECONDS);
                    long cbT1 = System.nanoTime();
                    System.err.printf("PERF triggerTouch=%.1fms executeCallbacks=%.1fms%n",
                            (touchT1 - touchT0) / 1e6, (cbT1 - touchT1) / 1e6);
                    renderNow();
                } catch (Exception e) {
                    System.err.println("touch error: " + e);
                }
            }).get(15, TimeUnit.SECONDS);
        } catch (Exception e) {
            System.err.println("touch dispatch error: " + e);
        }
        System.err.printf("PERF /touch handler total=%.1fms%n", (System.nanoTime() - handlerT0) / 1e6);
        // Devuelve el frame ya actualizado en la misma respuesta — el cliente no necesita
        // un segundo round-trip a /frame.png para verlo (ver indexHtml()).
        byte[] png = currentFramePng;
        exchange.getResponseHeaders().add("Content-Type", "image/png");
        exchange.sendResponseHeaders(200, png.length);
        exchange.getResponseBody().write(png);
        exchange.close();
    }

    static void sendEmpty(HttpExchange exchange, int code) throws IOException {
        exchange.sendResponseHeaders(code, -1);
        exchange.close();
    }
}
