package threadsmod.inlinecontrol;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;

import java.lang.ref.WeakReference;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

import threadsmod.autoblock.AutoBlockSync;
import threadsmod.autoblock.ManualBlockCallback;
import threadsmod.autoblock.ModStateStore;
import threadsmod.reporting.ReportController;
import threadsmod.reporting.ReportPayload;
import threadsmod.reporting.ReportRequest;
import threadsmod.reporting.ReportResult;
import threadsmod.reporting.ReportResultCallback;

/**
 * Stable controller for a version-specific inline Block renderer.
 *
 * It has no Compose or obfuscated Threads dependency. The version patchlet owns
 * author/media extraction and rendering; AutoBlockSync owns the one-at-a-time
 * native scheduler and passive pacing.
 */
public final class InlineBlockController {
    public static final String UI_IDLE = "idle";
    public static final String UI_CONFIRMING = "confirming";
    public static final String UI_QUEUED = "queued";
    public static final String UI_STARTED = "started";
    public static final String UI_SUCCESS = "success";
    public static final String UI_FAILED = "failed";

    /** Success hold and color contract mirrored by the native Compose adapter. */
    public static final long SUCCESS_HOLD_MS = 550L;
    public static final int SUCCESS_COLOR_ARGB = 0xff2e9e5b;

    private static final int MAX_OPERATIONS = 128;
    private static final long TERMINAL_STALE_MS = 2L * 60L * 1000L;
    private static final long CONFIRMATION_STALE_MS = 10L * 60L * 1000L;
    private static final long SUCCESS_VISIBLE_MS = 1500L;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final AtomicLong TOKENS = new AtomicLong();
    private static final Object LOCK = new Object();
    private static final LinkedHashMap<String, Operation> OPERATIONS =
            new LinkedHashMap<String, Operation>(32, 0.75f, true);

    private InlineBlockController() {}

    /**
     * Entry point for the sole host-rendered Block button. The SHA-bound host
     * supplies the immutable Report request for the same row. Calls are
     * marshalled to Android's main thread before UI work.
     */
    public static void onClick(
            final InlineBlockRequest request,
            final ReportRequest reportRequest,
            final InlineBlockUiCallback callback) {
        onClick(
                request,
                reportRequest,
                request == null ? null : request.getResolvedAuthorModel(),
                callback);
    }

    /** Called by the SHA-bound click adapter with the exact model from this row. */
    public static void onClick(
            final InlineBlockRequest request,
            final ReportRequest reportRequest,
            final Object resolvedAuthorModel,
            final InlineBlockUiCallback callback) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            MAIN.post(new Runnable() {
                @Override
                public void run() {
                    onClick(request, reportRequest, resolvedAuthorModel, callback);
                }
            });
            return;
        }
        if (request == null || callback == null || !request.isValid()
                || !reportMatches(request, reportRequest)) {
            failBeforeEnqueue(
                    callback, request, resolvedAuthorModel, "invalid_target");
            return;
        }

        Activity activity = AutoBlockSync.getForegroundActivity();
        String viewer = AutoBlockSync.getCurrentViewer();
        if (!usableActivity(activity) || !InlineBlockRequest.isNumericId(viewer)) {
            failBeforeEnqueue(
                    callback, request, resolvedAuthorModel, "no_foreground_session");
            return;
        }
        if (viewer.equals(request.getAuthorId())) {
            failBeforeEnqueue(
                    callback, request, resolvedAuthorModel, "self_block_refused");
            return;
        }

        final Operation operation = reserve(request, resolvedAuthorModel, callback);
        if (operation == null) {
            // An operation for this immutable media/author pair is already live.
            return;
        }
        showConfirmation(activity, viewer, operation, reportRequest);
    }

    /** State lookup for a version adapter that needs to reconstruct a recycled row. */
    public static String getUiState(String mediaKey, String authorId) {
        InlineBlockRequest request = new InlineBlockRequest(mediaKey, authorId, "");
        if (!request.isValid()) {
            return UI_IDLE;
        }
        synchronized (LOCK) {
            pruneLocked(System.currentTimeMillis());
            Operation operation = OPERATIONS.get(request.operationKey());
            return operation == null ? UI_IDLE : operation.state;
        }
    }

    public static boolean isInFlight(String mediaKey, String authorId) {
        String state = getUiState(mediaKey, authorId);
        return UI_CONFIRMING.equals(state) || UI_QUEUED.equals(state)
                || UI_STARTED.equals(state);
    }

    /** Removes only terminal visual state; active native work cannot be cleared. */
    public static void clearTerminalState(String mediaKey, String authorId) {
        InlineBlockRequest request = new InlineBlockRequest(mediaKey, authorId, "");
        if (!request.isValid()) {
            return;
        }
        synchronized (LOCK) {
            Operation operation = OPERATIONS.get(request.operationKey());
            if (operation != null && (UI_SUCCESS.equals(operation.state)
                    || UI_FAILED.equals(operation.state))) {
                OPERATIONS.remove(request.operationKey());
            }
        }
    }

    private static void showConfirmation(
            final Activity activity,
            final String viewer,
            final Operation operation,
            final ReportRequest reportRequest) {
        try {
            InlineBlockDialog.show(
                    activity,
                    operation.request,
                    reportRequest,
                    ModStateStore.isAlsoBlockProfileEnabled(activity),
                    new InlineBlockDialog.Listener() {
                        @Override
                        public void onAlsoBlockChanged(boolean alsoBlock) {
                            ModStateStore.setAlsoBlockProfileEnabled(activity, alsoBlock);
                        }

                        @Override
                        public void onSubmit(String reason, boolean alsoBlock) {
                            submitCombined(
                                    activity,
                                    viewer,
                                    operation,
                                    reportRequest,
                                    reason,
                                    alsoBlock);
                        }

                        @Override
                        public void onCancel() {
                            cancel(operation);
                        }
                    });
        } catch (Throwable error) {
            fail(operation, "confirmation_unavailable");
        }
    }

    private static void submitCombined(
            final Activity activity,
            final String viewer,
            final Operation operation,
            final ReportRequest reportRequest,
            final String reason,
            final boolean alsoBlock) {
        if (!isCurrentWithState(operation, UI_CONFIRMING)
                || !usableActivity(activity)
                || AutoBlockSync.getForegroundActivity() != activity
                || !viewer.equals(AutoBlockSync.getCurrentViewer())
                || !reportMatches(operation.request, reportRequest)
                || !ReportPayload.isReason(reason)) {
            fail(operation, "report_context_unavailable");
            return;
        }

        try {
            ReportController.queueFromForeground(
                    activity,
                    viewer,
                    reportRequest,
                    reason,
                    new ReportResultCallback() {
                        @Override
                        public void onResult(ReportResult result) {
                            showReportResult(activity, result);
                            if (!alsoBlock && isCurrent(operation)) {
                                InlineBlockUiCallback callback = operation.callback();
                                remove(operation);
                                safeCancelled(callback, operation.request);
                            }
                        }

                        @Override
                        public void onCancelled() {
                            if (!alsoBlock && isCurrent(operation)) {
                                InlineBlockUiCallback callback = operation.callback();
                                remove(operation);
                                safeCancelled(callback, operation.request);
                            }
                        }
                    });
        } catch (Throwable ignored) {
            showReportResult(activity, null);
            if (!alsoBlock && isCurrent(operation)) {
                InlineBlockUiCallback callback = operation.callback();
                remove(operation);
                safeCancelled(callback, operation.request);
            }
        }

        if (alsoBlock && isCurrent(operation)) {
            submit(activity, viewer, operation);
        }
    }

    private static void submit(
            Activity activity,
            String viewer,
            final Operation operation) {
        if (!isCurrent(operation) || !usableActivity(activity)
                || AutoBlockSync.getForegroundActivity() != activity) {
            fail(operation, "foreground_lost");
            return;
        }
        String liveViewer = AutoBlockSync.getCurrentViewer();
        if (!viewer.equals(liveViewer)) {
            fail(operation, "viewer_changed");
            return;
        }

        boolean accepted;
        // The scheduler reports a synchronous pre-queue refusal through the callback and by
        // returning false; the specific closed stage must win over the generic rejection.
        final String[] synchronousRefusal = new String[1];
        final boolean[] schedulerReturned = new boolean[1];
        try {
            accepted = AutoBlockSync.enqueueManual(
                    operation.request.getAuthorId(),
                    operation.request.getLabel(),
                    operation.resolvedAuthorModel,
                    new ManualBlockCallback() {
                        @Override
                        public void onManualBlockQueued(String targetId) {
                            // The controller emitted queued only after its own durable write.
                        }

                        @Override
                        public void onManualBlockStarted(String targetId) {
                            postStarted(operation, targetId);
                        }

                        @Override
                        public void onManualBlockSuccess(String targetId) {
                            postSuccess(operation, targetId);
                        }

                        @Override
                        public void onManualBlockFailure(String targetId, String stage) {
                            if (!schedulerReturned[0] && targetMatches(operation, targetId)) {
                                synchronousRefusal[0] = safeStage(stage);
                                return;
                            }
                            postFailure(operation, targetId, stage);
                        }
                    });
        } catch (Throwable error) {
            accepted = false;
        }
        schedulerReturned[0] = true;
        if (!accepted) {
            if (synchronousRefusal[0] != null) {
                fail(operation, synchronousRefusal[0]);
                return;
            }
            fail(operation, "scheduler_rejected");
            return;
        }
        // AutoBlockSync returned true only after committing the durable queue item.
        transition(operation, UI_QUEUED);
        safeQueued(operation.callback(), operation.request);
    }

    private static void postStarted(final Operation operation, final String targetId) {
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                if (!targetMatches(operation, targetId) || !isCurrent(operation)) {
                    return;
                }
                transition(operation, UI_STARTED);
                safeStarted(operation.callback(), operation.request);
            }
        });
    }

    private static void postSuccess(final Operation operation, final String targetId) {
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                if (!targetMatches(operation, targetId) || !isCurrent(operation)) {
                    return;
                }
                transition(operation, UI_SUCCESS);
                safeSuccess(operation.callback(), operation.request);

                MAIN.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        if (!isCurrentWithState(operation, UI_SUCCESS)) {
                            return;
                        }
                        // Restore the sole report-capable entry after Block success.
                        safeCancelled(operation.callback(), operation.request);
                        remove(operation);
                    }
                }, SUCCESS_VISIBLE_MS);
            }
        });
    }

    private static void postFailure(
            final Operation operation,
            final String targetId,
            final String stage) {
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                if (targetMatches(operation, targetId) && isCurrent(operation)) {
                    fail(operation, safeStage(stage));
                }
            }
        });
    }

    private static void cancel(Operation operation) {
        if (!isCurrentWithState(operation, UI_CONFIRMING)) {
            return;
        }
        InlineBlockUiCallback callback = operation.callback();
        remove(operation);
        safeCancelled(callback, operation.request);
    }

    private static void fail(Operation operation, String stage) {
        if (operation == null || !isCurrent(operation)) {
            return;
        }
        String closedStage = safeStage(stage);
        if (isCurrentWithState(operation, UI_CONFIRMING)) {
            AutoBlockSync.recordInlinePreEnqueueFailure(
                    closedStage, operation.resolvedAuthorModel != null);
        }
        transition(operation, UI_FAILED);
        safeFailure(operation.callback(), operation.request, closedStage);
        remove(operation);
    }

    private static void failBeforeEnqueue(
            InlineBlockUiCallback callback,
            InlineBlockRequest request,
            Object resolvedAuthorModel,
            String stage) {
        String closedStage = safeStage(stage);
        AutoBlockSync.recordInlinePreEnqueueFailure(
                closedStage, resolvedAuthorModel != null);
        safeFailure(callback, request, closedStage);
    }

    private static Operation reserve(
            InlineBlockRequest request,
            Object resolvedAuthorModel,
            InlineBlockUiCallback callback) {
        synchronized (LOCK) {
            long now = System.currentTimeMillis();
            pruneLocked(now);
            String key = request.operationKey();
            if (OPERATIONS.containsKey(key)) {
                return null;
            }
            for (Operation current : OPERATIONS.values()) {
                if (request.getAuthorId().equals(current.request.getAuthorId())
                        && (UI_CONFIRMING.equals(current.state)
                        || UI_QUEUED.equals(current.state)
                        || UI_STARTED.equals(current.state))) {
                    return null;
                }
            }
            if (OPERATIONS.size() >= MAX_OPERATIONS && !removeOneTerminalLocked()) {
                return null;
            }
            Operation operation = new Operation(
                    TOKENS.incrementAndGet(), request, resolvedAuthorModel, callback,
                    AutoBlockSync.getForegroundActivity(), UI_CONFIRMING, now);
            OPERATIONS.put(key, operation);
            return operation;
        }
    }

    private static void transition(Operation operation, String state) {
        synchronized (LOCK) {
            Operation current = OPERATIONS.get(operation.request.operationKey());
            if (current != null && current.token == operation.token) {
                current.state = state;
                current.updatedAt = System.currentTimeMillis();
            }
        }
    }

    private static boolean isCurrent(Operation operation) {
        synchronized (LOCK) {
            Operation current = operation == null
                    ? null : OPERATIONS.get(operation.request.operationKey());
            return current != null && current.token == operation.token;
        }
    }

    private static boolean isCurrentWithState(Operation operation, String state) {
        synchronized (LOCK) {
            Operation current = operation == null
                    ? null : OPERATIONS.get(operation.request.operationKey());
            return current != null && current.token == operation.token
                    && state.equals(current.state);
        }
    }

    private static void remove(Operation operation) {
        synchronized (LOCK) {
            if (operation == null) {
                return;
            }
            Operation current = OPERATIONS.get(operation.request.operationKey());
            if (current != null && current.token == operation.token) {
                OPERATIONS.remove(operation.request.operationKey());
            }
        }
    }

    private static void pruneLocked(long now) {
        Iterator<Map.Entry<String, Operation>> iterator = OPERATIONS.entrySet().iterator();
        while (iterator.hasNext()) {
            Operation operation = iterator.next().getValue();
            long age = operation.updatedAt <= 0L ? Long.MAX_VALUE : now - operation.updatedAt;
            boolean terminal = UI_SUCCESS.equals(operation.state)
                    || UI_FAILED.equals(operation.state);
            boolean staleConfirmation = UI_CONFIRMING.equals(operation.state)
                    && age > CONFIRMATION_STALE_MS;
            if ((terminal && age > TERMINAL_STALE_MS) || staleConfirmation) {
                iterator.remove();
            }
        }
    }

    private static boolean removeOneTerminalLocked() {
        Iterator<Map.Entry<String, Operation>> iterator = OPERATIONS.entrySet().iterator();
        while (iterator.hasNext()) {
            Operation operation = iterator.next().getValue();
            if (UI_SUCCESS.equals(operation.state) || UI_FAILED.equals(operation.state)) {
                iterator.remove();
                return true;
            }
        }
        return false;
    }

    private static boolean targetMatches(Operation operation, String targetId) {
        return operation != null && operation.request.getAuthorId().equals(targetId);
    }

    private static boolean reportMatches(
            InlineBlockRequest blockRequest, ReportRequest reportRequest) {
        return blockRequest != null && blockRequest.isValid()
                && reportRequest != null && reportRequest.isValid()
                && blockRequest.getMediaKey().equals(reportRequest.getItemKey())
                && blockRequest.getAuthorId().equals(reportRequest.getProfileId());
    }

    private static boolean usableActivity(Activity activity) {
        return activity != null && !activity.isFinishing() && !activity.isDestroyed();
    }

    private static String safeStage(String value) {
        if (value == null || value.length() == 0) {
            return "unknown_failure";
        }
        StringBuilder clean = new StringBuilder();
        for (int i = 0; i < value.length() && clean.length() < 60; i++) {
            char c = value.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_' || c == '-') {
                clean.append(c);
            }
        }
        return clean.length() == 0 ? "unknown_failure" : clean.toString();
    }

    private static void showReportResult(Activity activity, ReportResult result) {
        if (!usableActivity(activity)) {
            return;
        }
        String message = result == null || result.message.length() == 0
                ? "The report could not be queued." : result.message;
        try {
            Toast.makeText(activity, message, Toast.LENGTH_LONG).show();
        } catch (Throwable ignored) {
            // Report persistence is authoritative; toast delivery is best effort.
        }
    }

    private static void safeQueued(
            InlineBlockUiCallback callback, InlineBlockRequest request) {
        if (callback != null) {
            try {
                callback.onQueued(request);
            } catch (Throwable ignored) {
                // Host rendering is optional and cannot change account state.
            }
        }
    }

    private static void safeStarted(
            InlineBlockUiCallback callback, InlineBlockRequest request) {
        if (callback != null) {
            try {
                callback.onStarted(request);
            } catch (Throwable ignored) {
                // Host rendering is optional and cannot change account state.
            }
        }
    }

    private static void safeSuccess(
            InlineBlockUiCallback callback, InlineBlockRequest request) {
        if (callback != null) {
            try {
                callback.onSuccess(request);
            } catch (Throwable ignored) {
                // Host rendering is optional and cannot change account state.
            }
        }
    }

    private static void safeFailure(
            InlineBlockUiCallback callback,
            InlineBlockRequest request,
            String stage) {
        if (callback != null) {
            try {
                callback.onFailure(request, safeStage(stage));
            } catch (Throwable ignored) {
                // Host rendering is optional and cannot change account state.
            }
        }
    }

    private static void safeCancelled(
            InlineBlockUiCallback callback, InlineBlockRequest request) {
        if (callback != null) {
            try {
                callback.onCancelled(request);
            } catch (Throwable ignored) {
                // Host rendering is optional and cannot change account state.
            }
        }
    }

    private static void safeDismiss(
            InlineBlockUiCallback callback, InlineBlockRequest request) {
        if (callback != null) {
            try {
                callback.onDismiss(request);
            } catch (Throwable ignored) {
                // Host rendering is optional and cannot change account state.
            }
        }
    }

    private static final class Operation {
        final long token;
        final InlineBlockRequest request;
        final Object resolvedAuthorModel;
        final InlineBlockUiCallback callback;
        final WeakReference<Activity> activityRef;
        volatile String state;
        volatile long updatedAt;

        Operation(
                long token,
                InlineBlockRequest request,
                Object resolvedAuthorModel,
                InlineBlockUiCallback callback,
                Activity activity,
                String state,
                long updatedAt) {
            this.token = token;
            this.request = request;
            this.resolvedAuthorModel = resolvedAuthorModel;
            this.callback = callback;
            this.activityRef = new WeakReference<Activity>(activity);
            this.state = state;
            this.updatedAt = updatedAt;
        }

        InlineBlockUiCallback callback() {
            return callback;
        }

        Activity activity() {
            return activityRef.get();
        }
    }
}
