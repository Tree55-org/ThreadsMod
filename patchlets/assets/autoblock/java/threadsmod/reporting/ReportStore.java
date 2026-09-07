package threadsmod.reporting;

import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.database.DatabaseErrorHandler;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteException;
import android.database.sqlite.SQLiteOpenHelper;
import android.util.Base64;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Transactional, viewer-scoped report outbox and bounded terminal history. */
public final class ReportStore {
    public static final String PREFERENCE_FILE = "threadsmod_reporting";
    public static final String INSTALL_SECRET_KEY = "report_install_secret_v1";
    public static final String DATABASE_NAME = "threadsmod_reporting.db";

    public static final String HISTORY_SENT = "sent";
    public static final String HISTORY_REJECTED = "rejected_403";
    public static final String HISTORY_GAVE_UP = "gave_up";

    public static final String LOCAL_STATE_MISSING = "missing";
    public static final String LOCAL_STATE_VALID = "valid";
    public static final String LOCAL_STATE_CORRUPT = "corrupt";
    public static final String LOCAL_STATE_OVERSIZE = "oversize";
    public static final String LOCAL_STATE_WRONG_TYPE = "wrong_type";
    public static final String LOCAL_STATE_DURABILITY_UNCERTAIN = "durability_uncertain";
    public static final String LOCAL_STATE_UNAVAILABLE = "unavailable";

    private static final String TABLE_OUTBOX = "report_outbox";
    private static final String TABLE_HISTORY = "report_history";
    private static final int DATABASE_VERSION = 2;
    private static final String OUTBOX_V1_SQL =
            "CREATE TABLE report_outbox ("
                    + "report_id TEXT PRIMARY KEY NOT NULL,"
                    + "viewer_key TEXT NOT NULL,"
                    + "target_key TEXT NOT NULL,"
                    + "payload_json TEXT NOT NULL,"
                    + "tries INTEGER NOT NULL CHECK(tries BETWEEN 0 AND 15),"
                    + "created_at INTEGER NOT NULL CHECK(created_at >= 0),"
                    + "next_at INTEGER NOT NULL CHECK(next_at >= 0),"
                    + "last_http INTEGER NOT NULL CHECK(last_http = 0 OR last_http BETWEEN 100 AND 599),"
                    + "last_error TEXT NOT NULL,"
                    + "UNIQUE(viewer_key,target_key))";
    private static final String OUTBOX_V2_SQL =
            "CREATE TABLE report_outbox ("
                    + "report_id TEXT PRIMARY KEY NOT NULL,"
                    + "viewer_key TEXT NOT NULL,"
                    + "target_key TEXT NOT NULL,"
                    + "payload_json TEXT NOT NULL,"
                    + "tries INTEGER NOT NULL CHECK(tries BETWEEN 0 AND 15),"
                    + "created_at INTEGER NOT NULL CHECK(created_at >= 0),"
                    + "next_at INTEGER NOT NULL CHECK(next_at >= 0),"
                    + "last_http INTEGER NOT NULL CHECK(last_http = 0 OR last_http BETWEEN 100 AND 599),"
                    + "last_error TEXT NOT NULL)";
    private static final String OUTBOX_DUE_INDEX_SQL =
            "CREATE INDEX report_outbox_due_idx ON report_outbox"
                    + "(viewer_key,next_at,created_at)";
    private static final String HISTORY_SQL =
            "CREATE TABLE report_history ("
                    + "row_id INTEGER PRIMARY KEY AUTOINCREMENT,"
                    + "report_id TEXT NOT NULL,"
                    + "viewer_key TEXT NOT NULL,"
                    + "target_id TEXT NOT NULL,"
                    + "target_user TEXT NOT NULL,"
                    + "outcome TEXT NOT NULL,"
                    + "tries INTEGER NOT NULL CHECK(tries BETWEEN 0 AND 15),"
                    + "at INTEGER NOT NULL CHECK(at >= 0),"
                    + "UNIQUE(viewer_key,report_id))";
    private static final String HISTORY_INDEX_SQL =
            "CREATE INDEX report_history_viewer_idx ON report_history"
                    + "(viewer_key,at DESC,row_id DESC)";
    private static final int MAX_OUTBOX = 1000;
    private static final int MAX_HISTORY = 500;
    private static final int MAX_PAYLOAD_BYTES = 16 * 1024;
    private static final long MAX_STORED_FUTURE_MS = 366L * 24L * 60L * 60L * 1000L;
    private static final long[] RETRY_DELAYS_MS = new long[] {
            30_000L, 60_000L, 2L * 60_000L, 5L * 60_000L,
            15L * 60_000L, 60L * 60_000L,
            6L * 60L * 60_000L, 12L * 60L * 60_000L
    };

    private static final Map<String, String> ACTIVE_DELIVERIES =
            new HashMap<String, String>();
    private static final Map<String, String> REVIEW_STATES = new HashMap<String, String>();
    private static DatabaseHelper databaseHelper;
    private static boolean schemaValidated;

    private ReportStore() {}

    public static final class PendingEntry {
        public final String reportId;
        public final String profileId;
        public final String profileUsername;
        public final String reason;
        public final String postContent;
        public final int attempts;
        public final long createdAt;
        public final long nextAttemptAt;
        public final int lastHttpStatus;
        public final String lastError;
        public final boolean inFlight;

        PendingEntry(StoredRow row) {
            reportId = row.reportId;
            profileId = row.payload.getTargetId();
            profileUsername = row.payload.getTargetUsername();
            reason = row.payload.getReason();
            postContent = row.payload.getPostContent();
            attempts = row.tries;
            createdAt = row.createdAt;
            nextAttemptAt = row.nextAt;
            lastHttpStatus = row.lastHttp;
            lastError = row.lastError;
            inFlight = ACTIVE_DELIVERIES.containsKey(row.reportId);
        }
    }

    public static final class HistoryEntry {
        public final String reportId;
        public final String profileId;
        public final String profileUsername;
        public final String outcome;
        public final int attempts;
        public final long timestamp;

        HistoryEntry(StoredHistory row) {
            reportId = row.reportId;
            profileId = row.targetId;
            profileUsername = row.targetUser;
            outcome = row.outcome;
            attempts = row.tries;
            timestamp = row.at;
        }
    }

    public static final class Snapshot {
        public final String outboxState;
        public final String historyState;
        public final boolean needsReview;
        public final int pendingCount;
        public final int sentCount;
        public final int rejectedCount;
        public final int gaveUpCount;
        public final long nextAttemptAt;
        public final String terminalNotice;
        public final long terminalNoticeAt;
        public final List<PendingEntry> pending;
        public final List<HistoryEntry> history;

        Snapshot(
                String outboxState,
                String historyState,
                List<PendingEntry> pending,
                List<HistoryEntry> history) {
            this.outboxState = outboxState;
            this.historyState = historyState;
            needsReview = needsReview(outboxState) || needsReview(historyState);
            this.pending = Collections.unmodifiableList(pending);
            this.history = Collections.unmodifiableList(history);
            pendingCount = pending.size();
            int sent = 0;
            int rejected = 0;
            int gaveUp = 0;
            long next = Long.MAX_VALUE;
            for (PendingEntry entry : pending) {
                next = Math.min(next, entry.nextAttemptAt);
            }
            String notice = "";
            long noticeAt = 0L;
            for (HistoryEntry entry : history) {
                if (HISTORY_SENT.equals(entry.outcome)) {
                    sent++;
                } else if (HISTORY_REJECTED.equals(entry.outcome)) {
                    rejected++;
                    if (notice.length() == 0) {
                        notice = "A report was rejected by the relay (HTTP 403). Review the report service policy before trying again.";
                        noticeAt = entry.timestamp;
                    }
                } else if (HISTORY_GAVE_UP.equals(entry.outcome)) {
                    gaveUp++;
                    if (notice.length() == 0) {
                        notice = "Delivery could not be confirmed after 15 attempts; the server may have accepted it. Review before reporting again.";
                        noticeAt = entry.timestamp;
                    }
                }
            }
            sentCount = sent;
            rejectedCount = rejected;
            gaveUpCount = gaveUp;
            nextAttemptAt = next == Long.MAX_VALUE ? 0L : next;
            terminalNotice = notice;
            terminalNoticeAt = noticeAt;
        }
    }

    public static final class CancelResult {
        public static final String DELETED = "deleted";
        public static final String IN_FLIGHT = "in_flight";
        public static final String NOT_FOUND = "not_found";
        public static final String NEEDS_REVIEW = "needs_review";
        public static final String FAILED = "failed";

        public final String status;

        CancelResult(String status) {
            this.status = status;
        }

        public boolean isDeleted() {
            return DELETED.equals(status);
        }
    }

    static final class EnqueueResult {
        static final int ACCEPTED = 1;
        static final int FULL = 2;
        static final int STORE_ERROR = 3;
        static final int NEEDS_REVIEW = 4;

        final int code;
        final String reportId;

        EnqueueResult(int code, String reportId) {
            this.code = code;
            this.reportId = reportId == null ? "" : reportId;
        }
    }

    static final class Delivery {
        final String reportId;
        final ReportPayload payload;
        final int attempt;

        Delivery(String reportId, ReportPayload payload, int attempt) {
            this.reportId = reportId;
            this.payload = payload;
            this.attempt = attempt;
        }
    }

    static final class PseudonymDraft {
        final String pseudonym;
        private final String candidateSecret;

        PseudonymDraft(String pseudonym, String candidateSecret) {
            this.pseudonym = pseudonym == null ? "" : pseudonym;
            this.candidateSecret = candidateSecret == null ? "" : candidateSecret;
        }

        boolean isValid() {
            return ReportValues.isPseudonym(pseudonym);
        }
    }

    /** Builds a stable preview value without writing the install secret. */
    static synchronized PseudonymDraft preparePseudonym(
            Context context, String viewerId) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            return new PseudonymDraft("", "");
        }
        String scope = viewerKey(viewerId);
        if (reviewState(scope) != null) {
            return new PseudonymDraft("", "");
        }
        try {
            SharedPreferences preferences = preferences(context);
            Map<String, ?> values = preferences.getAll();
            boolean exists = values.containsKey(INSTALL_SECRET_KEY);
            Object raw = values.get(INSTALL_SECRET_KEY);
            if (exists && !(raw instanceof String)) {
                markReview(scope, LOCAL_STATE_WRONG_TYPE);
                return new PseudonymDraft("", "");
            }
            String encoded = exists ? (String) raw : "";
            byte[] secret = exists ? decodeSecret(encoded) : null;
            if (exists && secret == null) {
                markReview(scope, LOCAL_STATE_CORRUPT);
                return new PseudonymDraft("", "");
            }
            if (!exists) {
                secret = new byte[32];
                new SecureRandom().nextBytes(secret);
                encoded = Base64.encodeToString(secret, Base64.NO_WRAP);
            }
            return new PseudonymDraft(
                    pseudonymFromSecret(secret, viewerId), exists ? "" : encoded);
        } catch (Throwable ignored) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            return new PseudonymDraft("", "");
        }
    }

    /** Commits exactly the pseudonym secret prepared for this explicit modal action. */
    static synchronized boolean commitPseudonym(
            Context context, String viewerId, PseudonymDraft draft) {
        if (context == null || !ReportValues.isNumericId(viewerId)
                || draft == null || !draft.isValid()) {
            return false;
        }
        String scope = viewerKey(viewerId);
        if (reviewState(scope) != null) {
            return false;
        }
        try {
            SharedPreferences preferences = preferences(context);
            Map<String, ?> values = preferences.getAll();
            if (values.containsKey(INSTALL_SECRET_KEY)) {
                Object raw = values.get(INSTALL_SECRET_KEY);
                if (!(raw instanceof String)) {
                    markReview(scope, LOCAL_STATE_WRONG_TYPE);
                    return false;
                }
                byte[] existing = decodeSecret((String) raw);
                if (existing == null) {
                    markReview(scope, LOCAL_STATE_CORRUPT);
                    return false;
                }
                return draft.pseudonym.equals(
                        pseudonymFromSecret(existing, viewerId));
            }
            byte[] candidate = decodeSecret(draft.candidateSecret);
            if (candidate == null || !draft.pseudonym.equals(
                    pseudonymFromSecret(candidate, viewerId))) {
                return false;
            }
            if (!preferences.edit()
                    .putString(INSTALL_SECRET_KEY, draft.candidateSecret)
                    .commit()) {
                preferences.edit().remove(INSTALL_SECRET_KEY).commit();
                markReview(scope, LOCAL_STATE_DURABILITY_UNCERTAIN);
                return false;
            }
            return true;
        } catch (Throwable ignored) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            return false;
        }
    }

    /** Reads an already committed pseudonym; absence is valid only for an empty store. */
    static synchronized String pseudonymFor(Context context, String viewerId) {
        if (context == null || !ReportValues.isNumericId(viewerId)) {
            return "";
        }
        String scope = viewerKey(viewerId);
        try {
            Map<String, ?> values = preferences(context).getAll();
            if (!values.containsKey(INSTALL_SECRET_KEY)) {
                return "";
            }
            Object raw = values.get(INSTALL_SECRET_KEY);
            if (!(raw instanceof String)) {
                markReview(scope, LOCAL_STATE_WRONG_TYPE);
                return "";
            }
            byte[] secret = decodeSecret((String) raw);
            if (secret == null) {
                markReview(scope, LOCAL_STATE_CORRUPT);
                return "";
            }
            return pseudonymFromSecret(secret, viewerId);
        } catch (Throwable ignored) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            return "";
        }
    }

    static synchronized EnqueueResult enqueue(
            Context context, String viewerId, ReportPayload payload, long now) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0 || payload == null || !payload.isValid()
                || payload.getTargetId().equals(viewerId)) {
            return new EnqueueResult(EnqueueResult.STORE_ERROR, "");
        }
        if (reviewState(scope) != null) {
            return new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");
        }
        String expectedPseudonym = pseudonymFor(context, viewerId);
        if (reviewState(scope) != null) {
            return new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");
        }
        if (!expectedPseudonym.equals(payload.getPseudonym())) {
            return new EnqueueResult(EnqueueResult.STORE_ERROR, "");
        }
        SQLiteDatabase db = null;
        boolean began = false;
        EnqueueResult result = new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");
        try {
            db = writableDatabase(context);
            db.beginTransaction();
            began = true;
            int pendingCount = countOutbox(db, scope);
            if (pendingCount >= MAX_OUTBOX) {
                result = new EnqueueResult(EnqueueResult.FULL, "");
            } else {
                String reportId = randomId();
                String payloadJson = payload.toJson().toString();
                int payloadBytes = utf8Length(payloadJson);
                if (payloadBytes == 0 || payloadBytes > MAX_PAYLOAD_BYTES) {
                    throw new StoreStateException(
                            payloadBytes > MAX_PAYLOAD_BYTES
                                    ? LOCAL_STATE_OVERSIZE : LOCAL_STATE_CORRUPT);
                }
                ContentValues values = new ContentValues();
                values.put("report_id", reportId);
                values.put("viewer_key", scope);
                values.put("target_key", payload.targetKey());
                values.put("payload_json", payloadJson);
                values.put("tries", 0);
                values.put("created_at", saneTime(now));
                values.put("next_at", saneTime(now));
                values.put("last_http", 0);
                values.put("last_error", "");
                if (db.insertOrThrow(TABLE_OUTBOX, null, values) < 0L) {
                    throw new SQLiteException("report insert failed");
                }
                result = new EnqueueResult(EnqueueResult.ACCEPTED, reportId);
            }
            db.setTransactionSuccessful();
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
            result = new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            result = new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");
        } finally {
            if (!endTransaction(db, began, scope)) {
                result = new EnqueueResult(EnqueueResult.NEEDS_REVIEW, "");
            }
        }
        return result;
    }

    /** Atomically reserves and counts one due attempt before returning its payload. */
    static synchronized Delivery reserveNextDue(
            Context context, String viewerId, long now) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0 || reviewState(scope) != null) {
            return null;
        }
        String expectedPseudonym = pseudonymFor(context, viewerId);
        if (reviewState(scope) != null) {
            return null;
        }
        if (expectedPseudonym.length() == 0) {
            return null;
        }
        SQLiteDatabase db = null;
        boolean began = false;
        Delivery delivery = null;
        try {
            db = writableDatabase(context);
            db.beginTransaction();
            began = true;
            boolean insertedHistory = false;
            while (true) {
                StoredRow row = queryOneOutbox(
                        db,
                        scope,
                        expectedPseudonym,
                        "viewer_key=? AND next_at<=?",
                        new String[] {scope, Long.toString(saneTime(now))},
                        "next_at ASC, created_at ASC, report_id ASC");
                if (row == null) {
                    break;
                }
                if (row.tries >= 15) {
                    moveToHistory(db, scope, row, HISTORY_GAVE_UP, now);
                    insertedHistory = true;
                    continue;
                }
                int attempt = row.tries + 1;
                ContentValues update = new ContentValues();
                update.put("tries", attempt);
                update.put("next_at", safeAdd(now, retryDelay(attempt)));
                update.put("last_http", 0);
                update.put("last_error", "delivery_interrupted");
                int changed = db.update(
                        TABLE_OUTBOX,
                        update,
                        "viewer_key=? AND report_id=? AND tries=?",
                        new String[] {scope, row.reportId, Integer.toString(row.tries)});
                if (changed != 1) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                delivery = new Delivery(row.reportId, row.payload, attempt);
                break;
            }
            if (insertedHistory) {
                trimHistory(db, scope);
            }
            db.setTransactionSuccessful();
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
            delivery = null;
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            delivery = null;
        } finally {
            if (!endTransaction(db, began, scope)) {
                delivery = null;
            }
        }
        if (delivery != null) {
            ACTIVE_DELIVERIES.put(delivery.reportId, scope);
        }
        return delivery;
    }

    static synchronized void markSent(
            Context context, String viewerId, String reportId, long now) {
        finish(context, viewerId, reportId, HISTORY_SENT, now);
    }

    static synchronized void markRejected(
            Context context, String viewerId, String reportId, long now) {
        finish(context, viewerId, reportId, HISTORY_REJECTED, now);
    }

    static synchronized boolean markFailure(
            Context context,
            String viewerId,
            String reportId,
            int httpStatus,
            String error,
            long now) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0 || reviewState(scope) != null) {
            return false;
        }
        SQLiteDatabase db = null;
        boolean began = false;
        boolean remains = false;
        try {
            db = writableDatabase(context);
            db.beginTransaction();
            began = true;
            String expectedPseudonym = pseudonymFor(context, viewerId);
            String detectedReview = reviewState(scope);
            if (detectedReview != null) {
                throw new StoreStateException(detectedReview);
            }
            if (expectedPseudonym.length() == 0) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            StoredRow selected = queryOneOutbox(
                    db,
                    scope,
                    expectedPseudonym,
                    "viewer_key=? AND report_id=?",
                    new String[] {scope, cleanId(reportId)},
                    null);
            if (selected == null) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            if (selected.tries >= 15) {
                moveToHistory(db, scope, selected, HISTORY_GAVE_UP, now);
                trimHistory(db, scope);
            } else {
                ContentValues update = new ContentValues();
                update.put("last_http", boundedHttpStatus(httpStatus));
                update.put("last_error", ReportValues.cleanToken(error, 120));
                if (db.update(
                        TABLE_OUTBOX,
                        update,
                        "viewer_key=? AND report_id=?",
                        new String[] {scope, selected.reportId}) != 1) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                remains = true;
            }
            db.setTransactionSuccessful();
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
            remains = false;
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            remains = false;
        } finally {
            if (!endTransaction(db, began, scope)) {
                remains = false;
            }
        }
        return remains;
    }

    static synchronized long nextWakeAt(Context context, String viewerId) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0 || reviewState(scope) != null) {
            return 0L;
        }
        try {
            SQLiteDatabase db = writableDatabase(context);
            String expectedPseudonym = pseudonymFor(context, viewerId);
            if (reviewState(scope) != null) {
                return 0L;
            }
            if (expectedPseudonym.length() == 0) {
                if (countOutbox(db, scope) == 0) {
                    return 0L;
                }
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            StoredRow row = queryOneOutbox(
                    db,
                    scope,
                    expectedPseudonym,
                    "viewer_key=?",
                    new String[] {scope},
                    "next_at ASC, created_at ASC, report_id ASC");
            return row == null ? 0L : row.nextAt;
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
        }
        return 0L;
    }

    static synchronized boolean retryNow(Context context, String viewerId, long now) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0 || reviewState(scope) != null) {
            return false;
        }
        if (ACTIVE_DELIVERIES.containsValue(scope)) {
            return false;
        }
        SQLiteDatabase db = null;
        boolean began = false;
        boolean changed = false;
        try {
            db = writableDatabase(context);
            db.beginTransaction();
            began = true;
            int pendingCount = countOutbox(db, scope);
            if (pendingCount == 0) {
                db.setTransactionSuccessful();
                return false;
            }
            String expectedPseudonym = pseudonymFor(context, viewerId);
            String detectedReview = reviewState(scope);
            if (detectedReview != null) {
                throw new StoreStateException(detectedReview);
            }
            if (expectedPseudonym.length() == 0) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            ContentValues update = new ContentValues();
            update.put("next_at", saneTime(now));
            update.put("last_error", "manual_retry");
            if (pendingCount > 0) {
                int updated = db.update(
                        TABLE_OUTBOX,
                        update,
                        "viewer_key=?",
                        new String[] {scope});
                if (updated != pendingCount) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                changed = true;
            }
            db.setTransactionSuccessful();
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
            changed = false;
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            changed = false;
        } finally {
            if (!endTransaction(db, began, scope)) {
                changed = false;
            }
        }
        return changed;
    }

    static synchronized CancelResult cancelPendingDetailed(
            Context context, String viewerId, String reportId) {
        String scope = viewerKey(viewerId);
        String safeReportId = cleanId(reportId);
        if (context == null || scope.length() == 0 || safeReportId.length() == 0) {
            return new CancelResult(CancelResult.FAILED);
        }
        if (ACTIVE_DELIVERIES.containsKey(safeReportId)) {
            return new CancelResult(CancelResult.IN_FLIGHT);
        }
        if (reviewState(scope) != null) {
            return new CancelResult(CancelResult.NEEDS_REVIEW);
        }
        SQLiteDatabase db = null;
        boolean began = false;
        String outcome = CancelResult.FAILED;
        try {
            db = writableDatabase(context);
            db.beginTransaction();
            began = true;
            int pendingCount = countOutbox(db, scope);
            if (pendingCount == 0) {
                outcome = CancelResult.NOT_FOUND;
            } else {
                String expectedPseudonym = pseudonymFor(context, viewerId);
                String detectedReview = reviewState(scope);
                if (detectedReview != null) {
                    throw new StoreStateException(detectedReview);
                }
                if (expectedPseudonym.length() == 0) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                StoredRow selected = queryOneOutbox(
                        db,
                        scope,
                        expectedPseudonym,
                        "viewer_key=? AND report_id=?",
                        new String[] {scope, safeReportId},
                        null);
                if (selected == null) {
                    outcome = CancelResult.NOT_FOUND;
                } else if (ACTIVE_DELIVERIES.containsKey(safeReportId)) {
                    outcome = CancelResult.IN_FLIGHT;
                } else if (db.delete(
                        TABLE_OUTBOX,
                        "viewer_key=? AND report_id=?",
                        new String[] {scope, safeReportId}) == 1) {
                    outcome = CancelResult.DELETED;
                } else {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
            }
            db.setTransactionSuccessful();
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
            outcome = CancelResult.NEEDS_REVIEW;
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            outcome = CancelResult.NEEDS_REVIEW;
        } finally {
            if (!endTransaction(db, began, scope)) {
                outcome = CancelResult.NEEDS_REVIEW;
            }
        }
        return new CancelResult(outcome);
    }

    static synchronized boolean cancelPending(
            Context context, String viewerId, String reportId) {
        return cancelPendingDetailed(context, viewerId, reportId).isDeleted();
    }

    public static synchronized Snapshot getSnapshot(Context context, String viewerId) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0) {
            return emptySnapshot(LOCAL_STATE_UNAVAILABLE);
        }
        String review = reviewState(scope);
        if (review != null) {
            return emptySnapshot(review);
        }
        try {
            SQLiteDatabase db = writableDatabase(context);
            String expectedPseudonym = pseudonymFor(context, viewerId);
            String detectedReview = reviewState(scope);
            if (detectedReview != null) {
                return emptySnapshot(detectedReview);
            }
            List<StoredRow> rows = loadOutbox(db, scope, expectedPseudonym);
            List<StoredHistory> storedHistory = loadHistory(db, scope);
            if (!ReportValues.isPseudonym(expectedPseudonym)
                    && (!rows.isEmpty() || !storedHistory.isEmpty())) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            validateSnapshotIdentity(rows, storedHistory, viewerId);
            ArrayList<PendingEntry> pending = new ArrayList<PendingEntry>();
            ArrayList<HistoryEntry> history = new ArrayList<HistoryEntry>();
            for (StoredRow row : rows) {
                pending.add(new PendingEntry(row));
            }
            for (StoredHistory row : storedHistory) {
                history.add(new HistoryEntry(row));
            }
            return new Snapshot(LOCAL_STATE_VALID, LOCAL_STATE_VALID, pending, history);
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
            return emptySnapshot(badState.state);
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
            return emptySnapshot(LOCAL_STATE_CORRUPT);
        }
    }

    static synchronized void releaseDelivery(String reportId) {
        ACTIVE_DELIVERIES.remove(cleanId(reportId));
    }

    /** Rejects impossible cross-table lifecycle duplicates and self-target rows. */
    private static void validateSnapshotIdentity(
            List<StoredRow> rows,
            List<StoredHistory> history,
            String viewerId) throws StoreStateException {
        Set<String> reportIds = new HashSet<String>();
        for (StoredRow row : rows) {
            if (viewerId.equals(row.payload.getTargetId())
                    || !reportIds.add(row.reportId)) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
        }
        for (StoredHistory row : history) {
            if (viewerId.equals(row.targetId) || !reportIds.add(row.reportId)) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
        }
    }

    private static void finish(
            Context context, String viewerId, String reportId, String outcome, long now) {
        String scope = viewerKey(viewerId);
        if (context == null || scope.length() == 0 || reviewState(scope) != null) {
            return;
        }
        SQLiteDatabase db = null;
        boolean began = false;
        try {
            db = writableDatabase(context);
            db.beginTransaction();
            began = true;
            String expectedPseudonym = pseudonymFor(context, viewerId);
            String detectedReview = reviewState(scope);
            if (detectedReview != null) {
                throw new StoreStateException(detectedReview);
            }
            if (expectedPseudonym.length() == 0) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            StoredRow selected = queryOneOutbox(
                    db,
                    scope,
                    expectedPseudonym,
                    "viewer_key=? AND report_id=?",
                    new String[] {scope, cleanId(reportId)},
                    null);
            if (selected == null) {
                throw new StoreStateException(LOCAL_STATE_CORRUPT);
            }
            moveToHistory(db, scope, selected, outcome, now);
            trimHistory(db, scope);
            db.setTransactionSuccessful();
        } catch (StoreStateException badState) {
            markReview(scope, badState.state);
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_CORRUPT);
        } finally {
            endTransaction(db, began, scope);
        }
    }

    private static List<StoredRow> loadOutbox(
            SQLiteDatabase db, String scope, String expectedPseudonym)
            throws Exception {
        Cursor cursor = null;
        ArrayList<StoredRow> rows = new ArrayList<StoredRow>();
        Set<String> ids = new HashSet<String>();
        try {
            cursor = db.query(
                    TABLE_OUTBOX,
                    new String[] {
                            "report_id", "viewer_key", "target_key", "payload_json",
                            "tries", "created_at", "next_at", "last_http", "last_error"
                    },
                    "viewer_key=?",
                    new String[] {scope},
                    null,
                    null,
                    "next_at ASC, created_at ASC, report_id ASC",
                    Integer.toString(MAX_OUTBOX + 1));
            while (cursor.moveToNext()) {
                if (rows.size() >= MAX_OUTBOX) {
                    throw new StoreStateException(LOCAL_STATE_OVERSIZE);
                }
                if (!ReportValues.isPseudonym(expectedPseudonym)) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                StoredRow row = readOutboxRow(cursor, scope, expectedPseudonym);
                if (!ids.add(row.reportId)) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                rows.add(row);
            }
            return rows;
        } finally {
            close(cursor);
        }
    }

    private static StoredRow queryOneOutbox(
            SQLiteDatabase db,
            String scope,
            String expectedPseudonym,
            String selection,
            String[] selectionArgs,
            String orderBy) throws Exception {
        if (!ReportValues.isPseudonym(expectedPseudonym)) {
            throw new StoreStateException(LOCAL_STATE_CORRUPT);
        }
        Cursor cursor = null;
        try {
            cursor = db.query(
                    TABLE_OUTBOX,
                    new String[] {
                            "report_id", "viewer_key", "target_key", "payload_json",
                            "tries", "created_at", "next_at", "last_http", "last_error"
                    },
                    selection,
                    selectionArgs,
                    null,
                    null,
                    orderBy,
                    "1");
            return cursor.moveToFirst()
                    ? readOutboxRow(cursor, scope, expectedPseudonym) : null;
        } finally {
            close(cursor);
        }
    }

    private static int countOutbox(SQLiteDatabase db, String scope) throws Exception {
        Cursor cursor = null;
        try {
            cursor = db.rawQuery(
                    "SELECT COUNT(*) FROM " + TABLE_OUTBOX + " WHERE viewer_key=?",
                    new String[] {scope});
            if (!cursor.moveToFirst()
                    || cursor.getType(0) != Cursor.FIELD_TYPE_INTEGER) {
                throw new StoreStateException(LOCAL_STATE_WRONG_TYPE);
            }
            long count = cursor.getLong(0);
            if (count < 0L || count > MAX_OUTBOX) {
                throw new StoreStateException(
                        count > MAX_OUTBOX
                                ? LOCAL_STATE_OVERSIZE : LOCAL_STATE_CORRUPT);
            }
            return (int) count;
        } finally {
            close(cursor);
        }
    }

    private static StoredRow readOutboxRow(
            Cursor cursor, String scope, String expectedPseudonym) throws Exception {
        requireType(cursor, 0, Cursor.FIELD_TYPE_STRING);
        requireType(cursor, 1, Cursor.FIELD_TYPE_STRING);
        requireType(cursor, 2, Cursor.FIELD_TYPE_STRING);
        requireType(cursor, 3, Cursor.FIELD_TYPE_STRING);
        for (int index = 4; index <= 7; index++) {
            requireType(cursor, index, Cursor.FIELD_TYPE_INTEGER);
        }
        requireType(cursor, 8, Cursor.FIELD_TYPE_STRING);
        String reportId = cursor.getString(0);
        String viewerKey = cursor.getString(1);
        String targetKey = cursor.getString(2);
        String payloadJson = cursor.getString(3);
        long rawTries = cursor.getLong(4);
        long createdAt = cursor.getLong(5);
        long nextAt = cursor.getLong(6);
        long rawHttp = cursor.getLong(7);
        String lastError = cursor.getString(8);
        int payloadBytes = utf8Length(payloadJson);
        if (!cleanId(reportId).equals(reportId)
                || !scope.equals(viewerKey)
                || payloadBytes == 0
                || payloadBytes > MAX_PAYLOAD_BYTES
                || rawTries < 0L || rawTries > 15L
                || !isPlausibleStoredTime(createdAt)
                || !isPlausibleStoredTime(nextAt)
                || !(rawHttp == 0L || (rawHttp >= 100L && rawHttp <= 599L))
                || !ReportJson.isCompleteObject(payloadJson)
                || !ReportValues.cleanToken(lastError, 120).equals(lastError)) {
            throw new StoreStateException(
                    payloadBytes > MAX_PAYLOAD_BYTES
                            ? LOCAL_STATE_OVERSIZE : LOCAL_STATE_CORRUPT);
        }
        JSONObject rawPayload = new JSONObject(payloadJson);
        ReportPayload payload = ReportPayload.fromJson(rawPayload);
        if (payload == null || !payload.matchesStoredJson(rawPayload)
                || !ReportValues.isNumericId(payload.getTargetId())
                || !payload.targetKey().equals(targetKey)
                || !expectedPseudonym.equals(payload.getPseudonym())) {
            throw new StoreStateException(LOCAL_STATE_CORRUPT);
        }
        return new StoredRow(
                reportId, targetKey, payload, (int) rawTries,
                createdAt, nextAt, (int) rawHttp, lastError);
    }

    private static List<StoredHistory> loadHistory(SQLiteDatabase db, String scope)
            throws Exception {
        Cursor cursor = null;
        ArrayList<StoredHistory> rows = new ArrayList<StoredHistory>();
        Set<String> ids = new HashSet<String>();
        try {
            cursor = db.query(
                    TABLE_HISTORY,
                    new String[] {
                            "row_id", "report_id", "viewer_key", "target_id",
                            "target_user", "outcome", "tries", "at"
                    },
                    "viewer_key=?",
                    new String[] {scope},
                    null,
                    null,
                    "at DESC, row_id DESC",
                    Integer.toString(MAX_HISTORY + 1));
            while (cursor.moveToNext()) {
                if (rows.size() >= MAX_HISTORY) {
                    throw new StoreStateException(LOCAL_STATE_OVERSIZE);
                }
                for (int index : new int[] {0, 6, 7}) {
                    requireType(cursor, index, Cursor.FIELD_TYPE_INTEGER);
                }
                for (int index : new int[] {1, 2, 3, 4, 5}) {
                    requireType(cursor, index, Cursor.FIELD_TYPE_STRING);
                }
                long rowId = cursor.getLong(0);
                String reportId = cursor.getString(1);
                String viewerKey = cursor.getString(2);
                String targetId = cursor.getString(3);
                String targetUser = cursor.getString(4);
                String outcome = cursor.getString(5);
                long tries = cursor.getLong(6);
                long at = cursor.getLong(7);
                boolean outcomeValid = HISTORY_SENT.equals(outcome)
                        || HISTORY_REJECTED.equals(outcome)
                        || HISTORY_GAVE_UP.equals(outcome);
                boolean attemptsValid = (HISTORY_GAVE_UP.equals(outcome) && tries == 15L)
                        || ((HISTORY_SENT.equals(outcome)
                                || HISTORY_REJECTED.equals(outcome))
                                && tries >= 1L && tries <= 15L);
                if (rowId <= 0L || !cleanId(reportId).equals(reportId)
                        || !scope.equals(viewerKey)
                        || !ReportValues.isNumericId(targetId)
                        || targetUser.length() == 0
                        || !ReportValues.normalizeUsername(targetUser).equals(targetUser)
                        || !outcomeValid || !attemptsValid
                        || !isPlausibleStoredTime(at)
                        || !ids.add(reportId)) {
                    throw new StoreStateException(LOCAL_STATE_CORRUPT);
                }
                rows.add(new StoredHistory(
                        reportId, targetId, targetUser, outcome, (int) tries, at));
            }
            return rows;
        } finally {
            close(cursor);
        }
    }

    private static void moveToHistory(
            SQLiteDatabase db,
            String scope,
            StoredRow row,
            String outcome,
            long now) throws Exception {
        ContentValues history = new ContentValues();
        history.put("report_id", row.reportId);
        history.put("viewer_key", scope);
        history.put("target_id", row.payload.getTargetId());
        history.put("target_user", row.payload.getTargetUsername());
        history.put("outcome", outcome);
        history.put("tries", row.tries);
        history.put("at", saneTime(now));
        if (db.insertOrThrow(TABLE_HISTORY, null, history) < 0L
                || db.delete(
                        TABLE_OUTBOX,
                        "viewer_key=? AND report_id=?",
                        new String[] {scope, row.reportId}) != 1) {
            throw new StoreStateException(LOCAL_STATE_CORRUPT);
        }
    }

    private static void trimHistory(SQLiteDatabase db, String scope) {
        db.execSQL(
                "DELETE FROM " + TABLE_HISTORY
                        + " WHERE viewer_key=? AND row_id NOT IN (SELECT row_id FROM "
                        + TABLE_HISTORY
                        + " WHERE viewer_key=? ORDER BY row_id DESC LIMIT "
                        + MAX_HISTORY + ")",
                new Object[] {scope, scope});
    }

    private static SQLiteDatabase writableDatabase(Context context) {
        if (databaseHelper == null) {
            databaseHelper = new DatabaseHelper(context.getApplicationContext());
        }
        SQLiteDatabase database = databaseHelper.getWritableDatabase();
        if (database == null || !database.isOpen() || database.isReadOnly()) {
            throw new SQLiteException("report database is not writable");
        }
        validateSchema(database);
        return database;
    }

    private static void validateSchema(SQLiteDatabase database) {
        if (schemaValidated) {
            return;
        }
        Cursor check = null;
        try {
            check = database.rawQuery("PRAGMA quick_check(1)", null);
            if (!check.moveToFirst() || check.getType(0) != Cursor.FIELD_TYPE_STRING
                    || !"ok".equalsIgnoreCase(check.getString(0))) {
                throw new SQLiteException("report database integrity check failed");
            }
        } finally {
            close(check);
        }
        Cursor version = null;
        try {
            version = database.rawQuery("PRAGMA user_version", null);
            if (!version.moveToFirst()
                    || version.getType(0) != Cursor.FIELD_TYPE_INTEGER
                    || version.getInt(0) != DATABASE_VERSION) {
                throw new SQLiteException("report database version requires review");
            }
        } finally {
            close(version);
        }
        requireSchemaObject(
                database,
                "table",
                TABLE_OUTBOX,
                new String[] {
                        "report_idtextprimarykeynotnull",
                        "viewer_keytextnotnull",
                        "target_keytextnotnull",
                        "payload_jsontextnotnull"
                });
        forbidSchemaObjectFragment(
                database,
                "table",
                TABLE_OUTBOX,
                "unique(viewer_key,target_key)");
        requireSchemaObject(
                database,
                "index",
                "report_outbox_due_idx",
                new String[] {"(viewer_key,next_at,created_at)"});
        requireSchemaObject(
                database,
                "table",
                TABLE_HISTORY,
                new String[] {
                        "row_idintegerprimarykeyautoincrement",
                        "report_idtextnotnull",
                        "viewer_keytextnotnull",
                        "unique(viewer_key,report_id)"
                });
        requireSchemaObject(
                database,
                "index",
                "report_history_viewer_idx",
                new String[] {"(viewer_key,atdesc,row_iddesc)"});
        requireExactSchemaObject(database, "table", TABLE_OUTBOX, OUTBOX_V2_SQL);
        requireExactSchemaObject(
                database,
                "index",
                "report_outbox_due_idx",
                OUTBOX_DUE_INDEX_SQL);
        requireExactSchemaObject(database, "table", TABLE_HISTORY, HISTORY_SQL);
        requireExactSchemaObject(
                database,
                "index",
                "report_history_viewer_idx",
                HISTORY_INDEX_SQL);
        requireOwnedSchemaObjectCount(database, TABLE_OUTBOX, 3);
        requireOwnedSchemaObjectCount(database, TABLE_HISTORY, 3);
        schemaValidated = true;
    }

    private static void requireSchemaObject(
            SQLiteDatabase database,
            String type,
            String name,
            String[] requiredFragments) {
        Cursor cursor = null;
        try {
            cursor = database.query(
                    "sqlite_master",
                    new String[] {"type", "name", "sql"},
                    "type=? AND name=?",
                    new String[] {type, name},
                    null,
                    null,
                    null,
                    "2");
            if (!cursor.moveToFirst() || cursor.getCount() != 1
                    || cursor.getType(0) != Cursor.FIELD_TYPE_STRING
                    || cursor.getType(1) != Cursor.FIELD_TYPE_STRING
                    || cursor.getType(2) != Cursor.FIELD_TYPE_STRING
                    || !type.equals(cursor.getString(0))
                    || !name.equals(cursor.getString(1))) {
                throw new SQLiteException("report database schema object is missing");
            }
            String normalized = cursor.getString(2)
                    .toLowerCase(java.util.Locale.US)
                    .replaceAll("\\s+", "");
            for (String fragment : requiredFragments) {
                if (!normalized.contains(fragment)) {
                    throw new SQLiteException("report database schema drift requires review");
                }
            }
        } finally {
            close(cursor);
        }
    }

    private static void forbidSchemaObjectFragment(
            SQLiteDatabase database,
            String type,
            String name,
            String forbiddenFragment) {
        Cursor cursor = null;
        try {
            cursor = database.query(
                    "sqlite_master",
                    new String[] {"sql"},
                    "type=? AND name=?",
                    new String[] {type, name},
                    null,
                    null,
                    null,
                    "2");
            if (!cursor.moveToFirst() || cursor.getCount() != 1
                    || cursor.getType(0) != Cursor.FIELD_TYPE_STRING) {
                throw new SQLiteException("report database schema object is missing");
            }
            String normalized = cursor.getString(0)
                    .toLowerCase(java.util.Locale.US)
                    .replaceAll("\\s+", "");
            if (normalized.contains(forbiddenFragment)) {
                throw new SQLiteException("report database retired uniqueness requires review");
            }
        } finally {
            close(cursor);
        }
    }

    private static void requireExactSchemaObject(
            SQLiteDatabase database,
            String type,
            String name,
            String expectedSql) {
        Cursor cursor = null;
        try {
            cursor = database.query(
                    "sqlite_master",
                    new String[] {"type", "name", "sql"},
                    "type=? AND name=?",
                    new String[] {type, name},
                    null,
                    null,
                    null,
                    "2");
            if (!cursor.moveToFirst() || cursor.getCount() != 1
                    || cursor.getType(0) != Cursor.FIELD_TYPE_STRING
                    || cursor.getType(1) != Cursor.FIELD_TYPE_STRING
                    || cursor.getType(2) != Cursor.FIELD_TYPE_STRING
                    || !type.equals(cursor.getString(0))
                    || !name.equals(cursor.getString(1))
                    || !normalizeSchemaSql(expectedSql).equals(
                            normalizeSchemaSql(cursor.getString(2)))) {
                throw new SQLiteException("report database exact schema requires review");
            }
        } finally {
            close(cursor);
        }
    }

    private static void requireOwnedSchemaObjectCount(
            SQLiteDatabase database, String table, int expectedCount) {
        Cursor cursor = null;
        try {
            cursor = database.rawQuery(
                    "SELECT COUNT(*) FROM sqlite_master WHERE tbl_name=? "
                            + "AND type IN ('table','index','trigger')",
                    new String[] {table});
            if (!cursor.moveToFirst()
                    || cursor.getType(0) != Cursor.FIELD_TYPE_INTEGER
                    || cursor.getLong(0) != expectedCount) {
                throw new SQLiteException("report database schema object count requires review");
            }
        } finally {
            close(cursor);
        }
    }

    private static String normalizeSchemaSql(String sql) {
        return sql == null ? "" : sql.toLowerCase(java.util.Locale.US).replaceAll("\\s+", "");
    }

    private static boolean endTransaction(
            SQLiteDatabase database, boolean began, String scope) {
        if (!began || database == null) {
            return !began;
        }
        try {
            database.endTransaction();
            return true;
        } catch (Throwable failure) {
            markReview(scope, LOCAL_STATE_DURABILITY_UNCERTAIN);
            return false;
        }
    }

    private static void requireType(Cursor cursor, int column, int expected)
            throws StoreStateException {
        if (cursor.getType(column) != expected) {
            throw new StoreStateException(LOCAL_STATE_WRONG_TYPE);
        }
    }

    private static Snapshot emptySnapshot(String state) {
        return new Snapshot(
                state, state,
                new ArrayList<PendingEntry>(), new ArrayList<HistoryEntry>());
    }

    private static String reviewState(String scope) {
        return REVIEW_STATES.get(scope);
    }

    private static void markReview(String scope, String state) {
        if (scope != null && scope.length() > 0 && !REVIEW_STATES.containsKey(scope)) {
            REVIEW_STATES.put(scope, needsReview(state) ? state : LOCAL_STATE_CORRUPT);
        }
    }

    private static boolean needsReview(String state) {
        return LOCAL_STATE_CORRUPT.equals(state)
                || LOCAL_STATE_OVERSIZE.equals(state)
                || LOCAL_STATE_WRONG_TYPE.equals(state)
                || LOCAL_STATE_DURABILITY_UNCERTAIN.equals(state);
    }

    private static void close(Cursor cursor) {
        if (cursor != null) {
            cursor.close();
        }
    }

    private static byte[] decodeSecret(String encoded) {
        try {
            byte[] secret = Base64.decode(encoded, Base64.NO_WRAP);
            return secret.length == 32
                    && Base64.encodeToString(secret, Base64.NO_WRAP).equals(encoded)
                    ? secret : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static String pseudonymFromSecret(byte[] secret, String viewerId)
            throws Exception {
        if (secret == null || secret.length != 32
                || !ReportValues.isNumericId(viewerId)) {
            return "";
        }
        Mac hmac = Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(secret, "HmacSHA256"));
        byte[] digest = hmac.doFinal(
                ("threads:" + viewerId).getBytes(StandardCharsets.UTF_8));
        return "acct_" + firstHex(digest, 12);
    }

    private static String viewerKey(String viewerId) {
        if (!ReportValues.isNumericId(viewerId)) {
            return "";
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(
                    viewerId.getBytes(StandardCharsets.UTF_8));
            return firstHex(digest, digest.length);
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String firstHex(byte[] bytes, int count) {
        StringBuilder value = new StringBuilder(count * 2);
        for (int index = 0; index < count; index++) {
            int element = bytes[index] & 0xff;
            if (element < 16) {
                value.append('0');
            }
            value.append(Integer.toHexString(element));
        }
        return value.toString();
    }

    private static String randomId() {
        byte[] bytes = new byte[16];
        new SecureRandom().nextBytes(bytes);
        return "rpt_" + firstHex(bytes, bytes.length);
    }

    private static String cleanId(String value) {
        if (value == null || value.length() != 36 || !value.startsWith("rpt_")) {
            return "";
        }
        for (int index = 4; index < value.length(); index++) {
            char character = value.charAt(index);
            if (!((character >= '0' && character <= '9')
                    || (character >= 'a' && character <= 'f'))) {
                return "";
            }
        }
        return value;
    }

    private static int boundedHttpStatus(int value) {
        return value >= 100 && value <= 599 ? value : 0;
    }

    private static long saneTime(long value) {
        return Math.max(0L, value);
    }

    private static long safeAdd(long left, long right) {
        if (right > 0L && left > Long.MAX_VALUE - right) {
            return Long.MAX_VALUE;
        }
        return Math.max(0L, left + right);
    }

    private static boolean isPlausibleStoredTime(long value) {
        long now = System.currentTimeMillis();
        return value > 0L && value <= safeAdd(now, MAX_STORED_FUTURE_MS);
    }

    private static long retryDelay(int attempt) {
        int index = Math.max(0, Math.min(RETRY_DELAYS_MS.length - 1, attempt - 1));
        return RETRY_DELAYS_MS[index];
    }

    private static int utf8Length(String value) {
        return value == null ? 0 : value.getBytes(StandardCharsets.UTF_8).length;
    }

    private static SharedPreferences preferences(Context context) {
        return context.getApplicationContext().getSharedPreferences(
                PREFERENCE_FILE, Context.MODE_PRIVATE);
    }

    private static final class StoredRow {
        final String reportId;
        final String targetKey;
        final ReportPayload payload;
        final int tries;
        final long createdAt;
        final long nextAt;
        final int lastHttp;
        final String lastError;

        StoredRow(
                String reportId,
                String targetKey,
                ReportPayload payload,
                int tries,
                long createdAt,
                long nextAt,
                int lastHttp,
                String lastError) {
            this.reportId = reportId;
            this.targetKey = targetKey;
            this.payload = payload;
            this.tries = tries;
            this.createdAt = createdAt;
            this.nextAt = nextAt;
            this.lastHttp = lastHttp;
            this.lastError = lastError;
        }
    }

    private static final class StoredHistory {
        final String reportId;
        final String targetId;
        final String targetUser;
        final String outcome;
        final int tries;
        final long at;

        StoredHistory(
                String reportId,
                String targetId,
                String targetUser,
                String outcome,
                int tries,
                long at) {
            this.reportId = reportId;
            this.targetId = targetId;
            this.targetUser = targetUser;
            this.outcome = outcome;
            this.tries = tries;
            this.at = at;
        }
    }

    private static final class StoreStateException extends Exception {
        final String state;

        StoreStateException(String state) {
            this.state = state;
        }
    }

    private static final class DatabaseHelper extends SQLiteOpenHelper {
        DatabaseHelper(Context context) {
            super(
                    context,
                    DATABASE_NAME,
                    null,
                    DATABASE_VERSION,
                    new DatabaseErrorHandler() {
                        @Override
                        public void onCorruption(SQLiteDatabase database) {
                            throw new SQLiteException(
                                    "report database corruption requires review");
                        }
                    });
        }

        @Override
        public void onCreate(SQLiteDatabase db) {
            createOutboxV2(db);
            createOutboxDueIndex(db);
            db.execSQL(HISTORY_SQL);
            db.execSQL(HISTORY_INDEX_SQL);
        }

        @Override
        public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
            if (oldVersion != 1 || newVersion != 2) {
                throw new SQLiteException("report database upgrade requires reviewed migration");
            }

            // SQLiteOpenHelper owns the surrounding upgrade transaction. Every
            // check or copy failure throws, so the v1 bytes remain intact.
            requireMigrationIntegrity(db);
            requireSchemaObject(
                    db,
                    "table",
                    TABLE_OUTBOX,
                    new String[] {
                            "report_idtextprimarykeynotnull",
                            "viewer_keytextnotnull",
                            "target_keytextnotnull",
                            "payload_jsontextnotnull",
                            "triesintegernotnullcheck(triesbetween0and15)",
                            "created_atintegernotnullcheck(created_at>=0)",
                            "next_atintegernotnullcheck(next_at>=0)",
                            "last_httpintegernotnullcheck(last_http=0orlast_httpbetween100and599)",
                            "last_errortextnotnull",
                            "unique(viewer_key,target_key)"
                    });
            requireSchemaObject(
                    db,
                    "index",
                    "report_outbox_due_idx",
                    new String[] {"(viewer_key,next_at,created_at)"});
            requireSchemaObject(
                    db,
                    "table",
                    TABLE_HISTORY,
                    new String[] {
                            "row_idintegerprimarykeyautoincrement",
                            "report_idtextnotnull",
                            "viewer_keytextnotnull",
                            "unique(viewer_key,report_id)"
                    });
            requireSchemaObject(
                    db,
                    "index",
                    "report_history_viewer_idx",
                    new String[] {"(viewer_key,atdesc,row_iddesc)"});
            requireExactSchemaObject(db, "table", TABLE_OUTBOX, OUTBOX_V1_SQL);
            requireExactSchemaObject(
                    db,
                    "index",
                    "report_outbox_due_idx",
                    OUTBOX_DUE_INDEX_SQL);
            requireExactSchemaObject(db, "table", TABLE_HISTORY, HISTORY_SQL);
            requireExactSchemaObject(
                    db,
                    "index",
                    "report_history_viewer_idx",
                    HISTORY_INDEX_SQL);
            requireOwnedSchemaObjectCount(db, TABLE_OUTBOX, 4);
            requireOwnedSchemaObjectCount(db, TABLE_HISTORY, 3);

            long sourceRows = countAllRows(db, TABLE_OUTBOX);
            db.execSQL("DROP INDEX report_outbox_due_idx");
            db.execSQL("ALTER TABLE " + TABLE_OUTBOX + " RENAME TO report_outbox_v1");
            createOutboxV2(db);
            db.execSQL(
                    "INSERT INTO " + TABLE_OUTBOX
                            + " (report_id,viewer_key,target_key,payload_json,tries,created_at,"
                            + "next_at,last_http,last_error) "
                            + "SELECT report_id,viewer_key,target_key,payload_json,tries,created_at,"
                            + "next_at,last_http,last_error FROM report_outbox_v1");
            long copiedRows = countAllRows(db, TABLE_OUTBOX);
            if (copiedRows != sourceRows) {
                throw new SQLiteException("report database migration row count mismatch");
            }
            db.execSQL("DROP TABLE report_outbox_v1");
            createOutboxDueIndex(db);
            schemaValidated = false;
        }

        @Override
        public void onDowngrade(SQLiteDatabase db, int oldVersion, int newVersion) {
            throw new SQLiteException("report database downgrade is forbidden");
        }

        private static void createOutboxV2(SQLiteDatabase db) {
            db.execSQL(OUTBOX_V2_SQL);
        }

        private static void createOutboxDueIndex(SQLiteDatabase db) {
            db.execSQL(OUTBOX_DUE_INDEX_SQL);
        }

        private static void requireMigrationIntegrity(SQLiteDatabase db) {
            Cursor cursor = null;
            try {
                cursor = db.rawQuery("PRAGMA quick_check(1)", null);
                if (!cursor.moveToFirst()
                        || cursor.getType(0) != Cursor.FIELD_TYPE_STRING
                        || !"ok".equalsIgnoreCase(cursor.getString(0))) {
                    throw new SQLiteException("report database migration integrity check failed");
                }
            } finally {
                ReportStore.close(cursor);
            }
        }

        private static long countAllRows(SQLiteDatabase db, String table) {
            Cursor cursor = null;
            try {
                cursor = db.rawQuery("SELECT COUNT(*) FROM " + table, null);
                if (!cursor.moveToFirst()
                        || cursor.getType(0) != Cursor.FIELD_TYPE_INTEGER
                        || cursor.getLong(0) < 0L) {
                    throw new SQLiteException("report database migration count failed");
                }
                return cursor.getLong(0);
            } finally {
                ReportStore.close(cursor);
            }
        }
    }
}
