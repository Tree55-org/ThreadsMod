package threadsmod.reporting;

import javax.net.ssl.HttpsURLConnection;

public final class ReportClient {
    private static HttpsURLConnection connection;

    public static Object post(Object payload, String viewerId, int attempt) {
        return "POST";
    }

    public static void send() throws Exception {
        connection.setRequestMethod("POST");
    }
}
