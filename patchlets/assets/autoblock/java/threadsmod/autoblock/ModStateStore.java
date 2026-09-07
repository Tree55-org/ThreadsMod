package threadsmod.autoblock;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Bounded, viewer-scoped state shared by the mod's inline action and activity UI.
 *
 * This class deliberately stores only numeric Threads IDs, short display labels,
 * outcome metadata, and local timestamps. It never stores a Threads session,
 * cookie, access token, or server response body.
 */
public final class ModStateStore {
    public static final String STATE_QUEUED = "queued";
    public static final String STATE_RUNNING = "running";
    public static final String STATE_FAILED = "failed";
    public static final String STATE_ABANDONED = "abandoned";

    public static final String OUTCOME_BLOCKED = "blocked";
    public static final String OUTCOME_FAILED = "failed";
    public static final String OUTCOME_ABANDONED = "abandoned";

    public static final String SOURCE_INLINE = "inline";
    public static final String SOURCE_SIGNED_LIST = "signed_list";

    private static final String PREFS = "threadsmod_autoblock";
    /** Removed from old installs; a validated active viewer is process-memory only. */
    private static final String LEGACY_KEY_ACTIVE_VIEWER = "ui_active_viewer";
    private static final String KEY_ALSO_BLOCK_PROFILE = "ui_also_block_profile";
    private static final String KEY_RUNTIME_CODE = "ui_runtime_state_code";
    private static final String KEY_RUNTIME_AT = "ui_runtime_state_at";
    private static final String KEY_RUNTIME_VIEWER = "ui_runtime_state_viewer";

    private static final int MAX_QUEUE = 100;
    private static final int MAX_HISTORY = 200;
    private static final int MAX_ALERTS = 20;
    private static final int MAX_DONE_IDS = 5000;
    static final int MAX_COMPLETION_REVIEW_TARGETS = 200;
    private static final int MAX_JSON_CHARS = 96 * 1024;
    private static final long DAY_MS = 24L * 60L * 60L * 1000L;
    private static final long HOUR_MS = 60L * 60L * 1000L;

    private static volatile ManualQueueListener queueListener;
    private static String activeViewer = "";
    private static boolean activeViewerSuppressed = true;

    private ModStateStore() {}

    /** Runtime hook used to drain manual work through the serialized block scheduler. */
    public interface ManualQueueListener {
        void onManualQueueChanged(Activity activity, String viewerId);
    }

    public static final class QueueItem {
        public final String targetId;
        public final String label;
        public final String source;
        public final String state;
        public final String error;
        public final long createdAt;
        public final long updatedAt;
        public final int attempts;

        QueueItem(JSONObject value) {
            targetId = safeId(value.optString("target_id", ""));
            label = cleanText(value.optString("label", ""), 80);
            source = cleanToken(value.optString("source", SOURCE_INLINE), 32);
            state = cleanToken(value.optString("state", STATE_QUEUED), 24);
            error = cleanText(value.optString("error", ""), 120);
            createdAt = saneTime(value.optLong("created_at", 0L));
            updatedAt = saneTime(value.optLong("updated_at", createdAt));
            attempts = Math.max(0, Math.min(999, value.optInt("attempts", 0)));
        }

        JSONObject toJson() {
            JSONObject value = new JSONObject();
            try {
                value.put("target_id", targetId);
                value.put("label", label);
                value.put("source", source);
                value.put("state", state);
                value.put("error", error);
                value.put("created_at", createdAt);
                value.put("updated_at", updatedAt);
                value.put("attempts", attempts);
            } catch (Throwable ignored) {
                // JSONObject backed by memory should not reject these primitives.
            }
            return value;
        }
    }

    /** Strict viewer-scoped quarantine snapshot shared with the automatic selector. */
    static final class CompletionReviewState {
        final boolean valid;
        final boolean full;
        final Set<String> targets;

        private CompletionReviewState(boolean valid, boolean full, Set<String> targets) {
            this.valid = valid;
            this.full = full;
            this.targets = targets;
        }

        static CompletionReviewState valid(Set<String> targets) {
            return new CompletionReviewState(
                    true, targets.size() >= MAX_COMPLETION_REVIEW_TARGETS, targets);
        }

        static CompletionReviewState invalid() {
            return new CompletionReviewState(false, true, new HashSet<String>());
        }
    }

    public static final class HistoryItem {
        public final String targetId;
        public final String label;
        public final String source;
        public final String outcome;
        public final String detail;
        public final long timestamp;

        HistoryItem(JSONObject value) {
            targetId = safeId(value.optString("target_id", ""));
            label = cleanText(value.optString("label", ""), 80);
            source = cleanToken(value.optString("source", SOURCE_INLINE), 32);
            outcome = cleanToken(value.optString("outcome", ""), 24);
            detail = cleanText(value.optString("detail", ""), 120);
            timestamp = saneTime(value.optLong("timestamp", 0L));
        }

        JSONObject toJson() {
            JSONObject value = new JSONObject();
            try {
                value.put("target_id", targetId);
                value.put("label", label);
                value.put("source", source);
                value.put("outcome", outcome);
                value.put("detail", detail);
                value.put("timestamp", timestamp);
            } catch (Throwable ignored) {
                // JSONObject backed by memory should not reject these primitives.
            }
            return value;
        }
    }

    public static final class AlertItem {
        public final String code;
        public final String message;
        public final long timestamp;

        AlertItem(JSONObject value) {
            code = cleanToken(value.optString("code", "unknown"), 48);
            message = cleanText(value.optString("message", ""), 240);
            timestamp = saneTime(value.optLong("timestamp", 0L));
        }

        JSONObject toJson() {
            JSONObject value = new JSONObject();
            try {
                value.put("code", code);
                value.put("message", message);
                value.put("timestamp", timestamp);
            } catch (Throwable ignored) {
                // JSONObject backed by memory should not reject these primitives.
            }
            return value;
        }
    }

    public static final class Snapshot {
        public final String viewerId;
        public final String status;
        public final String runtimeCode;
        public final long runtimeAt;
        public final int blocked;
        public final int queued;
        public final int lastHour;
        public final int today;
        public final int failedOrAbandoned;
        public final int blocklistSize;
        public final long listFetchedAt;
        public final String listUpdatedAt;
        public final List<QueueItem> queue;
        public final List<HistoryItem> history;
        public final List<AlertItem> alerts;

        Snapshot(
                String viewerId,
                String status,
                String runtimeCode,
                long runtimeAt,
                int blocked,
                int queued,
                int lastHour,
                int today,
                int failedOrAbandoned,
                int blocklistSize,
                long listFetchedAt,
                String listUpdatedAt,
                List<QueueItem> queue,
                List<HistoryItem> history,
                List<AlertItem> alerts) {
            this.viewerId = viewerId;
            this.status = status;
            this.runtimeCode = runtimeCode;
            this.runtimeAt = runtimeAt;
            this.blocked = blocked;
            this.queued = queued;
            this.lastHour = lastHour;
            this.today = today;
            this.failedOrAbandoned = failedOrAbandoned;
            this.blocklistSize = blocklistSize;
            this.listFetchedAt = listFetchedAt;
            this.listUpdatedAt = listUpdatedAt;
            this.queue = Collections.unmodifiableList(queue);
            this.history = Collections.unmodifiableList(history);
            this.alerts = Collections.unmodifiableList(alerts);
        }

        public AlertItem latestAlert() {
            return alerts.isEmpty() ? null : alerts.get(0);
        }
    }

    public static void setManualQueueListener(ManualQueueListener listener) {
        queueListener = listener;
    }

    public static void notifyManualQueueChanged(Activity activity) {
        if (activity == null) {
            return;
        }
        ManualQueueListener listener = queueListener;
        String viewer = getActiveViewer(activity);
        if (listener != null && isViewerId(viewer)) {
            try {
                listener.onManualQueueChanged(activity, viewer);
            } catch (Throwable ignored) {
                // Optional UI notification must never make the host Activity fail.
            }
        }
    }

    /** Publishes only a viewer just extracted from the live foreground Threads session. */
    static synchronized boolean setValidatedActiveViewer(Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return false;
        }
        if (!removeLegacyActiveViewer(context)) {
            activeViewer = "";
            activeViewerSuppressed = true;
            return false;
        }
        activeViewer = viewerId;
        activeViewerSuppressed = false;
        return true;
    }

    /** Hides the previous account scope and removes the retired raw-viewer preference. */
    public static synchronized void clearActiveViewer(Context context) {
        activeViewer = "";
        activeViewerSuppressed = true;
        if (context != null) {
            removeLegacyActiveViewer(context);
        }
    }

    public static synchronized String getActiveViewer(Context context) {
        if (context == null || !removeLegacyActiveViewer(context)) {
            activeViewer = "";
            activeViewerSuppressed = true;
            return "";
        }
        if (activeViewerSuppressed) {
            return "";
        }
        String value = activeViewer;
        return isViewerId(value) ? value : "";
    }

    private static boolean removeLegacyActiveViewer(Context context) {
        try {
            SharedPreferences preferences = prefs(context);
            if (!preferences.getAll().containsKey(LEGACY_KEY_ACTIVE_VIEWER)) {
                return true;
            }
            return preferences.edit().remove(LEGACY_KEY_ACTIVE_VIEWER).commit();
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static boolean isAlsoBlockProfileEnabled(Context context) {
        return context != null && prefs(context).getBoolean(KEY_ALSO_BLOCK_PROFILE, true);
    }

    public static boolean setAlsoBlockProfileEnabled(Context context, boolean enabled) {
        return context != null && prefs(context).edit()
                .putBoolean(KEY_ALSO_BLOCK_PROFILE, enabled)
                .commit();
    }

    /** Adds or retries a manual target without evicting or resetting active work. */
    public static synchronized boolean enqueueManual(
            Context context,
            String viewerId,
            String targetId,
            String label,
            String source) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)
                || viewerId.equals(targetId)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        Set<String> done = readDoneIds(p, viewerId);
        if (done == null || done.contains(targetId)) {
            return false;
        }

        long now = System.currentTimeMillis();
        ArrayList<QueueItem> queue = readQueue(p, viewerId);
        QueueItem existing = null;
        for (QueueItem item : queue) {
            if (item.targetId.equals(targetId)) {
                existing = item;
                break;
            }
        }
        if (existing == null && queue.size() >= MAX_QUEUE) {
            return false;
        }
        if (existing != null && (STATE_QUEUED.equals(existing.state)
                || STATE_RUNNING.equals(existing.state))) {
            return true;
        }
        JSONArray encoded = new JSONArray();
        boolean replaced = false;
        for (QueueItem item : queue) {
            if (item.targetId.equals(targetId)) {
                encoded.put(queueJson(
                        targetId,
                        cleanText(label, 80).length() == 0 ? item.label : cleanText(label, 80),
                        cleanToken(source, 32),
                        STATE_QUEUED,
                        "",
                        item.createdAt > 0L ? item.createdAt : now,
                        now,
                        item.attempts));
                replaced = true;
            } else {
                encoded.put(item.toJson());
            }
        }
        if (!replaced) {
            JSONArray withNewFirst = new JSONArray();
            withNewFirst.put(queueJson(
                    targetId,
                    cleanText(label, 80),
                    cleanToken(source, 32),
                    STATE_QUEUED,
                    "",
                    now,
                    now,
                    0));
            for (int i = 0; i < encoded.length(); i++) {
                withNewFirst.put(encoded.opt(i));
            }
            encoded = withNewFirst;
        }
        return p.edit().putString(queueKey(viewerId), encoded.toString()).commit();
    }

    public static synchronized QueueItem nextQueued(Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return null;
        }
        for (QueueItem item : readQueue(prefs(context), viewerId)) {
            if (STATE_QUEUED.equals(item.state)) {
                return item;
            }
        }
        return null;
    }

    /**
     * Converts process-interrupted native work to an explicit, user-retryable state.
     * It never retries automatically because the account mutation may have reached
     * Threads before the process died, even though no success callback was persisted.
     */
    public static synchronized int recoverInterruptedManual(
            Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return 0;
        }
        SharedPreferences p = prefs(context);
        ArrayList<QueueItem> queue = readQueue(p, viewerId);
        JSONArray encoded = new JSONArray();
        ArrayList<QueueItem> interrupted = new ArrayList<QueueItem>();
        long now = System.currentTimeMillis();
        String detail = "Interrupted before Threads confirmed completion; verify account state before retry.";
        for (QueueItem item : queue) {
            if (STATE_RUNNING.equals(item.state)) {
                encoded.put(queueJson(
                        item.targetId,
                        item.label,
                        item.source,
                        STATE_ABANDONED,
                        detail,
                        item.createdAt,
                        now,
                        item.attempts));
                interrupted.add(item);
            } else {
                encoded.put(item.toJson());
            }
        }
        if (interrupted.isEmpty()
                || !p.edit().putString(queueKey(viewerId), encoded.toString()).commit()) {
            return 0;
        }
        for (QueueItem item : interrupted) {
            appendHistory(context, viewerId, item.targetId, item.label, item.source,
                    OUTCOME_ABANDONED, detail);
        }
        addAlert(context, viewerId, "manual_block_interrupted",
                interrupted.size() + " inline block(s) need review before retry.");
        return interrupted.size();
    }

    public static synchronized boolean markManualStarted(
            Context context, String viewerId, String targetId) {
        return updateQueueState(
                context, viewerId, targetId, STATE_RUNNING, "", true, false);
    }

    public static synchronized boolean markManualFailed(
            Context context,
            String viewerId,
            String targetId,
            BlockDiagnostic diagnostic) {
        if (diagnostic == null) {
            return false;
        }
        String detail = diagnostic.detail();
        boolean updated = updateQueueState(
                context, viewerId, targetId, STATE_FAILED, detail, false, false);
        if (updated) {
            appendHistory(context, viewerId, targetId, "", SOURCE_INLINE,
                    OUTCOME_FAILED, detail);
        }
        return updated;
    }

    public static synchronized boolean markManualAbandoned(
            Context context, String viewerId, String targetId, String detail) {
        boolean updated = updateQueueState(
                context, viewerId, targetId, STATE_ABANDONED, detail, false, false);
        if (updated) {
            appendHistory(context, viewerId, targetId, "", SOURCE_INLINE,
                    OUTCOME_ABANDONED, detail);
        }
        return updated;
    }

    public static synchronized boolean markManualBlocked(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        String label = "";
        ArrayList<QueueItem> queue = readQueue(p, viewerId);
        JSONArray remaining = new JSONArray();
        for (QueueItem item : queue) {
            if (item.targetId.equals(targetId)) {
                label = item.label;
            } else if (remaining.length() < MAX_QUEUE) {
                remaining.put(item.toJson());
            }
        }
        HashSet<String> done = readDoneIds(p, viewerId);
        if (done == null
                || (!done.contains(targetId) && done.size() >= MAX_DONE_IDS)) {
            return false;
        }
        done.add(targetId);
        boolean saved = p.edit()
                .putString(queueKey(viewerId), remaining.toString())
                .putStringSet(doneKey(viewerId), done)
                .commit();
        if (saved) {
            appendHistory(context, viewerId, targetId, label, SOURCE_INLINE,
                    OUTCOME_BLOCKED, "");
        }
        return saved;
    }

    public static synchronized boolean retryManual(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)) {
            return false;
        }
        try {
        SharedPreferences p = prefs(context);
        CompletionReviewState review = readCompletionReview(p, viewerId);
        if (!review.valid) {
            return false;
        }
        ArrayList<QueueItem> queue = readQueue(p, viewerId);
        JSONArray encoded = new JSONArray();
        boolean found = false;
        long now = System.currentTimeMillis();
        for (QueueItem item : queue) {
            if (item.targetId.equals(targetId)
                    && (STATE_FAILED.equals(item.state)
                    || STATE_ABANDONED.equals(item.state))) {
                encoded.put(queueJson(
                        item.targetId,
                        item.label,
                        item.source,
                        STATE_QUEUED,
                        "",
                        item.createdAt,
                        now,
                        item.attempts));
                found = true;
            } else {
                encoded.put(item.toJson());
            }
        }
        if (!found) {
            return false;
        }
        HashSet<String> remainingReview = new HashSet<String>(review.targets);
        remainingReview.remove(targetId);
        SharedPreferences.Editor editor = p.edit()
                .putString(queueKey(viewerId), encoded.toString());
        putCompletionReview(editor, viewerId, remainingReview);
        if (!editor.commit()) {
            return false;
        }
        HashSet<String> retried = new HashSet<String>();
        retried.add(targetId);
        AutoBlockSync.clearLocalCompletionReviewAfterRetry(viewerId, retried);
        return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static synchronized int retryAllManual(Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return 0;
        }
        try {
        SharedPreferences p = prefs(context);
        CompletionReviewState review = readCompletionReview(p, viewerId);
        if (!review.valid) {
            return 0;
        }
        ArrayList<QueueItem> queue = readQueue(p, viewerId);
        JSONArray encoded = new JSONArray();
        HashSet<String> retried = new HashSet<String>();
        int changed = 0;
        long now = System.currentTimeMillis();
        for (QueueItem item : queue) {
            if (STATE_FAILED.equals(item.state) || STATE_ABANDONED.equals(item.state)) {
                encoded.put(queueJson(item.targetId, item.label, item.source,
                        STATE_QUEUED, "", item.createdAt, now, item.attempts));
                retried.add(item.targetId);
                changed++;
            } else {
                encoded.put(item.toJson());
            }
        }
        if (changed > 0) {
            HashSet<String> remainingReview = new HashSet<String>(review.targets);
            remainingReview.removeAll(retried);
            SharedPreferences.Editor editor = p.edit()
                    .putString(queueKey(viewerId), encoded.toString());
            putCompletionReview(editor, viewerId, remainingReview);
            if (!editor.commit()) {
                return 0;
            }
            AutoBlockSync.clearLocalCompletionReviewAfterRetry(viewerId, retried);
        }
        return changed;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    /**
     * Durably quarantines a target after confirmed success could not be recorded or
     * after a dispatched mutation ended without a terminal callback. Corrupt or
     * oversized state is never treated as empty.
     */
    static synchronized boolean quarantineCompletionReview(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)
                || viewerId.equals(targetId)) {
            return false;
        }
        try {
        SharedPreferences p = prefs(context);
        CompletionReviewState review = readCompletionReview(p, viewerId);
        if (!review.valid) {
            return false;
        }
        HashSet<String> targets = new HashSet<String>(review.targets);
        if (!targets.contains(targetId)
                && targets.size() >= MAX_COMPLETION_REVIEW_TARGETS) {
            return false;
        }
        targets.add(targetId);
        SharedPreferences.Editor editor = p.edit();
        putCompletionReview(editor, viewerId, targets);
        return editor.commit();
        } catch (Throwable ignored) {
            return false;
        }
    }

    static synchronized CompletionReviewState completionReviewState(
            Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return CompletionReviewState.invalid();
        }
        try {
            return readCompletionReview(prefs(context), viewerId);
        } catch (Throwable ignored) {
            return CompletionReviewState.invalid();
        }
    }

    public static synchronized void recordAutomaticBlocked(
            Context context, String viewerId, String targetId) {
        appendHistory(context, viewerId, targetId, "", SOURCE_SIGNED_LIST,
                OUTCOME_BLOCKED, "");
    }

    public static synchronized void recordAutomaticFailure(
            Context context,
            String viewerId,
            String targetId,
            BlockDiagnostic diagnostic) {
        if (diagnostic == null) {
            return;
        }
        appendHistory(context, viewerId, targetId, "", SOURCE_SIGNED_LIST,
                OUTCOME_FAILED, diagnostic.detail());
    }

    /**
     * Persists the sole passive mutation identity before rate reservation and bridge dispatch.
     * An existing or malformed value is never overwritten.
     */
    public static synchronized boolean markPassiveRunning(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)
                || viewerId.equals(targetId)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        String key = passiveRunningKey(viewerId);
        try {
            String existing = p.getString(key, "");
            if (existing.length() != 0) {
                return false;
            }
            long now = System.currentTimeMillis();
            return p.edit().putString(key, targetId + "," + now).commit();
        } catch (Throwable ignored) {
            return false;
        }
    }

    /** Removes only the exact running identity after a terminal callback was handled. */
    public static synchronized boolean clearPassiveRunning(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        String key = passiveRunningKey(viewerId);
        try {
            String raw = p.getString(key, "");
            String[] parts = raw.split(",", -1);
            if (parts.length != 2 || !targetId.equals(parts[0])
                    || !isSaneStoredTime(parts[1])) {
                return false;
            }
            return p.edit().remove(key).commit();
        } catch (Throwable ignored) {
            return false;
        }
    }

    /** True only when no prior passive dispatch identity needs recovery or review. */
    public static synchronized boolean isPassiveRunningClear(
            Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return false;
        }
        try {
            return prefs(context).getString(passiveRunningKey(viewerId), "").length() == 0;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /**
     * Atomically converts process-interrupted passive work into completion-review quarantine.
     * Returns 1 when recovered, 0 when empty, and -1 for corrupt/full/uncommitted state.
     */
    public static synchronized int recoverInterruptedPassive(
            Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return -1;
        }
        SharedPreferences p = prefs(context);
        String key = passiveRunningKey(viewerId);
        try {
            String raw = p.getString(key, "");
            if (raw.length() == 0) {
                return 0;
            }
            String[] parts = raw.split(",", -1);
            if (parts.length != 2 || !isTargetId(parts[0])
                    || viewerId.equals(parts[0]) || !isSaneStoredTime(parts[1])) {
                return -1;
            }
            String targetId = parts[0];
            CompletionReviewState review = readCompletionReview(p, viewerId);
            if (!review.valid || (!review.targets.contains(targetId) && review.full)) {
                return -1;
            }
            HashSet<String> targets = new HashSet<String>(review.targets);
            targets.add(targetId);
            SharedPreferences.Editor editor = p.edit().remove(key);
            putCompletionReview(editor, viewerId, targets);
            if (!editor.commit()) {
                return -1;
            }
            String detail = "Interrupted passive mutation needs account-state review before retry.";
            appendHistory(context, viewerId, targetId, "", SOURCE_SIGNED_LIST,
                    OUTCOME_ABANDONED, detail);
            addAlert(context, viewerId, "passive_block_interrupted", detail);
            return 1;
        } catch (Throwable ignored) {
            return -1;
        }
    }

    /** Stores exactly one viewer-scoped alert and runtime code for a safe diagnostic. */
    public static synchronized void recordFailureDiagnostic(
            Context context, String viewerId, BlockDiagnostic diagnostic) {
        if (context == null || !isViewerId(viewerId) || diagnostic == null) {
            return;
        }
        long now = System.currentTimeMillis();
        prefs(context).edit()
                .putString(KEY_RUNTIME_CODE, cleanToken(diagnostic.code(), 48))
                .putLong(KEY_RUNTIME_AT, now)
                .putString(KEY_RUNTIME_VIEWER, viewerId)
                .apply();
        addAlert(context, viewerId, diagnostic.code(), diagnostic.status());
    }

    public static synchronized void recordRuntimeState(
            Context context,
            String viewerId,
            String code,
            String message,
            boolean failure) {
        if (context == null) {
            return;
        }
        String safeViewer = isViewerId(viewerId) ? viewerId : "";
        String safeCode = cleanToken(code, 48);
        long now = System.currentTimeMillis();
        prefs(context).edit()
                .putString(KEY_RUNTIME_CODE, safeCode)
                .putLong(KEY_RUNTIME_AT, now)
                .putString(KEY_RUNTIME_VIEWER, safeViewer)
                .apply();
        if (failure && isViewerId(safeViewer)) {
            addAlert(context, safeViewer, safeCode, message);
        }
    }

    public static synchronized Snapshot snapshot(Context context) {
        String viewer = getActiveViewer(context);
        return snapshot(context, viewer);
    }

    public static synchronized Snapshot snapshot(Context context, String viewerId) {
        if (context == null) {
            return emptySnapshot();
        }
        SharedPreferences p = prefs(context);
        String viewer = isViewerId(viewerId) ? viewerId : "";
        ArrayList<QueueItem> queue = isViewerId(viewer)
                ? readQueue(p, viewer) : new ArrayList<QueueItem>();
        ArrayList<HistoryItem> history = isViewerId(viewer)
                ? readHistory(p, viewer) : new ArrayList<HistoryItem>();
        ArrayList<AlertItem> alerts = isViewerId(viewer)
                ? readAlerts(p, viewer) : new ArrayList<AlertItem>();

        long now = System.currentTimeMillis();
        int queued = 0;
        for (QueueItem item : queue) {
            if (STATE_QUEUED.equals(item.state) || STATE_RUNNING.equals(item.state)) {
                queued++;
            }
        }
        int failed = 0;
        for (HistoryItem item : history) {
            if (OUTCOME_FAILED.equals(item.outcome)
                    || OUTCOME_ABANDONED.equals(item.outcome)) {
                failed++;
            }
        }
        int lastHour = 0;
        int today = 0;
        if (isViewerId(viewer)) {
            for (Long event : readAttemptTimes(p.getString(attemptsKey(viewer), ""), now)) {
                today++;
                if (event.longValue() > now - HOUR_MS) {
                    lastHour++;
                }
            }
        }
        Set<String> done = isViewerId(viewer) ? readDoneIds(p, viewer) : null;
        int blocked = done == null ? 0 : done.size();
        BlocklistStore.Snapshot blocklist = BlocklistStore.snapshot(context);
        int targetCount = blocklist.valid ? blocklist.targetCount : 0;
        String status = cleanText(AutoBlockSync.getStatus(context, viewer), 240);
        String runtimeCode = cleanToken(p.getString(KEY_RUNTIME_CODE, "idle"), 48);
        long runtimeAt = saneTime(p.getLong(KEY_RUNTIME_AT, 0L));
        String runtimeViewer = p.getString(KEY_RUNTIME_VIEWER, "");
        if (isViewerId(viewer) && isViewerId(runtimeViewer) && !viewer.equals(runtimeViewer)) {
            runtimeCode = "idle";
            runtimeAt = 0L;
        }
        return new Snapshot(
                viewer,
                status,
                runtimeCode,
                runtimeAt,
                blocked,
                queued,
                lastHour,
                today,
                failed,
                targetCount,
                blocklist.valid ? saneTime(blocklist.fetchedAtMs) : 0L,
                blocklist.valid ? cleanText(blocklist.verifiedUpdatedAt, 80) : "",
                queue,
                history,
                alerts);
    }

    public static void clearAlerts(Context context, String viewerId) {
        if (context != null && isViewerId(viewerId)) {
            prefs(context).edit().remove(alertsKey(viewerId)).apply();
        }
    }

    private static Snapshot emptySnapshot() {
        return new Snapshot("", "No runtime status yet.", "idle", 0L,
                0, 0, 0, 0, 0, 0, 0L, "",
                new ArrayList<QueueItem>(),
                new ArrayList<HistoryItem>(),
                new ArrayList<AlertItem>());
    }

    private static boolean updateQueueState(
            Context context,
            String viewerId,
            String targetId,
            String state,
            String error,
            boolean incrementAttempts,
            boolean onlyRetryable) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        ArrayList<QueueItem> queue = readQueue(p, viewerId);
        JSONArray encoded = new JSONArray();
        boolean found = false;
        long now = System.currentTimeMillis();
        for (QueueItem item : queue) {
            if (item.targetId.equals(targetId)
                    && (!onlyRetryable || STATE_FAILED.equals(item.state)
                    || STATE_ABANDONED.equals(item.state))) {
                encoded.put(queueJson(
                        item.targetId,
                        item.label,
                        item.source,
                        state,
                        cleanText(error, 120),
                        item.createdAt,
                        now,
                        item.attempts + (incrementAttempts ? 1 : 0)));
                found = true;
            } else {
                encoded.put(item.toJson());
            }
        }
        return found && p.edit().putString(queueKey(viewerId), encoded.toString()).commit();
    }

    private static void appendHistory(
            Context context,
            String viewerId,
            String targetId,
            String label,
            String source,
            String outcome,
            String detail) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)) {
            return;
        }
        SharedPreferences p = prefs(context);
        ArrayList<HistoryItem> old = readHistory(p, viewerId);
        JSONArray encoded = new JSONArray();
        encoded.put(historyJson(targetId, label, source, outcome, detail,
                System.currentTimeMillis()));
        for (HistoryItem item : old) {
            if (encoded.length() >= MAX_HISTORY) {
                break;
            }
            encoded.put(item.toJson());
        }
        p.edit().putString(historyKey(viewerId), encoded.toString()).apply();
    }

    private static void addAlert(
            Context context, String viewerId, String code, String message) {
        if (context == null || !isViewerId(viewerId)) {
            return;
        }
        SharedPreferences p = prefs(context);
        ArrayList<AlertItem> old = readAlerts(p, viewerId);
        JSONArray encoded = new JSONArray();
        encoded.put(alertJson(code, message, System.currentTimeMillis()));
        for (AlertItem item : old) {
            if (encoded.length() >= MAX_ALERTS) {
                break;
            }
            encoded.put(item.toJson());
        }
        p.edit().putString(alertsKey(viewerId), encoded.toString()).apply();
    }

    private static ArrayList<QueueItem> readQueue(SharedPreferences p, String viewerId) {
        ArrayList<QueueItem> out = new ArrayList<QueueItem>();
        JSONArray values = readArray(p.getString(queueKey(viewerId), "[]"));
        for (int i = 0; i < values.length() && out.size() < MAX_QUEUE; i++) {
            JSONObject value = values.optJSONObject(i);
            if (value == null) {
                continue;
            }
            QueueItem item = new QueueItem(value);
            if (isTargetId(item.targetId) && isQueueState(item.state)) {
                out.add(item);
            }
        }
        return out;
    }

    private static CompletionReviewState readCompletionReview(
            SharedPreferences p, String viewerId) {
        if (p == null || !isViewerId(viewerId)) {
            return CompletionReviewState.invalid();
        }
        try {
            String key = completionReviewKey(viewerId);
            Map<String, ?> values = p.getAll();
            if (!values.containsKey(key)) {
                return CompletionReviewState.valid(new HashSet<String>());
            }
            Object raw = values.get(key);
            if (!(raw instanceof Set<?>)) {
                return CompletionReviewState.invalid();
            }
            Set<?> stored = (Set<?>) raw;
            if (stored.size() > MAX_COMPLETION_REVIEW_TARGETS) {
                return CompletionReviewState.invalid();
            }
            HashSet<String> targets = new HashSet<String>();
            for (Object value : stored) {
                if (!(value instanceof String)) {
                    return CompletionReviewState.invalid();
                }
                String target = (String) value;
                if (!isTargetId(target) || viewerId.equals(target)) {
                    return CompletionReviewState.invalid();
                }
                targets.add(target);
            }
            return CompletionReviewState.valid(targets);
        } catch (Throwable ignored) {
            return CompletionReviewState.invalid();
        }
    }

    private static void putCompletionReview(
            SharedPreferences.Editor editor, String viewerId, Set<String> targets) {
        if (targets == null || targets.isEmpty()) {
            editor.remove(completionReviewKey(viewerId));
        } else {
            editor.putStringSet(
                    completionReviewKey(viewerId), new HashSet<String>(targets));
        }
    }

    private static ArrayList<HistoryItem> readHistory(SharedPreferences p, String viewerId) {
        ArrayList<HistoryItem> out = new ArrayList<HistoryItem>();
        JSONArray values = readArray(p.getString(historyKey(viewerId), "[]"));
        for (int i = 0; i < values.length() && out.size() < MAX_HISTORY; i++) {
            JSONObject value = values.optJSONObject(i);
            if (value == null) {
                continue;
            }
            HistoryItem item = new HistoryItem(value);
            if (isTargetId(item.targetId) && isOutcome(item.outcome)) {
                out.add(item);
            }
        }
        return out;
    }

    private static ArrayList<AlertItem> readAlerts(SharedPreferences p, String viewerId) {
        ArrayList<AlertItem> out = new ArrayList<AlertItem>();
        JSONArray values = readArray(p.getString(alertsKey(viewerId), "[]"));
        for (int i = 0; i < values.length() && out.size() < MAX_ALERTS; i++) {
            JSONObject value = values.optJSONObject(i);
            if (value != null) {
                AlertItem item = new AlertItem(value);
                if (item.message.length() > 0) {
                    out.add(item);
                }
            }
        }
        return out;
    }

    private static JSONArray readArray(String raw) {
        if (raw == null || raw.length() == 0 || raw.length() > MAX_JSON_CHARS) {
            return new JSONArray();
        }
        try {
            return new JSONArray(raw);
        } catch (Throwable ignored) {
            return new JSONArray();
        }
    }

    /**
     * Returns a defensive viewer-scoped completed-target snapshot. A null result means the
     * persisted value is corrupt or over its fixed bound and callers must fail closed.
     */
    static synchronized Set<String> doneIdsForScheduler(
            Context context, String viewerId) {
        if (context == null || !isViewerId(viewerId)) {
            return null;
        }
        return readDoneIds(prefs(context), viewerId);
    }

    /**
     * True only when the viewer's valid completed-target set already records this target. A
     * corrupt or oversized set answers false so the caller still fails closed at enqueue time.
     */
    static synchronized boolean isCompletedTarget(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)) {
            return false;
        }
        HashSet<String> done = readDoneIds(prefs(context), viewerId);
        return done != null && done.contains(targetId);
    }

    /** Atomically appends an automatic completion without granting capacity on corrupt state. */
    static synchronized boolean markAutomaticDone(
            Context context, String viewerId, String targetId) {
        if (context == null || !isViewerId(viewerId) || !isTargetId(targetId)
                || viewerId.equals(targetId)) {
            return false;
        }
        SharedPreferences p = prefs(context);
        HashSet<String> done = readDoneIds(p, viewerId);
        if (done == null
                || (!done.contains(targetId) && done.size() >= MAX_DONE_IDS)) {
            return false;
        }
        done.add(targetId);
        return p.edit().putStringSet(doneKey(viewerId), done).commit();
    }

    /** Reads the raw preference type first so a type-confused StringSet cannot crash callers. */
    private static HashSet<String> readDoneIds(
            SharedPreferences preferences, String viewerId) {
        if (preferences == null || !isViewerId(viewerId)) {
            return null;
        }
        try {
            Map<String, ?> values = preferences.getAll();
            String key = doneKey(viewerId);
            if (values == null) {
                return null;
            }
            if (!values.containsKey(key)) {
                return new HashSet<String>();
            }
            Object raw = values.get(key);
            if (!(raw instanceof Set<?>)) {
                return null;
            }
            Set<?> stored = (Set<?>) raw;
            if (stored.size() > MAX_DONE_IDS) {
                return null;
            }
            HashSet<String> done = new HashSet<String>();
            for (Object value : stored) {
                if (!(value instanceof String)) {
                    return null;
                }
                String targetId = (String) value;
                if (!isTargetId(targetId) || viewerId.equals(targetId)) {
                    return null;
                }
                done.add(targetId);
            }
            return done.size() == stored.size() ? done : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static List<Long> readAttemptTimes(String raw, long now) {
        ArrayList<Long> out = new ArrayList<Long>();
        if (raw == null || raw.length() == 0 || raw.length() > 4096) {
            return out;
        }
        String[] parts = raw.split(",");
        for (String part : parts) {
            try {
                long value = Long.parseLong(part);
                if (value <= now && value > now - DAY_MS) {
                    out.add(Long.valueOf(value));
                }
            } catch (Throwable ignored) {
                // Corrupt local counters never become successful activity.
            }
        }
        return out;
    }

    private static JSONObject queueJson(
            String targetId,
            String label,
            String source,
            String state,
            String error,
            long createdAt,
            long updatedAt,
            int attempts) {
        JSONObject value = new JSONObject();
        try {
            value.put("target_id", safeId(targetId));
            value.put("label", cleanText(label, 80));
            value.put("source", cleanToken(source, 32));
            value.put("state", cleanToken(state, 24));
            value.put("error", cleanText(error, 120));
            value.put("created_at", saneTime(createdAt));
            value.put("updated_at", saneTime(updatedAt));
            value.put("attempts", Math.max(0, Math.min(999, attempts)));
        } catch (Throwable ignored) {
            // JSONObject backed by memory should not reject these primitives.
        }
        return value;
    }

    private static JSONObject historyJson(
            String targetId,
            String label,
            String source,
            String outcome,
            String detail,
            long timestamp) {
        JSONObject value = new JSONObject();
        try {
            value.put("target_id", safeId(targetId));
            value.put("label", cleanText(label, 80));
            value.put("source", cleanToken(source, 32));
            value.put("outcome", cleanToken(outcome, 24));
            value.put("detail", cleanText(detail, 120));
            value.put("timestamp", saneTime(timestamp));
        } catch (Throwable ignored) {
            // JSONObject backed by memory should not reject these primitives.
        }
        return value;
    }

    private static JSONObject alertJson(String code, String message, long timestamp) {
        JSONObject value = new JSONObject();
        try {
            value.put("code", cleanToken(code, 48));
            value.put("message", cleanText(message, 240));
            value.put("timestamp", saneTime(timestamp));
        } catch (Throwable ignored) {
            // JSONObject backed by memory should not reject these primitives.
        }
        return value;
    }

    private static String cleanText(String value, int maxLength) {
        if (value == null) {
            return "";
        }
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < value.length() && out.length() < maxLength; i++) {
            char c = value.charAt(i);
            if (c >= 32 && c != 127) {
                out.append(c);
            }
        }
        return out.toString().trim();
    }

    private static String cleanToken(String value, int maxLength) {
        if (value == null) {
            return "";
        }
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < value.length() && out.length() < maxLength; i++) {
            char c = value.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_' || c == '-') {
                out.append(c);
            }
        }
        return out.toString();
    }

    private static String safeId(String value) {
        return isTargetId(value) ? value : "";
    }

    private static boolean isViewerId(String value) {
        return isTargetId(value);
    }

    private static boolean isTargetId(String value) {
        if (value == null || value.length() < 4 || value.length() > 24
                || value.charAt(0) == '0') {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        return true;
    }

    private static boolean isQueueState(String value) {
        return STATE_QUEUED.equals(value) || STATE_RUNNING.equals(value)
                || STATE_FAILED.equals(value) || STATE_ABANDONED.equals(value);
    }

    private static boolean isOutcome(String value) {
        return OUTCOME_BLOCKED.equals(value) || OUTCOME_FAILED.equals(value)
                || OUTCOME_ABANDONED.equals(value);
    }

    private static long saneTime(long value) {
        long now = System.currentTimeMillis();
        return value > 0L && value <= now + DAY_MS ? value : 0L;
    }

    private static boolean isSaneStoredTime(String value) {
        if (value == null || value.length() == 0 || value.length() > 19) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        try {
            return saneTime(Long.parseLong(value)) > 0L;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static String queueKey(String viewerId) {
        return "ui_manual_queue_threads_" + viewerId;
    }

    private static String historyKey(String viewerId) {
        return "ui_history_threads_" + viewerId;
    }

    private static String alertsKey(String viewerId) {
        return "ui_alerts_threads_" + viewerId;
    }

    private static String doneKey(String viewerId) {
        return "done_threads_" + viewerId;
    }

    private static String attemptsKey(String viewerId) {
        return "attempts_threads_" + viewerId;
    }

    private static String completionReviewKey(String viewerId) {
        return "completion_review_threads_" + viewerId;
    }

    private static String passiveRunningKey(String viewerId) {
        return "passive_running_threads_" + viewerId;
    }
}
