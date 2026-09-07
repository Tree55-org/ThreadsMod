package threadsmod.reporting;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.CookieHandler;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.TimeZone;

import javax.net.ssl.HttpsURLConnection;

/** Foreground-only, single-flight delivery engine for explicitly queued reports. */
public final class ReportClient {
    private static final int CONNECT_TIMEOUT_MS = 15_000;
    private static final int READ_TIMEOUT_MS = 15_000;
    private static final int MAX_REQUEST_BYTES = 16 * 1024;
    private static final int MAX_RESPONSE_BYTES = 8 * 1024;
    private static final int MAX_PER_DRAIN = 20;
    private static final long MAX_WAKE_DELAY_MS = 24L * 60L * 60L * 1000L;

    private static final Object LOCK = new Object();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Runnable WAKE = new Runnable() {
        @Override
        public void run() {
            startDrain();
        }
    };

    private static Context applicationContext;
    private static String activeViewerId = "";
    private static boolean foreground;
    private static boolean workerRunning;
    private static boolean drainRequested;
    private static int drainRequestedGeneration = -1;
    private static int generation;
    private static long ownerSequence;
    private static HttpsURLConnection activeConnection;
    private static ForegroundOwner activeOwner;
    private static String cachedStatusViewerId = "";
    private static ReportStore.Snapshot cachedStatus;
    private static String trustedStoreViewerId = "";
    private static int trustedStoreGeneration = -1;

    private ReportClient() {}

    public interface LocalStatusCallback {
        void onStatus(ReportStore.Snapshot snapshot);
    }

    public interface RetryCallback {
        void onRetryRequested(boolean changed, ReportStore.Snapshot snapshot);
    }

    public interface CancelCallback {
        void onCancelled(ReportStore.CancelResult result, ReportStore.Snapshot snapshot);
    }

    public static final class ForegroundOwner {
        private final long value;

        private ForegroundOwner(long value) {
            this.value = value;
        }
    }

    /** Activates delivery only for this foreground viewer and schedules its exact wake. */
    public static ForegroundOwner onForeground(Context context, String viewerId) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            stopForeground(null, false);
            return null;
        }
        final ForegroundOwner owner;
        synchronized (LOCK) {
            owner = new ForegroundOwner(++ownerSequence);
            activeOwner = owner;
            applicationContext = context.getApplicationContext();
            activeViewerId = viewerId;
            foreground = true;
            generation++;
            drainRequested = false;
            drainRequestedGeneration = -1;
            trustedStoreViewerId = "";
            trustedStoreGeneration = -1;
            disconnectLocked();
            MAIN.removeCallbacks(WAKE);
        }
        startDrain();
        scheduleStatusRefresh(context.getApplicationContext(), viewerId, null);
        return owner;
    }

    /** Stops wakes and aborts any active transport; persisted work remains viewer-scoped. */
    public static void onBackground() {
        stopForeground(null, false);
    }

    /** A stale Activity owner cannot stop a newer foreground owner's delivery. */
    public static void onBackground(ForegroundOwner owner) {
        stopForeground(owner, true);
    }

    private static void stopForeground(ForegroundOwner owner, boolean requireOwner) {
        synchronized (LOCK) {
            if (requireOwner && (owner == null || owner != activeOwner)) {
                return;
            }
            foreground = false;
            activeOwner = null;
            activeViewerId = "";
            generation++;
            drainRequested = false;
            drainRequestedGeneration = -1;
            trustedStoreViewerId = "";
            trustedStoreGeneration = -1;
            MAIN.removeCallbacks(WAKE);
            disconnectLocked();
        }
    }

    public static boolean isForegroundFor(String viewerId) {
        synchronized (LOCK) {
            return foreground && ReportValues.isNumericId(viewerId)
                    && viewerId.equals(activeViewerId);
        }
    }

    private static int foregroundGeneration(String viewerId) {
        synchronized (LOCK) {
            return foreground && ReportValues.isNumericId(viewerId)
                    && viewerId.equals(activeViewerId) ? generation : -1;
        }
    }

    /**
     * Persists one report authorized by the combined modal's positive-action tap.
     * Network delivery remains foreground-only and starts only after durable enqueue.
     */
    static void queueExplicit(
            Context context,
            String viewerId,
            ReportRequest request,
            String reason,
            ReportResultCallback callback) {
        ReportResult result;
        if (context == null || !ReportValues.isNumericId(viewerId)
                || request == null || !request.isValidForNewQueue()
                || !ReportPayload.isReason(reason)) {
            result = new ReportResult(
                    ReportResult.INVALID, "", "The report fields are invalid.");
            postResult(callback, result);
            return;
        }
        if (request.isViewer(viewerId)) {
            result = new ReportResult(
                    ReportResult.SELF_TARGET, "", "You cannot report the active viewer.");
            postResult(callback, result);
            return;
        }
        final int safeGeneration = foregroundGeneration(viewerId);
        if (safeGeneration < 0) {
            result = new ReportResult(
                    ReportResult.NOT_FOREGROUND,
                    "",
                    "The report was not queued because Threads Mod is not foregrounded for this account.");
            postResult(callback, result);
            return;
        }

        final Context safeContext = context.getApplicationContext();
        final String safeViewerId = viewerId;
        final ReportRequest safeRequest = request;
        final String safeReason = reason;
        final ReportResultCallback safeCallback = callback;
        Thread persistence = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    ReportStore.PseudonymDraft pseudonymDraft =
                            ReportStore.preparePseudonym(safeContext, safeViewerId);
                    if (pseudonymDraft == null || !pseudonymDraft.isValid()) {
                        postResult(
                                safeCallback,
                                new ReportResult(
                                        ReportResult.STORE_FAILED,
                                        "",
                                        "The report pseudonym could not be prepared for the local outbox."));
                        return;
                    }
                    ReportPayload payload = ReportPayload.create(
                            pseudonymDraft.pseudonym,
                            safeRequest,
                            safeReason,
                            "",
                            currentLanguage(),
                            currentTimeZone());
                    if (payload == null || !payload.isValid()
                            || !pseudonymDraft.pseudonym.equals(payload.getPseudonym())) {
                        postResult(
                                safeCallback,
                                new ReportResult(
                                        ReportResult.STORE_FAILED,
                                        "",
                                        "The report could not be prepared for the local outbox."));
                        return;
                    }
                    persistExplicit(
                            safeContext,
                            safeViewerId,
                            payload,
                            pseudonymDraft,
                            safeGeneration,
                            safeCallback);
                } catch (Throwable ignored) {
                    postResult(
                            safeCallback,
                            new ReportResult(
                                    ReportResult.STORE_FAILED,
                                    "",
                                    "The report could not be saved locally; nothing was sent."));
                }
            }
        }, "threadsmod-report-persist");
        persistence.setDaemon(true);
        try {
            persistence.start();
        } catch (Throwable ignored) {
            postResult(
                    callback,
                    new ReportResult(
                            ReportResult.STORE_FAILED,
                            "",
                            "The local report worker could not start; nothing was sent."));
        }
    }

    private static void persistExplicit(
            Context context,
            String viewerId,
            ReportPayload payload,
            ReportStore.PseudonymDraft pseudonymDraft,
            int expectedGeneration,
            ReportResultCallback callback) {
        ReportResult result;
        if (!isActive(viewerId, expectedGeneration)) {
            postResult(callback, new ReportResult(
                    ReportResult.NOT_FOREGROUND,
                    "",
                    "The foreground account changed before the report could be queued."));
            return;
        }
        ReportStore.Snapshot preflight = ReportStore.getSnapshot(context, viewerId);
        cacheStatus(viewerId, preflight);
        if (!storageReady(preflight)) {
            result = new ReportResult(
                    ReportResult.OUTBOX_NEEDS_REVIEW,
                    "",
                    "The local report database needs review; nothing was changed or sent.");
            postResult(callback, result);
            return;
        }
        if (!isActive(viewerId, expectedGeneration)) {
            postResult(callback, new ReportResult(
                    ReportResult.NOT_FOREGROUND,
                    "",
                    "The foreground account changed before the report could be queued."));
            return;
        }
        if (payload == null || !payload.isValid()
                || pseudonymDraft == null || !pseudonymDraft.isValid()
                || !ReportStore.commitPseudonym(
                        context, viewerId, pseudonymDraft)) {
            ReportStore.Snapshot snapshot = ReportStore.getSnapshot(context, viewerId);
            cacheStatus(viewerId, snapshot);
            result = snapshot.needsReview
                    ? new ReportResult(
                            ReportResult.OUTBOX_NEEDS_REVIEW,
                            "",
                            "The local report state needs review; nothing was sent.")
                    : new ReportResult(
                            ReportResult.STORE_FAILED,
                            "",
                            "The report pseudonym changed or could not be committed; nothing was sent.");
            postResult(callback, result);
            return;
        }

        ReportStore.EnqueueResult stored = ReportStore.enqueue(
                context, viewerId, payload, System.currentTimeMillis());
        if (stored.code == ReportStore.EnqueueResult.ACCEPTED) {
            result = new ReportResult(
                    ReportResult.QUEUED,
                    stored.reportId,
                    "Report saved locally and queued for foreground delivery.");
            startDrain();
        } else if (stored.code == ReportStore.EnqueueResult.FULL) {
            result = new ReportResult(
                    ReportResult.OUTBOX_FULL,
                    "",
                    "The 1,000-report outbox is full; nothing was sent.");
        } else if (stored.code == ReportStore.EnqueueResult.NEEDS_REVIEW) {
            result = new ReportResult(
                    ReportResult.OUTBOX_NEEDS_REVIEW,
                    "",
                    "The local report outbox needs review; its stored bytes were left unchanged and nothing was sent.");
        } else {
            result = new ReportResult(
                    ReportResult.STORE_FAILED,
                    "",
                    "The report could not be saved locally; nothing was sent.");
        }
        ReportStore.Snapshot snapshot = ReportStore.getSnapshot(context, viewerId);
        cacheStatus(viewerId, snapshot);
        postResult(callback, result);
    }

    /** User-requested retry; attempts are not erased and the 15-attempt ceiling remains. */
    public static boolean retryPendingNow(Context context, String viewerId) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            return false;
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return false;
        }
        ReportStore.Snapshot preflight = ReportStore.getSnapshot(context, viewerId);
        cacheStatus(viewerId, preflight);
        if (!storageReady(preflight)) {
            return false;
        }
        boolean changed = ReportStore.retryNow(
                context, viewerId, System.currentTimeMillis());
        if (changed && isForegroundFor(viewerId)) {
            startDrain();
        }
        scheduleStatusRefresh(context.getApplicationContext(), viewerId, null);
        return changed;
    }

    public static void retryPendingNowAsync(
            final Context context,
            final String viewerId,
            final RetryCallback callback) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            postRetry(callback, false, ReportStore.getSnapshot(null, ""));
            return;
        }
        final Context safeContext = context.getApplicationContext();
        Thread retry = new Thread(new Runnable() {
            @Override
            public void run() {
                ReportStore.Snapshot preflight =
                        ReportStore.getSnapshot(safeContext, viewerId);
                if (!storageReady(preflight)) {
                    cacheStatus(viewerId, preflight);
                    postRetry(callback, false, preflight);
                    return;
                }
                boolean changed = ReportStore.retryNow(
                        safeContext, viewerId, System.currentTimeMillis());
                if (changed && isForegroundFor(viewerId)) {
                    startDrain();
                }
                ReportStore.Snapshot snapshot =
                        ReportStore.getSnapshot(safeContext, viewerId);
                cacheStatus(viewerId, snapshot);
                postRetry(callback, changed, snapshot);
            }
        }, "threadsmod-report-retry");
        retry.setDaemon(true);
        retry.start();
    }

    public static ReportStore.Snapshot getLocalStatus(Context context, String viewerId) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            return ReportStore.getSnapshot(null, "");
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            ReportStore.Snapshot cached;
            synchronized (LOCK) {
                cached = viewerId.equals(cachedStatusViewerId) ? cachedStatus : null;
            }
            scheduleStatusRefresh(context.getApplicationContext(), viewerId, null);
            return cached == null ? ReportStore.getSnapshot(null, "") : cached;
        }
        ReportStore.Snapshot snapshot = ReportStore.getSnapshot(context, viewerId);
        cacheStatus(viewerId, snapshot);
        return snapshot;
    }

    public static void getLocalStatusAsync(
            Context context, String viewerId, LocalStatusCallback callback) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            postStatus(callback, ReportStore.getSnapshot(null, ""));
            return;
        }
        scheduleStatusRefresh(context.getApplicationContext(), viewerId, callback);
    }

    /** Explicit user deletion of one pending payload; no history record is retained. */
    public static boolean cancelPending(
            Context context, String viewerId, String reportId) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return false;
        }
        ReportStore.Snapshot preflight = ReportStore.getSnapshot(context, viewerId);
        cacheStatus(viewerId, preflight);
        if (!storageReady(preflight)) {
            return false;
        }
        boolean deleted = ReportStore.cancelPending(context, viewerId, reportId);
        if (context != null && ReportValues.isNumericId(viewerId)) {
            scheduleStatusRefresh(context.getApplicationContext(), viewerId, null);
        }
        return deleted;
    }

    public static ReportStore.CancelResult cancelPendingDetailed(
            Context context, String viewerId, String reportId) {
        if (context == null || !ReportValues.isNumericId(viewerId)
                || Looper.myLooper() == Looper.getMainLooper()) {
            return new ReportStore.CancelResult(ReportStore.CancelResult.FAILED);
        }
        ReportStore.Snapshot preflight = ReportStore.getSnapshot(context, viewerId);
        cacheStatus(viewerId, preflight);
        if (!storageReady(preflight)) {
            return new ReportStore.CancelResult(ReportStore.CancelResult.NEEDS_REVIEW);
        }
        return ReportStore.cancelPendingDetailed(context, viewerId, reportId);
    }

    public static void cancelPendingAsync(
            final Context context,
            final String viewerId,
            final String reportId,
            final CancelCallback callback) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            postCancel(
                    callback,
                    new ReportStore.CancelResult(ReportStore.CancelResult.FAILED),
                    ReportStore.getSnapshot(null, ""));
            return;
        }
        final Context safeContext = context.getApplicationContext();
        Thread cancel = new Thread(new Runnable() {
            @Override
            public void run() {
                ReportStore.Snapshot preflight =
                        ReportStore.getSnapshot(safeContext, viewerId);
                if (!storageReady(preflight)) {
                    cacheStatus(viewerId, preflight);
                    postCancel(
                            callback,
                            new ReportStore.CancelResult(
                                    ReportStore.CancelResult.NEEDS_REVIEW),
                            preflight);
                    return;
                }
                ReportStore.CancelResult result = ReportStore.cancelPendingDetailed(
                        safeContext, viewerId, reportId);
                ReportStore.Snapshot snapshot =
                        ReportStore.getSnapshot(safeContext, viewerId);
                cacheStatus(viewerId, snapshot);
                postCancel(callback, result, snapshot);
            }
        }, "threadsmod-report-cancel");
        cancel.setDaemon(true);
        cancel.start();
    }

    private static void startDrain() {
        final Context context;
        final String viewerId;
        final int expectedGeneration;
        synchronized (LOCK) {
            MAIN.removeCallbacks(WAKE);
            if (!foreground || applicationContext == null
                    || !ReportValues.isNumericId(activeViewerId)) {
                return;
            }
            if (workerRunning) {
                drainRequested = true;
                drainRequestedGeneration = generation;
                return;
            }
            workerRunning = true;
            drainRequested = false;
            drainRequestedGeneration = -1;
            context = applicationContext;
            viewerId = activeViewerId;
            expectedGeneration = generation;
        }
        Thread worker = new Thread(new Runnable() {
            @Override
            public void run() {
                drain(context, viewerId, expectedGeneration);
            }
        }, "threadsmod-report-delivery");
        worker.setDaemon(true);
        worker.start();
    }

    private static void drain(Context context, String viewerId, int expectedGeneration) {
        int processed = 0;
        try {
            if (!hasTrustedStore(viewerId, expectedGeneration)) {
                ReportStore.Snapshot preflight =
                        ReportStore.getSnapshot(context, viewerId);
                cacheStatus(viewerId, preflight);
                if (!storageReady(preflight)
                        || !trustStoreIfActive(viewerId, expectedGeneration)) {
                    return;
                }
            }
            while (processed < MAX_PER_DRAIN
                    && isActive(viewerId, expectedGeneration)) {
                ReportStore.Delivery delivery = ReportStore.reserveNextDue(
                        context, viewerId, System.currentTimeMillis());
                if (delivery == null) {
                    break;
                }
                try {
                    if (!isActive(viewerId, expectedGeneration)) {
                        break;
                    }
                    TransportResult transport = post(
                            delivery.payload, viewerId, expectedGeneration);
                    long completedAt = System.currentTimeMillis();
                    if (transport.accepted) {
                        ReportStore.markSent(
                                context, viewerId, delivery.reportId, completedAt);
                    } else if (transport.httpStatus == 403) {
                        ReportStore.markRejected(
                                context, viewerId, delivery.reportId, completedAt);
                    } else {
                        ReportStore.markFailure(
                                context,
                                viewerId,
                                delivery.reportId,
                                transport.httpStatus,
                                transport.error,
                                completedAt);
                    }
                    processed++;
                } finally {
                    ReportStore.releaseDelivery(delivery.reportId);
                }
            }
        } finally {
            long now = System.currentTimeMillis();
            long nextAt = ReportStore.nextWakeAt(context, viewerId);
            boolean immediatePending = isActive(viewerId, expectedGeneration)
                    && nextAt > 0L && nextAt <= now;
            if (!immediatePending) {
                ReportStore.Snapshot snapshot =
                        ReportStore.getSnapshot(context, viewerId);
                cacheStatus(viewerId, snapshot);
            }
            finishDrain(viewerId, expectedGeneration, nextAt);
        }
    }

    private static void finishDrain(
            String workerViewerId, int workerGeneration, long nextAt) {
        boolean contextReplaced = false;
        boolean rerunRequested = false;
        synchronized (LOCK) {
            activeConnection = null;
            workerRunning = false;
            if (!foreground || applicationContext == null
                    || !ReportValues.isNumericId(activeViewerId)) {
                return;
            }
            if (workerGeneration != generation
                    || !workerViewerId.equals(activeViewerId)) {
                contextReplaced = true;
                MAIN.removeCallbacks(WAKE);
            } else if (drainRequested
                    && drainRequestedGeneration == workerGeneration) {
                rerunRequested = true;
                drainRequested = false;
                drainRequestedGeneration = -1;
                MAIN.removeCallbacks(WAKE);
            }
        }
        if (contextReplaced || rerunRequested) {
            startDrain();
            return;
        }
        long now = System.currentTimeMillis();
        synchronized (LOCK) {
            if (!foreground || generation != workerGeneration
                    || !workerViewerId.equals(activeViewerId) || workerRunning) {
                return;
            }
            MAIN.removeCallbacks(WAKE);
            if (nextAt > 0L) {
                long delay = nextAt <= now
                        ? 0L : Math.min(nextAt - now, MAX_WAKE_DELAY_MS);
                MAIN.postDelayed(WAKE, delay);
            }
        }
    }

    private static boolean hasTrustedStore(String viewerId, int expectedGeneration) {
        synchronized (LOCK) {
            return foreground
                    && expectedGeneration == generation
                    && expectedGeneration == trustedStoreGeneration
                    && viewerId.equals(activeViewerId)
                    && viewerId.equals(trustedStoreViewerId);
        }
    }

    private static boolean trustStoreIfActive(String viewerId, int expectedGeneration) {
        synchronized (LOCK) {
            if (!foreground || expectedGeneration != generation
                    || !viewerId.equals(activeViewerId)) {
                return false;
            }
            trustedStoreViewerId = viewerId;
            trustedStoreGeneration = expectedGeneration;
            return true;
        }
    }

    private static boolean isActive(String viewerId, int expectedGeneration) {
        synchronized (LOCK) {
            return foreground && expectedGeneration == generation
                    && viewerId.equals(activeViewerId);
        }
    }

    private static TransportResult post(
            ReportPayload payload, String viewerId, int expectedGeneration) {
        HttpsURLConnection connection = null;
        try {
            JSONObject json = payload == null ? null : payload.toJson();
            byte[] body = json == null
                    ? new byte[0] : json.toString().getBytes(StandardCharsets.UTF_8);
            if (body.length == 0 || body.length > MAX_REQUEST_BYTES) {
                return new TransportResult(0, "invalid_payload_size", false);
            }

            URL url = ReportEndpoint.writeUrl();
            synchronized (CookieHandler.class) {
                if (CookieHandler.getDefault() != null) {
                    return new TransportResult(0, "cookie_handler_present", false);
                }
                connection = (HttpsURLConnection) url.openConnection();
            }
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setInstanceFollowRedirects(false);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setUseCaches(false);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            connection.setRequestProperty("Accept", "application/json");
            connection.setRequestProperty("User-Agent", "ThreadsMod-CloneBlocker/1");
            connection.setFixedLengthStreamingMode(body.length);
            if (CookieHandler.getDefault() != null) {
                connection.disconnect();
                return new TransportResult(0, "cookie_handler_present", false);
            }
            if (!registerConnection(connection, viewerId, expectedGeneration)) {
                connection.disconnect();
                return new TransportResult(0, "foreground_changed", false);
            }

            OutputStream output = connection.getOutputStream();
            try {
                output.write(body);
                output.flush();
            } finally {
                output.close();
            }
            int status = connection.getResponseCode();
            ResponseBody response = readBounded(connection, status);
            boolean accepted = status >= 200 && status <= 299
                    && response.complete && response.validUtf8 && hasOkTrue(response.text);
            String error;
            if (accepted) {
                error = "";
            } else if (!response.complete) {
                error = "response_too_large";
            } else if (!response.validUtf8) {
                error = "invalid_utf8_response";
            } else if (status >= 200 && status <= 299) {
                error = "invalid_success_response";
            } else {
                error = "http_" + status;
            }
            return new TransportResult(status, error, accepted);
        } catch (Throwable ignored) {
            return new TransportResult(0, "network_error", false);
        } finally {
            clearConnection(connection);
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static ResponseBody readBounded(HttpsURLConnection connection, int status) {
        InputStream input = null;
        ByteArrayOutputStream collected = new ByteArrayOutputStream();
        boolean complete = true;
        try {
            input = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
            if (input == null) {
                return new ResponseBody("", true, true);
            }
            byte[] buffer = new byte[1024];
            int total = 0;
            while (total <= MAX_RESPONSE_BYTES) {
                int read = input.read(buffer, 0,
                        Math.min(buffer.length, MAX_RESPONSE_BYTES + 1 - total));
                if (read < 0) {
                    break;
                }
                total += read;
                if (total > MAX_RESPONSE_BYTES) {
                    complete = false;
                    break;
                }
                collected.write(buffer, 0, read);
            }
        } catch (Throwable ignored) {
            complete = false;
        } finally {
            if (input != null) {
                try {
                    input.close();
                } catch (Throwable ignored) {
                    // Disconnect below closes remaining transport state.
                }
            }
        }
        try {
            String text = ReportJson.decodeUtf8(collected.toByteArray());
            if (text == null) {
                return new ResponseBody("", complete, false);
            }
            return new ResponseBody(text, complete, true);
        } catch (Throwable invalidEncoding) {
            return new ResponseBody("", complete, false);
        }
    }

    private static boolean hasOkTrue(String body) {
        if (!ReportJson.isCompleteObject(body)) {
            return false;
        }
        try {
            JSONObject response = new JSONObject(body);
            return Boolean.TRUE.equals(response.opt("ok"));
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static boolean registerConnection(
            HttpsURLConnection connection, String viewerId, int expectedGeneration) {
        synchronized (LOCK) {
            if (!foreground || expectedGeneration != generation
                    || !viewerId.equals(activeViewerId)) {
                return false;
            }
            activeConnection = connection;
            return true;
        }
    }

    private static void clearConnection(HttpsURLConnection connection) {
        synchronized (LOCK) {
            if (activeConnection == connection) {
                activeConnection = null;
            }
        }
    }

    private static void disconnectLocked() {
        HttpsURLConnection connection = activeConnection;
        activeConnection = null;
        if (connection != null) {
            try {
                connection.disconnect();
            } catch (Throwable ignored) {
                // The worker observes the generation change as well.
            }
        }
    }

    private static String currentLanguage() {
        try {
            return ReportValues.cleanText(
                    Locale.getDefault().toLanguageTag(), ReportValues.MAX_LANGUAGE);
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String currentTimeZone() {
        try {
            return ReportValues.cleanText(
                    TimeZone.getDefault().getID(), ReportValues.MAX_TIME_ZONE);
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static void postResult(
            final ReportResultCallback callback, final ReportResult result) {
        if (callback == null) {
            return;
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            callback.onResult(result);
            return;
        }
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                callback.onResult(result);
            }
        });
    }

    private static void scheduleStatusRefresh(
            final Context context,
            final String viewerId,
            final LocalStatusCallback callback) {
        Thread refresh = new Thread(new Runnable() {
            @Override
            public void run() {
                ReportStore.Snapshot snapshot =
                        ReportStore.getSnapshot(context, viewerId);
                cacheStatus(viewerId, snapshot);
                postStatus(callback, snapshot);
            }
        }, "threadsmod-report-status");
        refresh.setDaemon(true);
        refresh.start();
    }

    private static void cacheStatus(String viewerId, ReportStore.Snapshot snapshot) {
        synchronized (LOCK) {
            cachedStatusViewerId = viewerId == null ? "" : viewerId;
            cachedStatus = snapshot;
        }
    }

    private static boolean storageReady(ReportStore.Snapshot snapshot) {
        return snapshot != null
                && !snapshot.needsReview
                && ReportStore.LOCAL_STATE_VALID.equals(snapshot.outboxState)
                && ReportStore.LOCAL_STATE_VALID.equals(snapshot.historyState);
    }

    private static void postStatus(
            final LocalStatusCallback callback,
            final ReportStore.Snapshot snapshot) {
        if (callback == null) {
            return;
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            callback.onStatus(snapshot);
            return;
        }
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                callback.onStatus(snapshot);
            }
        });
    }

    private static void postRetry(
            final RetryCallback callback,
            final boolean changed,
            final ReportStore.Snapshot snapshot) {
        if (callback == null) {
            return;
        }
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                callback.onRetryRequested(changed, snapshot);
            }
        });
    }

    private static void postCancel(
            final CancelCallback callback,
            final ReportStore.CancelResult result,
            final ReportStore.Snapshot snapshot) {
        if (callback == null) {
            return;
        }
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                callback.onCancelled(result, snapshot);
            }
        });
    }

    private static final class TransportResult {
        final int httpStatus;
        final String error;
        final boolean accepted;

        TransportResult(int httpStatus, String error, boolean accepted) {
            this.httpStatus = httpStatus;
            this.error = ReportValues.cleanToken(error, 120);
            this.accepted = accepted;
        }
    }

    private static final class ResponseBody {
        final String text;
        final boolean complete;
        final boolean validUtf8;

        ResponseBody(String text, boolean complete, boolean validUtf8) {
            this.text = text == null ? "" : text;
            this.complete = complete;
            this.validUtf8 = validUtf8;
        }
    }
}
