package threadsmod.reporting;

import javax.net.ssl.HttpsURLConnection;

public final class ReportClient {
    private static HttpsURLConnection connection;

    public static Object post(Object payload, String viewerId, int attempt) throws Exception {
        connection.setRequestMethod("POST");
        return payload;
    }
}
