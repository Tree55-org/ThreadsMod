package threadsmod.reporting;

/** Callbacks from the combined modal's explicit report action. */
public interface ReportResultCallback {
    void onResult(ReportResult result);

    void onCancelled();
}
