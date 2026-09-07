package threadsmod.reporting;

import javax.net.ssl.HttpsURLConnection;

public final class ReportClient {
    private static HttpsURLConnection connection;

    public static Object post(Object payload, String viewerId, int attempt) throws Exception {
        String decoy = "POST";
        connection.setRequestMethod("GET");
        return decoy;
    }
}
