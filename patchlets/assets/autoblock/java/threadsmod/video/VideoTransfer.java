package threadsmod.video;

import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.CookieHandler;
import java.net.URL;
import java.util.Locale;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.ssl.HttpsURLConnection;

/** Same-UID HTTPS transport and bounded cache-first verification. No private Threads seams. */
final class VideoTransfer {
    static final long MAX_BYTES = 268435456L;
    static final long MAX_DURATION_MS = 180000L;
    private static final AtomicBoolean OWNER = new AtomicBoolean();

    interface Destination {
        OutputStream open() throws IOException;
        void cancel();
        void discard();
    }

    static final class Cancellation {
        private final AtomicBoolean cancelled = new AtomicBoolean();
        private HttpsURLConnection connection;
        private Closeable input;
        private Closeable output;
        private Destination destination;

        void cancel() { cancelled.set(true); }

        synchronized void track(HttpsURLConnection connection, Closeable input, Closeable output) {
            this.connection = connection;
            this.input = input;
            this.output = output;
        }

        synchronized void trackDestination(Destination destination) {
            this.destination = destination;
        }

        void abort() {
            cancel();
            HttpsURLConnection activeConnection;
            Closeable activeInput;
            Closeable activeOutput;
            Destination activeDestination;
            synchronized (this) {
                activeConnection = connection;
                activeInput = input;
                activeOutput = output;
                activeDestination = destination;
            }
            if (activeDestination != null) {
                try { activeDestination.cancel(); } catch (RuntimeException ignored) {}
            }
            if (activeConnection != null) {
                try { activeConnection.disconnect(); } catch (RuntimeException ignored) {}
            }
            closeQuietly(activeInput);
            closeQuietly(activeOutput);
        }

        void check(long deadline) throws IOException {
            if (cancelled.get() || Thread.currentThread().isInterrupted()
                    || System.nanoTime() - deadline >= 0L) {
                throw new IOException("video save interrupted");
            }
        }
    }

    private VideoTransfer() {}

    static void save(VideoSaveRequest request, File cacheDirectory,
            Destination destination, Cancellation cancellation) throws IOException {
        boolean owner = OWNER.compareAndSet(false, true);
        boolean success = false;
        File cache = null;
        File videoDirectory = null;
        Timer watchdog = null;
        try {
            if (!owner) throw new IOException("video save busy");
            if (request == null || cancellation == null || destination == null
                    || cacheDirectory == null || !cacheDirectory.isDirectory()) {
                throw new IOException("video save unavailable");
            }
            long deadline = System.nanoTime() + MAX_DURATION_MS * 1000000L;
            cancellation.check(deadline);
            // Register cancellation before download and before a provider can block in open().
            cancellation.trackDestination(destination);
            videoDirectory = prepareCacheDirectory(cacheDirectory);
            cache = File.createTempFile("threadsmod-video-", ".part", videoDirectory);
            watchdog = new Timer("ThreadsModVideoDeadline", true);
            final Cancellation current = cancellation;
            watchdog.schedule(new TimerTask() {
                @Override public void run() { current.abort(); }
            }, MAX_DURATION_MS);
            download(VideoSaveRequest.validateUrl(request.url), cache, cancellation, deadline);
            cancellation.check(deadline);
            verifyMp4(cache);
            cancellation.check(deadline);
            try (InputStream input = new FileInputStream(cache)) {
                cancellation.track(null, input, null);
                try (OutputStream output = destination.open()) {
                    if (output == null) throw new IOException("video destination unavailable");
                    cancellation.track(null, input, output);
                    long written = copyBounded(input, output, cache.length(), cancellation, deadline);
                    if (written != cache.length()) throw new IOException("video copy incomplete");
                    output.flush();
                }
            }
            // Successful close of the provider stream, rather than download completion, is success.
            cancellation.check(deadline);
            success = true;
        } catch (RuntimeException invalid) {
            throw new IOException("video save unavailable");
        } finally {
            try {
                if (watchdog != null) watchdog.cancel();
                if (cancellation != null) cancellation.track(null, null, null);
                if (cancellation != null) cancellation.trackDestination(null);
                if (cache != null) cache.delete();
                if (videoDirectory != null) videoDirectory.delete(); // succeeds only when empty
                if (!success && destination != null) {
                    try { destination.discard(); } catch (RuntimeException ignored) {}
                }
            } finally {
                if (owner) OWNER.set(false);
            }
        }
    }

    private static File prepareCacheDirectory(File cacheDirectory) throws IOException {
        File directory = new File(cacheDirectory, "threadsmod-videos");
        File expected = new File(cacheDirectory.getCanonicalFile(), "threadsmod-videos");
        if (!directory.getCanonicalFile().equals(expected)
                || (!directory.isDirectory() && !directory.mkdir())) {
            throw new IOException("video cache unavailable");
        }
        // Reap only this feature's bounded leftovers after process interruption, under OWNER.
        File[] retained = directory.listFiles();
        if (retained == null || retained.length > 128) throw new IOException("video cache unavailable");
        for (File stale : retained) {
            if (!stale.getName().matches("threadsmod-video-[0-9]+\\.part")
                    || !stale.isFile() || !stale.getCanonicalFile().equals(new File(expected, stale.getName()))
                    || !stale.delete()) throw new IOException("video cache unavailable");
        }
        return directory;
    }

    private static void download(URL initial, File cache,
            Cancellation cancellation, long deadline) throws IOException {
        URL current = initial;
        for (int hop = 0; hop <= 3; hop++) {
            HttpsURLConnection connection = null;
            try {
                cancellation.check(deadline);
                synchronized (CookieHandler.class) {
                    requireIsolatedHttp();
                    connection = (HttpsURLConnection) current.openConnection();
                }
                cancellation.track(connection, null, null);
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(15000);
                connection.setUseCaches(false);
                connection.setRequestMethod("GET");
                connection.setRequestProperty("User-Agent", "ThreadsMod-VideoSave/1");
                connection.setRequestProperty("Accept", "video/mp4");
                connection.setRequestProperty("Accept-Encoding", "identity");
                requireIsolatedHttp();
                int status = connection.getResponseCode();
                cancellation.check(deadline);
                if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                    current = VideoSaveRequest.redirect(current, connection.getHeaderField("Location"), hop + 1);
                    continue;
                }
                if (status != 200) throw new IOException("video response unavailable");
                String type = connection.getContentType();
                if (type == null || !"video/mp4".equals(type.split(";", 2)[0].trim().toLowerCase(Locale.US))) {
                    throw new IOException("video response invalid");
                }
                String encoding = connection.getHeaderField("Content-Encoding");
                if (encoding != null && !"identity".equalsIgnoreCase(encoding.trim())) {
                    throw new IOException("video encoding invalid");
                }
                long declared = connection.getContentLengthLong();
                if (declared > MAX_BYTES || declared == 0L || declared < -1L) {
                    throw new IOException("video size invalid");
                }
                requireIsolatedHttp();
                try (InputStream input = connection.getInputStream();
                     FileOutputStream output = new FileOutputStream(cache)) {
                    cancellation.track(connection, input, output);
                    long received = copyBounded(input, output, MAX_BYTES, cancellation, deadline);
                    if (received == 0L || (declared >= 0L && received != declared)) {
                        throw new IOException("video response incomplete");
                    }
                    output.getFD().sync();
                }
                return;
            } finally {
                cancellation.track(null, null, null);
                if (connection != null) connection.disconnect();
            }
        }
        throw new IOException("video redirect invalid");
    }

    static long copyBounded(InputStream input, OutputStream output, long maximum,
            Cancellation cancellation, long deadline) throws IOException {
        if (maximum < 1L || maximum > MAX_BYTES) throw new IOException("video size invalid");
        byte[] buffer = new byte[32768];
        long total = 0L;
        for (;;) {
            cancellation.check(deadline);
            int read = input.read(buffer);
            cancellation.check(deadline);
            if (read < 0) return total;
            if (read == 0) throw new IOException("video stream stalled");
            if (read > maximum - total) throw new IOException("video size invalid");
            output.write(buffer, 0, read);
            total += read;
        }
    }

    static void verifyMp4(File file) throws IOException {
        if (file == null || !file.isFile() || file.length() < 32L || file.length() > MAX_BYTES) {
            throw new IOException("video file invalid");
        }
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            long length = input.length();
            long offset = 0L;
            boolean fileType = false;
            boolean movie = false;
            boolean media = false;
            int boxes = 0;
            while (offset < length) {
                if (++boxes > 100000 || length - offset < 8L) throw new IOException("video box invalid");
                input.seek(offset);
                long size = input.readInt() & 0xffffffffL;
                int type = input.readInt();
                long header = 8L;
                if (size == 1L) {
                    if (length - offset < 16L) throw new IOException("video box invalid");
                    size = input.readLong();
                    header = 16L;
                } else if (size == 0L) {
                    size = length - offset;
                }
                if (size < header || size > length - offset) throw new IOException("video box invalid");
                if (offset == 0L && type != 0x66747970) throw new IOException("video header invalid");
                if (type == 0x66747970) { // ftyp
                    if (fileType || header != 8L || size < 16L || size > 4096L
                            || (size - 16L) % 4L != 0L) throw new IOException("video header invalid");
                    boolean brand = allowedBrand(input.readInt());
                    input.readInt(); // minor version
                    for (long position = 16L; position < size; position += 4L) {
                        brand |= allowedBrand(input.readInt());
                    }
                    if (!brand) throw new IOException("video brand invalid");
                    fileType = true;
                } else if (type == 0x6d6f6f76) { // moov
                    if (size < header + 8L) throw new IOException("video movie invalid");
                    movie = true;
                } else if (type == 0x6d646174) { // mdat
                    if (size <= header) throw new IOException("video media invalid");
                    media = true;
                }
                offset += size;
            }
            if (!fileType || !movie || !media) throw new IOException("video structure invalid");
        }
    }

    private static boolean allowedBrand(int brand) {
        return brand == 0x69736f6d || (brand >= 0x69736f32 && brand <= 0x69736f39)
                || brand == 0x6d703431 || brand == 0x6d703432
                || brand == 0x61766331 || brand == 0x64617368 || brand == 0x4d345620;
    }

    private static void requireIsolatedHttp() throws IOException {
        if (CookieHandler.getDefault() != null) throw new IOException("video cookie isolation unavailable");
    }

    private static void closeQuietly(Closeable stream) {
        if (stream != null) try { stream.close(); } catch (Exception ignored) {}
    }
}
