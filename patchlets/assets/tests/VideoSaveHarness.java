package threadsmod.video;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.CookieHandler;
import java.net.CookieManager;
import java.net.URL;
import java.net.URLConnection;
import java.net.URLStreamHandler;
import java.net.URLStreamHandlerFactory;
import java.security.Principal;
import java.security.cert.Certificate;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.ssl.HttpsURLConnection;

/** Offline executable canonical URL, bounded MP4 transport and document-cleanup proof. */
public final class VideoSaveHarness {
    private static final String URL_TEXT = "https://video.cdninstagram.com/video.mp4?token=bounded";
    private static final Map<String, Response> RESPONSES = new HashMap<String, Response>();
    private static int checks;
    private static int requests;

    private interface Test { void run() throws Exception; }

    private static final class Response {
        byte[] body;
        int status = 200;
        long declared;
        String type = "video/mp4";
        String encoding;
        String location;
        Response(byte[] body) { this.body = body; declared = body.length; }
    }

    private static final class FakeConnection extends HttpsURLConnection {
        private final Response response;
        FakeConnection(URL url, Response response) { super(url); this.response = response; }
        @Override public int getResponseCode() throws IOException {
            requests++;
            check(!getInstanceFollowRedirects(), "automatic redirects disabled");
            check("GET".equals(getRequestMethod()), "GET only");
            check(!getDoOutput(), "no network write body");
            check(!getUseCaches(), "shared response cache disabled");
            check(getConnectTimeout() > 0 && getConnectTimeout() <= 15000, "connect timeout bounded");
            check(getReadTimeout() > 0 && getReadTimeout() <= 15000, "read timeout bounded");
            check("identity".equals(getRequestProperty("Accept-Encoding")), "identity encoding");
            check("video/mp4".equals(getRequestProperty("Accept")), "MP4 request");
            check("ThreadsMod-VideoSave/1".equals(getRequestProperty("User-Agent")), "fixed user agent");
            check(getRequestProperties().size() == 3, "closed credential-free headers");
            return response.status;
        }
        @Override public long getContentLengthLong() { return response.declared; }
        @Override public String getContentType() { return response.type; }
        @Override public String getHeaderField(String name) {
            if ("Location".equals(name)) return response.location;
            if ("Content-Encoding".equals(name)) return response.encoding;
            return null;
        }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(response.body); }
        @Override public void disconnect() {}
        @Override public boolean usingProxy() { return false; }
        @Override public void connect() {}
        @Override public String getCipherSuite() { return "fixture"; }
        @Override public Certificate[] getLocalCertificates() { return null; }
        @Override public Certificate[] getServerCertificates() { return null; }
        @Override public Principal getPeerPrincipal() { return null; }
        @Override public Principal getLocalPrincipal() { return null; }
    }

    private static final class Destination implements VideoTransfer.Destination {
        final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        boolean opened;
        boolean discarded;
        boolean closed;
        boolean failClose;
        boolean failDiscard;
        @Override public void cancel() {}
        @Override public OutputStream open() {
            opened = true;
            return new OutputStream() {
                @Override public void write(int value) { bytes.write(value); }
                @Override public void write(byte[] data, int offset, int length) { bytes.write(data, offset, length); }
                @Override public void close() throws IOException {
                    closed = true;
                    if (failClose) throw new IOException("fixture close rejected");
                }
            };
        }
        @Override public void discard() {
            discarded = true;
            if (failDiscard) throw new IllegalStateException("fixture cleanup refused");
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new AssertionError("supply an empty fixture scratch directory");
        final File scratch = new File(args[0]);
        if (!scratch.isDirectory() || scratch.list().length != 0) throw new AssertionError("scratch must be empty");
        URL.setURLStreamHandlerFactory(new URLStreamHandlerFactory() {
            @Override public URLStreamHandler createURLStreamHandler(String protocol) {
                if (!"https".equals(protocol)) return null;
                return new URLStreamHandler() {
                    @Override protected URLConnection openConnection(URL url) throws IOException {
                        Response response = RESPONSES.get(url.toExternalForm());
                        if (response == null) throw new IOException("fixture endpoint missing");
                        return new FakeConnection(url, response);
                    }
                };
            }
        });
        for (String allowed : new String[] {
                URL_TEXT, "https://cdninstagram.com/video.mp4", "https://fbcdn.net/v.mp4",
                "https://scontent.x.fbcdn.net/v.mp4", "https://VIDEO.CDNINSTAGRAM.COM/v.mp4" }) {
            check(VideoSaveRequest.isAllowed(allowed), "allowed CDN URL");
        }
        for (final String denied : new String[] {
                null, "", "http://video.cdninstagram.com/v.mp4", "https://example.com/v.mp4",
                "https://cdninstagram.com.example.com/v.mp4", "https://evilfbcdn.net/v.mp4",
                "https://cdninstagram.com@evil.com/v.mp4", "https://user:pass@cdninstagram.com/v.mp4",
                "https://cdninstagram.com:443/v.mp4", "https://cdninstagram.com/v.mp4#fragment",
                "https://cdninstagram.com./v.mp4", "https://cdninstagram.com/", "https://cdninstagram.com",
                "https://cdninstagram.com/v\\x.mp4", "https://cdninstagram.com/v.mp4\r\nInjected: x",
                "https://cdninstagram.com/v mp4", "https://127.0.0.1/v.mp4",
                "https://cdninstagram.com/" + repeat('x', 8192) }) {
            check(!VideoSaveRequest.isAllowed(denied), "URL rejected");
        }
        for (final String filename : new String[] {null, "../v.mp4", "/v.mp4", "v.txt", "v.MP4", "a\\b.mp4", repeat('a', 100) + ".mp4"}) {
            reject(new Test() { @Override public void run() { new VideoSaveRequest(URL_TEXT, filename); } });
        }
        check(VideoSaveRequest.redirect(new URL(URL_TEXT), "/next.mp4", 1).toExternalForm()
                .equals("https://video.cdninstagram.com/next.mp4"), "relative redirect validated");
        check(VideoSaveRequest.redirect(new URL(URL_TEXT), "https://scontent.fbcdn.net/next.mp4", 3)
                .getHost().equals("scontent.fbcdn.net"), "third allowlisted redirect valid");
        for (final String denied : new String[] {"http://fbcdn.net/v.mp4", "https://evil.com/v.mp4", "https://user@fbcdn.net/v.mp4", "//evil.com/x"}) {
            reject(new Test() { @Override public void run() throws Exception { VideoSaveRequest.redirect(new URL(URL_TEXT), denied, 1); } });
        }
        reject(new Test() { @Override public void run() throws Exception { VideoSaveRequest.redirect(new URL(URL_TEXT), "/x", 4); } });
        check(VideoTransfer.MAX_BYTES == 268435456L && VideoTransfer.MAX_DURATION_MS == 180000L, "compiled transfer bounds");

        final byte[] mp4 = mp4("isom", true, true);
        File sample = new File(scratch, "sample.mp4");
        write(sample, mp4);
        VideoTransfer.verifyMp4(sample);
        checks++;
        for (byte[] invalid : new byte[][] {
                mp4("avif", true, true), mp4("isom", false, true), mp4("isom", true, false),
                new byte[64], "<html>not a video</html>".getBytes("UTF-8"), truncated(mp4) }) {
            write(sample, invalid);
            final File invalidFile = sample;
            reject(new Test() { @Override public void run() throws Exception { VideoTransfer.verifyMp4(invalidFile); } });
        }
        sample.delete();
        reject(new Test() { @Override public void run() throws Exception {
            VideoTransfer.copyBounded(new ByteArrayInputStream(new byte[9]), new ByteArrayOutputStream(),
                    8L, new VideoTransfer.Cancellation(), future());
        } });
        check(VideoTransfer.copyBounded(new ByteArrayInputStream(new byte[8]), new ByteArrayOutputStream(),
                8L, new VideoTransfer.Cancellation(), future()) == 8L, "exact stream bound accepted");

        Response positive = new Response(mp4);
        RESPONSES.put(URL_TEXT, positive);
        Destination success = new Destination();
        VideoTransfer.save(request(), scratch, success, new VideoTransfer.Cancellation());
        check(success.opened && success.closed && !success.discarded
                && java.util.Arrays.equals(mp4, success.bytes.toByteArray()), "save succeeds after exact provider copy and close");
        empty(scratch);

        Destination closeFailed = new Destination();
        closeFailed.failClose = true;
        closeFailed.failDiscard = true;
        failSave(scratch, closeFailed, new VideoTransfer.Cancellation());
        check(closeFailed.opened && closeFailed.closed, "provider close failure reached");

        for (int kind = 0; kind < 7; kind++) {
            Response invalid = new Response(mp4);
            if (kind == 0) invalid.declared = mp4.length + 1;
            if (kind == 1) invalid.declared = VideoTransfer.MAX_BYTES + 1;
            if (kind == 2) invalid.type = "text/html";
            if (kind == 3) invalid.encoding = "gzip";
            if (kind == 4) invalid.status = 403;
            if (kind == 5) invalid.body = mp4("avif", true, true);
            if (kind == 6) { invalid.status = 302; invalid.location = "https://evil.com/v.mp4"; }
            RESPONSES.put(URL_TEXT, invalid);
            Destination destination = new Destination();
            failSave(scratch, destination, new VideoTransfer.Cancellation());
            check(!destination.opened, "invalid download never opens destination");
        }

        Response redirect = new Response(new byte[0]);
        redirect.status = 302;
        redirect.location = "https://scontent.fbcdn.net/final.mp4";
        RESPONSES.put(URL_TEXT, redirect);
        RESPONSES.put(redirect.location, positive);
        Destination redirected = new Destination();
        VideoTransfer.save(request(), scratch, redirected, new VideoTransfer.Cancellation());
        check(redirected.closed && !redirected.discarded, "allowlisted redirect full save");
        empty(scratch);

        RESPONSES.put(URL_TEXT, positive);
        CookieHandler original = CookieHandler.getDefault();
        int before = requests;
        try {
            CookieHandler.setDefault(new CookieManager());
            Destination denied = new Destination();
            failSave(scratch, denied, new VideoTransfer.Cancellation());
            check(requests == before && !denied.opened, "cookie handler refused before network");
        } finally { CookieHandler.setDefault(original); }
        VideoTransfer.Cancellation cancelled = new VideoTransfer.Cancellation();
        cancelled.cancel();
        Destination cancelledOutput = new Destination();
        failSave(scratch, cancelledOutput, cancelled);
        check(!cancelledOutput.opened && requests == before, "cancelled save never dispatches");

        final CountDownLatch openStarted = new CountDownLatch(1);
        final CountDownLatch cancelDelivered = new CountDownLatch(1);
        final CountDownLatch blockedFinished = new CountDownLatch(1);
        final AtomicReference<Throwable> unexpected = new AtomicReference<Throwable>();
        final VideoTransfer.Cancellation providerCancellation = new VideoTransfer.Cancellation();
        final boolean[] providerState = new boolean[2];
        final VideoTransfer.Destination blockedProvider = new VideoTransfer.Destination() {
            @Override public OutputStream open() throws IOException {
                openStarted.countDown();
                try {
                    if (!cancelDelivered.await(5L, TimeUnit.SECONDS)) {
                        throw new AssertionError("provider-open cancellation hook missing");
                    }
                } catch (InterruptedException interrupted) { throw new IOException("fixture interrupted"); }
                throw new IOException("fixture provider cancelled before output acquired");
            }
            @Override public void cancel() {
                providerState[0] = true;
                cancelDelivered.countDown();
            }
            @Override public void discard() { providerState[1] = true; }
        };
        Thread blocked = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    VideoTransfer.save(request(), scratch, blockedProvider, providerCancellation);
                    unexpected.set(new AssertionError("cancelled provider should not save"));
                } catch (IOException expected) {
                    // Expected cancellation path.
                } catch (Throwable failure) { unexpected.set(failure); }
                finally { blockedFinished.countDown(); }
            }
        }, "FixtureBlockedProvider");
        blocked.setDaemon(true);
        blocked.start();
        check(openStarted.await(5L, TimeUnit.SECONDS), "provider open reached before stream acquisition");
        providerCancellation.abort();
        check(blockedFinished.await(5L, TimeUnit.SECONDS), "provider cancellation unblocks pending open");
        check(unexpected.get() == null && providerState[0] && providerState[1],
                "cancel hook fires before output acquisition and partial document discarded");
        empty(scratch);

        // A failed attempt releases the single-flight owner and a fresh explicit attempt can succeed.
        Destination retried = new Destination();
        File retainedDirectory = new File(scratch, "threadsmod-videos");
        check(retainedDirectory.mkdir(), "feature cache directory created");
        File stale = new File(retainedDirectory, "threadsmod-video-123.part");
        write(stale, new byte[] {1, 2, 3});
        VideoTransfer.save(request(), scratch, retried, new VideoTransfer.Cancellation());
        check(retried.closed && !retried.discarded, "ownership released after failures");
        check(!stale.exists(), "own process-interrupted cache partial reaped");
        empty(scratch);
        System.out.println("Video save fixtures passed: " + checks + " assertions; offline transport only.");
    }

    private static void failSave(File scratch, Destination destination, VideoTransfer.Cancellation cancellation) throws Exception {
        final File directory = scratch;
        final Destination output = destination;
        final VideoTransfer.Cancellation cancel = cancellation;
        reject(new Test() { @Override public void run() throws Exception { VideoTransfer.save(request(), directory, output, cancel); } });
        check(destination.discarded, "failed save deletes selected document best effort");
        empty(scratch);
    }

    private static VideoSaveRequest request() { return new VideoSaveRequest(URL_TEXT, "Threads-video-1.mp4"); }
    private static long future() { return System.nanoTime() + 60000000000L; }
    private static void empty(File directory) { check(directory.list().length == 0, "cache partial cleaned"); }
    private static void check(boolean condition, String label) { if (!condition) throw new AssertionError(label); checks++; }
    private static void reject(Test test) throws Exception {
        try { test.run(); } catch (IllegalArgumentException rejected) { checks++; return; }
        catch (IOException rejected) { checks++; return; }
        throw new AssertionError("fixture should fail closed");
    }
    private static String repeat(char value, int count) { StringBuilder text = new StringBuilder(); for (int i = 0; i < count; i++) text.append(value); return text.toString(); }
    private static void write(File file, byte[] bytes) throws Exception { try (FileOutputStream output = new FileOutputStream(file)) { output.write(bytes); } }
    private static byte[] truncated(byte[] bytes) { return java.util.Arrays.copyOf(bytes, bytes.length - 1); }
    private static byte[] mp4(String brand, boolean movie, boolean media) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        java.io.DataOutputStream output = new java.io.DataOutputStream(bytes);
        output.writeInt(20); output.writeBytes("ftyp"); output.writeBytes(brand); output.writeInt(0); output.writeBytes(brand);
        if (movie) { output.writeInt(16); output.writeBytes("moov"); output.writeInt(8); output.writeBytes("mvhd"); }
        if (media) { output.writeInt(12); output.writeBytes("mdat"); output.writeInt(1); }
        return bytes.toByteArray();
    }
}
