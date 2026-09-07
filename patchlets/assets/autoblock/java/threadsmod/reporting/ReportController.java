package threadsmod.reporting;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;

import threadsmod.autoblock.AutoBlockSync;

/** Entry point for the explicit positive action in the combined inline modal. */
public final class ReportController {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private ReportController() {}

    /**
     * One-step report authority. Call this only from the combined modal's explicit
     * positive-action tap after it has collected and validated the reason. The
     * initiating Activity and viewer are immutable authority: a replacement
     * Activity or account may not silently re-scope an already-open modal.
     */
    public static void queueFromForeground(
            final Activity initiatingActivity,
            final String initiatingViewerId,
            final ReportRequest request,
            final String reason,
            final ReportResultCallback callback) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            deliver(callback, new ReportResult(
                    ReportResult.INVALID,
                    "",
                    "The report action must be confirmed from the foreground modal."));
            return;
        }
        if (initiatingActivity == null
                || initiatingActivity.isFinishing()
                || initiatingActivity.isDestroyed()
                || AutoBlockSync.getForegroundActivity() != initiatingActivity
                || !ReportValues.isNumericId(initiatingViewerId)
                || !initiatingViewerId.equals(AutoBlockSync.getCurrentViewer())
                || request == null || !request.isValidForNewQueue()
                || !ReportPayload.isReason(reason)) {
            deliver(callback, new ReportResult(
                    ReportResult.INVALID,
                    "",
                    "The report target, reason, or foreground activity is invalid."));
            return;
        }
        if (request.isViewer(initiatingViewerId)) {
            deliver(callback, new ReportResult(
                    ReportResult.SELF_TARGET,
                    "",
                    "You cannot report the active viewer."));
            return;
        }
        ReportClient.queueExplicit(
                initiatingActivity.getApplicationContext(),
                initiatingViewerId,
                request,
                reason,
                callback);
    }

    private static void deliver(ReportResultCallback callback, ReportResult result) {
        if (callback == null) {
            return;
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            callback.onResult(result);
            return;
        }
        final ReportResultCallback safeCallback = callback;
        final ReportResult safeResult = result;
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                safeCallback.onResult(safeResult);
            }
        });
    }
}
