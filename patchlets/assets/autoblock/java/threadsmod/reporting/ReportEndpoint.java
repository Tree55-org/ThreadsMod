package threadsmod.reporting;

import java.net.URL;

/** Exact write allowlist owned only by the explicit combined-modal reporting patchlet. */
public final class ReportEndpoint {
    private static final String WRITE_URL =
            "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports";
    private static final String WRITE_HOST =
            "h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com";
    private static final String WRITE_PATH = "/v1/reports";
    private static final String STATS_URL =
            "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/installs";
    private static final String STATS_PATH = "/v1/installs";

    private ReportEndpoint() {}

    public static URL writeUrl() throws Exception {
        URL url = new URL(WRITE_URL);
        if (!"https".equalsIgnoreCase(url.getProtocol())
                || !WRITE_HOST.equalsIgnoreCase(url.getHost())
                || !WRITE_PATH.equals(url.getPath())
                || url.getPort() != -1
                || url.getUserInfo() != null
                || url.getQuery() != null
                || url.getRef() != null
                || !WRITE_URL.equals(url.toExternalForm())) {
            throw new SecurityException("report endpoint is not exactly allowlisted");
        }
        return url;
    }

    /**
     * The activation-statistics path on the same reviewed host. It carries only the closed
     * {@code InstallStatsPayload} field set and never a report, account, or target value.
     */
    public static URL statsUrl() throws Exception {
        URL url = new URL(STATS_URL);
        if (!"https".equalsIgnoreCase(url.getProtocol())
                || !WRITE_HOST.equalsIgnoreCase(url.getHost())
                || !STATS_PATH.equals(url.getPath())
                || url.getPort() != -1
                || url.getUserInfo() != null
                || url.getQuery() != null
                || url.getRef() != null
                || !STATS_URL.equals(url.toExternalForm())) {
            throw new SecurityException("statistics endpoint is not exactly allowlisted");
        }
        return url;
    }

    /** Validated endpoint text for the durable background delivery path. */
    public static String displayUrl() {
        try {
            return writeUrl().toExternalForm();
        } catch (Exception invalid) {
            throw new SecurityException("report endpoint cannot be displayed", invalid);
        }
    }
}
