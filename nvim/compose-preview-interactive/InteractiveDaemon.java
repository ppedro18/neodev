// Preview interactivo con daemon: igual que InteractiveWindow (RenderTask vivo,
// ventana Swing nativa, sin HTTP/PNG para los frames), pero el proceso Java sobrevive
// entre previews — <leader>ci sucesivos reusan el mismo Renderer/Bridge en vez de
// pagar el bootstrap de nuevo. Medido (ver README): RenderEnvironmentBootstrapper.
// bootstrap() + primer render() cuesta ~1.7-2.0s, igual para cualquier componente;
// ese costo es por-JVM (classloading + Bridge.init de layoutlib), no por-componente.
// InteractiveWindow sigue existiendo tal cual (vía de un solo uso, por si hace falta);
// este archivo es el que usa <leader>ci.
//
// Control por HTTP en localhost (solo control — los frames se pintan directo en el
// JPanel, nunca viajan por la red, mismo motivo que InteractiveWindow): GET /ping,
// POST /open (mismo JSON de config que InteractiveWindow tomaba por archivo), POST
// /stop. El puerto se escribe en ~/.cache/nvim/compose-preview/interactive-daemon.port
// (mismo cache dir que ya usa compose-preview.nvim) para que compose.lua lo encuentre
// entre invocaciones y entre reinicios de nvim.
//
// Decisión de producto: cerrar la ventana (la X) solo la oculta, no mata el daemon —
// si matara el proceso, el próximo <leader>ci volvería a pagar el cold start, que es
// exactamente lo que este archivo existe para evitar. :ComposePreviewInteractiveStop
// (POST /stop) es lo único que de verdad termina el proceso. El daemon tampoco se mata
// al cerrar nvim (VimLeavePre ya no lo toca) — sobrevive reinicios de nvim a propósito.
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

import javax.swing.JFrame;
import javax.swing.JPanel;
import javax.swing.SwingUtilities;
import java.awt.Dimension;
import java.awt.Graphics;
import java.awt.Toolkit;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.awt.image.BufferedImage;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public class InteractiveDaemon {
    static final ExecutorService renderExecutor = Executors.newSingleThreadExecutor();
    static RenderTask task;
    static CheckedDisposable disposable;
    static Renderer renderer;
    static long clockNanos = 1_000_000L;
    static volatile BufferedImage currentFrame;
    static double displayScale = 1.0;
    static JFrame frame;
    static Preview panel;

    // Identifica el "proyecto" ya bootstrapeado — si el próximo /open pide exactamente
    // lo mismo (mismo módulo Gradle/variant), nos salteamos RenderEnvironmentBootstrapper
    // entero y solo construimos un RenderTask nuevo contra el Renderer ya vivo.
    static String currentNamespace, currentResourceApkPath, currentLayoutlibPath;
    static List<String> currentClassPath, currentProjectClassPath;

    static volatile boolean inFlight = false;
    static volatile Object[] pendingTouch = null; // {RenderSession.TouchEventType, x, y}

    // Fuera de un touch, nada avanzaba clockNanos — un click manda PRESS+RELEASE en un
    // puñado de ms reales, así que cualquier animación por tiempo (ripple, spring,
    // infiniteRepeatable como el shimmer de MGSwipeableButton) quedaba congelada a mitad
    // de camino apenas soltabas el mouse, en cualquier componente con esa clase de
    // animación. Este ticker sigue pisando el reloj a ~60fps mientras la ventana esté
    // visible, para que esas animaciones terminen de jugar solas (ver README: "sin
    // animación idle" estaba anotado como feature separada, no faltaba por descuido).
    static final ScheduledExecutorService idleTicker = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "idle-ticker");
        t.setDaemon(true);
        return t;
    });
    static final long TICK_MS = 16;
    static volatile boolean ticking = false;

    public static void main(String[] args) throws Exception {
        int requestedPort = args.length > 0 ? Integer.parseInt(args[0]) : 0;

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", requestedPort), 0);
        server.createContext("/ping", ex -> sendText(ex, 200, "ok"));
        server.createContext("/open", InteractiveDaemon::handleOpen);
        server.createContext("/stop", ex -> {
            sendText(ex, 200, "ok");
            new Thread(() -> { stopTicking(); server.stop(0); disposeAll(); System.exit(0); }).start();
        });
        // Mismo motivo que InteractiveServer: un render lento no puede colgar /ping.
        server.setExecutor(Executors.newFixedThreadPool(2));
        server.start();

        int port = server.getAddress().getPort();
        Path portFile = portFilePath();
        Files.createDirectories(portFile.getParent());
        Files.writeString(portFile, String.valueOf(port));

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try { Files.deleteIfExists(portFile); } catch (Exception ignored) {}
            disposeAll();
        }));

        // Contrato con compose.lua: lee stdout hasta esta línea para saber a qué puerto
        // mandar el primer /open (mismo patrón que ya usaba InteractiveServer).
        System.out.println("PORT " + port);
        System.out.flush();
    }

    static Path portFilePath() {
        return Path.of(System.getProperty("user.home"), ".cache", "nvim", "compose-preview", "interactive-daemon.port");
    }

    static void sendText(HttpExchange exchange, int code, String body) throws java.io.IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(code, bytes.length);
        exchange.getResponseBody().write(bytes);
        exchange.close();
    }

    static void handleOpen(HttpExchange exchange) throws java.io.IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            sendText(exchange, 405, "method not allowed");
            return;
        }
        String body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        try {
            renderExecutor.submit(() -> openPreview(body)).get(60, TimeUnit.SECONDS);
            sendText(exchange, 200, "ok");
        } catch (Exception e) {
            System.err.println("open error: " + e);
            sendText(exchange, 500, "error: " + e);
        }
    }

    static List<String> toStringList(com.google.gson.JsonArray array) {
        List<String> list = new ArrayList<>();
        if (array != null) {
            for (JsonElement e : array) list.add(e.getAsString());
        }
        return list;
    }

    static void openPreview(String body) {
        long t0 = System.nanoTime();
        try {
            JsonObject cfg = new Gson().fromJson(body, JsonObject.class);
            String namespace = cfg.get("namespace").getAsString();
            String resourceApkPath = cfg.get("resourceApkPath").getAsString();
            String layoutlibPath = cfg.get("layoutlibPath").getAsString();
            List<String> classPath = toStringList(cfg.getAsJsonArray("classPath"));
            List<String> projectClassPath = toStringList(cfg.getAsJsonArray("projectClassPath"));
            String methodFQN = cfg.get("methodFQN").getAsString();
            String previewId = cfg.get("previewId").getAsString();

            Map<String, String> previewParams = new LinkedHashMap<>();
            if (cfg.has("previewParams")) {
                for (Map.Entry<String, JsonElement> e : cfg.getAsJsonObject("previewParams").entrySet()) {
                    previewParams.put(e.getKey(), e.getValue().getAsString());
                }
            }

            boolean sameProject = renderer != null
                    && namespace.equals(currentNamespace)
                    && resourceApkPath.equals(currentResourceApkPath)
                    && layoutlibPath.equals(currentLayoutlibPath)
                    && classPath.equals(currentClassPath)
                    && projectClassPath.equals(currentProjectClassPath);

            disposeTaskOnly();
            if (!sameProject) {
                disposeRendererOnly();
                RenderEnvironmentBootstrapper bootstrapper = new RenderEnvironmentBootstrapper(
                        null, resourceApkPath, namespace, classPath, projectClassPath, layoutlibPath,
                        Collections.emptyList(), Collections.emptyList());
                renderer = bootstrapper.bootstrap();
                currentNamespace = namespace;
                currentResourceApkPath = resourceApkPath;
                currentLayoutlibPath = layoutlibPath;
                currentClassPath = classPath;
                currentProjectClassPath = projectClassPath;
            }

            ComposeScreenshot screenshot = new ComposeScreenshot(
                    methodFQN, Collections.emptyList(), previewParams, previewId, null);
            ScreenshotPreviewElement previewElement = screenshot.toPreviewElement(renderer.getModule());
            String xmlLayout = (String) previewElement.resolveXmlLayouts().iterator().next();

            Field baseConfigField = Renderer.class.getDeclaredField("baseConfiguration");
            baseConfigField.setAccessible(true);
            Configuration baseConfiguration = (Configuration) baseConfigField.get(renderer);
            Configuration configuration = baseConfiguration.clone();
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
                return;
            }
            task.setXmlFile(new RenderXmlFileSnapshot(renderer.getProject(), "layout.xml", ResourceFolderType.LAYOUT, xmlLayout));

            renderNow();

            long t1 = System.nanoTime();
            System.err.printf("PERF open reuseBootstrap=%b total=%.1fms%n", sameProject, (t1 - t0) / 1e6);

            SwingUtilities.invokeAndWait(InteractiveDaemon::showOrUpdateWindow);
            startTicking();
        } catch (Exception e) {
            System.err.println("openPreview error: " + e);
        }
    }

    static void renderNow() throws Exception {
        long t0 = System.nanoTime();
        RenderResult result = (RenderResult) task.render().get(30, TimeUnit.SECONDS);
        long t1 = System.nanoTime();
        Object recyclable = result.getRenderedImage();
        currentFrame = (BufferedImage) recyclable.getClass().getMethod("getCopy").invoke(recyclable);
        System.err.printf("PERF render=%.1fms%n", (t1 - t0) / 1e6);
    }

    static class Preview extends JPanel {
        Preview() {
            setPreferredSize(new Dimension(displayWidth(), displayHeight()));
        }

        @Override
        protected void paintComponent(Graphics g) {
            super.paintComponent(g);
            BufferedImage f = currentFrame;
            if (f != null) {
                g.drawImage(f, 0, 0, displayWidth(), displayHeight(), null);
            }
        }
    }

    static int displayWidth() { return Math.round((float) (currentFrame.getWidth() * displayScale)); }
    static int displayHeight() { return Math.round((float) (currentFrame.getHeight() * displayScale)); }

    // Llamado en el EDT (invokeAndWait desde openPreview, o invokeLater desde
    // drainPending). Crea la ventana una sola vez; aberturas siguientes solo
    // actualizan tamaño/imagen y la traen al frente — mismo patrón que Android
    // Studio reusando su propio panel de preview entre archivos.
    static void showOrUpdateWindow() {
        Dimension screen = Toolkit.getDefaultToolkit().getScreenSize();
        double scaleH = (screen.height * 0.85) / currentFrame.getHeight();
        double scaleW = (screen.width * 0.85) / currentFrame.getWidth();
        displayScale = Math.min(1.0, Math.min(scaleH, scaleW));

        if (frame == null) {
            panel = new Preview();
            frame = new JFrame("Compose Preview (interactive)");
            frame.setDefaultCloseOperation(JFrame.DO_NOTHING_ON_CLOSE);
            frame.addWindowListener(new WindowAdapter() {
                @Override
                public void windowClosing(WindowEvent e) {
                    frame.setVisible(false); // ver nota de arriba: no mata el daemon
                    stopTicking(); // nadie la está mirando; se reanuda en el próximo /open
                }
            });
            MouseAdapter mouse = new MouseAdapter() {
                @Override public void mousePressed(MouseEvent e) { sendTouch(RenderSession.TouchEventType.PRESS, e); }
                @Override public void mouseDragged(MouseEvent e) { sendTouch(RenderSession.TouchEventType.DRAG, e); }
                @Override public void mouseReleased(MouseEvent e) { sendTouch(RenderSession.TouchEventType.RELEASE, e); }
            };
            panel.addMouseListener(mouse);
            panel.addMouseMotionListener(mouse);
            frame.setContentPane(panel);
        }
        panel.setPreferredSize(new Dimension(displayWidth(), displayHeight()));
        frame.pack();
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
        frame.toFront();
        panel.repaint();
    }

    static void sendTouch(RenderSession.TouchEventType type, MouseEvent e) {
        int x = Math.round((float) (e.getX() / displayScale));
        int y = Math.round((float) (e.getY() / displayScale));
        synchronized (InteractiveDaemon.class) {
            pendingTouch = new Object[] { type, x, y };
            if (inFlight) return;
            inFlight = true;
        }
        renderExecutor.submit(InteractiveDaemon::drainPending);
    }

    static void drainPending() {
        Object[] next;
        synchronized (InteractiveDaemon.class) {
            next = pendingTouch;
            pendingTouch = null;
        }
        if (next == null) {
            synchronized (InteractiveDaemon.class) { inFlight = false; }
            return;
        }
        try {
            long t0 = System.nanoTime();
            clockNanos += 16_000_000L;
            task.triggerTouchEvent((RenderSession.TouchEventType) next[0], (int) next[1], (int) next[2], clockNanos)
                    .get(10, TimeUnit.SECONDS);
            clockNanos += 16_000_000L;
            task.executeCallbacks(clockNanos).get(10, TimeUnit.SECONDS);
            renderNow();
            long t1 = System.nanoTime();
            System.err.printf("PERF touch+render total=%.1fms%n", (t1 - t0) / 1e6);
            SwingUtilities.invokeLater(() -> { if (panel != null) panel.repaint(); });
        } catch (Throwable ex) {
            // Throwable, no Exception: un StackOverflowError (ver abajo) es un Error y
            // escapaba de un catch(Exception), dejando inFlight en true para siempre —
            // el preview no volvía a reaccionar a ningún touch.
            System.err.println("touch error: " + ex);
        }
        // Resubmit, no llamada directa: un drag largo manda touches más rápido de lo que
        // renderiza, y la JVM no hace tail-call elimination — la recursión directa hacía
        // crecer el stack nativo sin tope hasta reventar en StackOverflowError.
        renderExecutor.submit(InteractiveDaemon::drainPending);
    }

    static void startTicking() {
        if (ticking) return;
        ticking = true;
        scheduleNextTick();
    }

    static void stopTicking() {
        ticking = false;
    }

    static void scheduleNextTick() {
        if (!ticking) return;
        idleTicker.schedule(() -> renderExecutor.submit(InteractiveDaemon::tickFrame), TICK_MS, TimeUnit.MILLISECONDS);
    }

    // Mismo renderExecutor que drainPending: un solo hilo, así que un tick nunca corre a
    // la vez que un touch — se intercalan en orden de llegada, sin carrera sobre
    // task/clockNanos/currentFrame.
    static void tickFrame() {
        if (!ticking || task == null) return;
        try {
            clockNanos += TICK_MS * 1_000_000L;
            task.executeCallbacks(clockNanos).get(10, TimeUnit.SECONDS);
            renderNow();
            SwingUtilities.invokeLater(() -> { if (panel != null) panel.repaint(); });
        } catch (Throwable ex) {
            System.err.println("tick error: " + ex);
        } finally {
            scheduleNextTick();
        }
    }

    static void disposeTaskOnly() {
        try { if (task != null) task.releaseRender(); } catch (Throwable ignored) {}
        try { if (disposable != null) Disposer.dispose(disposable); } catch (Throwable ignored) {}
        task = null;
        disposable = null;
    }

    static void disposeRendererOnly() {
        try { if (renderer != null) renderer.close(); } catch (Throwable ignored) {}
        renderer = null;
    }

    static void disposeAll() {
        disposeTaskOnly();
        disposeRendererOnly();
    }
}
