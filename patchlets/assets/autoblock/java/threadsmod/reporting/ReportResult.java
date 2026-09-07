package threadsmod.reporting;

/** Immediate, user-presentable result of explicitly accepting a report. */
public final class ReportResult {
    public static final String QUEUED = "queued";
    public static final String INVALID = "invalid";
    public static final String SELF_TARGET = "self_target";
    public static final String NOT_FOREGROUND = "not_foreground";
    public static final String OUTBOX_FULL = "outbox_full";
    public static final String OUTBOX_NEEDS_REVIEW = "outbox_needs_review";
    public static final String STORE_FAILED = "store_failed";

    public final String status;
    public final String reportId;
    public final String message;

    ReportResult(String status, String reportId, String message) {
        this.status = status == null ? INVALID : status;
        this.reportId = reportId == null ? "" : reportId;
        this.message = message == null ? "" : message;
    }

    public boolean isDurablyQueued() {
        return QUEUED.equals(status);
    }
}
