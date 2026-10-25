// Preview interactivo de un @Preview de Compose — versión "igual que Android Studio":
// mismo RenderTask (com.android.tools.rendering) que InteractiveServer, pero sin HTTP
// ni PNG ni navegador de por medio. Studio pinta el BufferedImage directo en un Swing
// JComponent, en el mismo proceso — esto hace exactamente eso. Medido: InteractiveServer
// (HTTP+PNG+browser) bajó de ~92-96ms a ~18-20ms por touch optimizando el encode; esta
// versión no encodea nada, así que el costo por touch es básicamente el render() solo
// (~3-4ms medido en caliente) + repaint de Swing.
//
// Bootstrap del RenderTask duplicado desde InteractiveServer a propósito (no factorizado
// en un helper compartido): es la misma ~40 líneas ya probada, y tocar InteractiveServer
// para extraerla arriesgaba romper algo ya verificado por cambiar algo que no hacía falta
// cambiar.
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
import kotlin.jvm.functions.Function1;

import javax.swing.JFrame;
import javax.swing.JPanel;
import javax.swing.SwingUtilities;
import java.awt.Dimension;
import java.awt.Graphics;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.awt.image.BufferedImage;
import java.io.FileReader;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class InteractiveWindow {
    // Mismo motivo que en InteractiveServer: no por thread-safety de RenderTask (ya
    // serializa internamente), sino para no encolarle renders más rápido de lo que
    // puede sacarlos.
    static final ExecutorService renderExecutor = Executors.newSingleThreadExecutor();
    static RenderTask task;
    static CheckedDisposable disposable;
    static Renderer renderer;
    static long clockNanos = 1_000_000L;
    static volatile BufferedImage currentFrame;
    static Preview panel;
    // La imagen se renderiza a resolución real de dispositivo (p.ej. 1080x2400 puntos) —
    // más alta que la pantalla disponible. Sin esto, frame.pack() pide una ventana más
    // grande que la pantalla y macOS la recorta/reacomoda hasta algo que ya no se ve
    // como teléfono (el aspect ratio real SÍ es el correcto, el bug era no escalar la
    // ventana a la pantalla). Las coordenadas del mouse llegan en espacio de pantalla
    // (post-escala) y hay que volver a dividir por este factor antes de triggerTouchEvent.
    static double displayScale = 1.0;

    // Coalescing: con el mouse real no llegan tantos mousedragged como mousemove de un
    // navegador, pero el patrón es el mismo que en InteractiveServer — solo se guarda la
    // última posición pendiente; si ya hay un render en vuelo, las intermedias se pisan.
    static volatile boolean inFlight = false;
    static volatile Object[] pending = null; // {RenderSession.TouchEventType, x, y}

    public static void main(String[] args) throws Exception {
        JsonObject cfg = new Gson().fromJson(new FileReader(args[0]), JsonObject.class);

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

        Dimension screen = java.awt.Toolkit.getDefaultToolkit().getScreenSize();
        double scaleH = (screen.height * 0.85) / currentFrame.getHeight();
        double scaleW = (screen.width * 0.85) / currentFrame.getWidth();
        displayScale = Math.min(1.0, Math.min(scaleH, scaleW));
        System.err.printf("PERF frame=%dx%d screen=%dx%d displayScale=%.3f%n",
                currentFrame.getWidth(), currentFrame.getHeight(), screen.width, screen.height, displayScale);

        Runtime.getRuntime().addShutdownHook(new Thread(InteractiveWindow::disposeQuietly));

        SwingUtilities.invokeLater(InteractiveWindow::openWindow);
    }

    static List<String> toStringList(com.google.gson.JsonArray array) {
        List<String> list = new ArrayList<>();
        if (array != null) {
            for (JsonElement e : array) list.add(e.getAsString());
        }
        return list;
    }

    static void renderNow() throws Exception {
        long t0 = System.nanoTime();
        RenderResult result = (RenderResult) task.render().get(30, TimeUnit.SECONDS);
        long t1 = System.nanoTime();
        Object recyclable = result.getRenderedImage();
        currentFrame = (BufferedImage) recyclable.getClass().getMethod("getCopy").invoke(recyclable);
        System.err.printf("PERF render=%.1fms (sin encode: ventana nativa pinta el BufferedImage directo)%n",
                (t1 - t0) / 1e6);
    }

    static class Preview extends JPanel {
        Preview() {
            setPreferredSize(new Dimension(displayWidth(), displayHeight()));
        }

        @Override
        protected void paintComponent(Graphics g) {
            super.paintComponent(g);
            BufferedImage frame = currentFrame;
            if (frame != null) {
                g.drawImage(frame, 0, 0, displayWidth(), displayHeight(), null);
            }
        }
    }

    static int displayWidth() { return Math.round((float) (currentFrame.getWidth() * displayScale)); }
    static int displayHeight() { return Math.round((float) (currentFrame.getHeight() * displayScale)); }

    static void openWindow() {
        panel = new Preview();
        JFrame frame = new JFrame("Compose Preview (interactive)");
        frame.setDefaultCloseOperation(JFrame.DO_NOTHING_ON_CLOSE);
        frame.addWindowListener(new WindowAdapter() {
            @Override
            public void windowClosing(WindowEvent e) {
                disposeQuietly();
                System.exit(0);
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
        frame.pack();
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
    }

    // El panel muestra el frame escalado a la pantalla (displayScale) — el MouseEvent
    // llega en ESE espacio, hay que volver a escalarlo al tamaño nativo del render antes
    // de triggerTouchEvent (mismo tipo de bug que ya se corrigió una vez en InteractiveServer
    // para su downscale de PNG).
    static void sendTouch(RenderSession.TouchEventType type, MouseEvent e) {
        int x = Math.round((float) (e.getX() / displayScale));
        int y = Math.round((float) (e.getY() / displayScale));
        synchronized (InteractiveWindow.class) {
            pending = new Object[] { type, x, y };
            if (inFlight) return;
            inFlight = true;
        }
        renderExecutor.submit(InteractiveWindow::drainPending);
    }

    static void drainPending() {
        Object[] next;
        synchronized (InteractiveWindow.class) {
            next = pending;
            pending = null;
        }
        if (next == null) {
            synchronized (InteractiveWindow.class) { inFlight = false; }
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
            SwingUtilities.invokeLater(() -> panel.repaint());
        } catch (Throwable ex) {
            // Throwable, no Exception: ver InteractiveDaemon.drainPending — mismo bug,
            // mismo fix (un StackOverflowError por la recursión de abajo escapaba de
            // catch(Exception) y dejaba inFlight en true para siempre).
            System.err.println("touch error: " + ex);
        }
        // Resubmit, no llamada directa: evita que el stack nativo crezca sin tope durante
        // un drag largo (ver InteractiveDaemon.drainPending).
        renderExecutor.submit(InteractiveWindow::drainPending);
    }

    static void disposeQuietly() {
        try {
            if (task != null) task.releaseRender();
            if (disposable != null) Disposer.dispose(disposable);
            if (renderer != null) renderer.close();
        } catch (Throwable ignored) {
        }
    }
}
