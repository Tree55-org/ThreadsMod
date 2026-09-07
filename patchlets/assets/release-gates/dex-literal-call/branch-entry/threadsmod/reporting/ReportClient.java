package threadsmod.reporting;

import javax.net.ssl.HttpsURLConnection;

public final class ReportClient {
    private static HttpsURLConnection connection;

    public static Object post(Object payload, String viewerId, int attempt) throws Exception {
        String method;
        if (attempt == 0) {
            method = "GET";
        } else {
            method = "POST";
        }
        connection.setRequestMethod(method);
        return payload;
    }
}
