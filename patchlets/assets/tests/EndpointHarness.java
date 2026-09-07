package threadsmod.autoblock;

import threadsmod.reporting.ReportEndpoint;

/** Host-side proof for the compiled read-mirror, object-name and consented-write allowlist. */
public final class EndpointHarness {
    private static final String ZERO64 = "0000000000000000000000000000000000000000000000000000000000000000";

    public static void main(String[] args) throws Exception {
        String[] expectedReads = new String[] {
                "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json",
                "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/manifest.json",
                "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/manifest.json"
        };
        String[] expectedObjectBases = new String[] {
                "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/objects/",
                "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/objects/",
                "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/objects/"
        };
        if (CloneBlockerEndpoints.blocklistMirrorCount() != expectedReads.length) {
            throw new AssertionError("unexpected blocklist mirror count");
        }
        if (ZERO64.length() != 64) {
            throw new AssertionError("harness object stem is not 64 characters");
        }
        String groupName = ZERO64 + ".json";
        String chunkName = ZERO64 + ".ndjson.gz";
        for (int i = 0; i < expectedReads.length; i++) {
            String actual = CloneBlockerEndpoints.manifestUrl(i).toExternalForm();
            if (!expectedReads[i].equals(actual)) {
                throw new AssertionError("unexpected read endpoint " + i + ": " + actual);
            }
            String actualGroup = CloneBlockerEndpoints.objectUrl(i, groupName).toExternalForm();
            if (!(expectedObjectBases[i] + groupName).equals(actualGroup)) {
                throw new AssertionError("unexpected group object endpoint " + i + ": " + actualGroup);
            }
            String actualChunk = CloneBlockerEndpoints.objectUrl(i, chunkName).toExternalForm();
            if (!(expectedObjectBases[i] + chunkName).equals(actualChunk)) {
                throw new AssertionError("unexpected chunk object endpoint " + i + ": " + actualChunk);
            }
            expectRejectedObjectName(i, "ABCDEF" + ZERO64.substring(6) + ".json");
            expectRejectedObjectName(i, "ABCDEF" + ZERO64.substring(6) + ".ndjson.gz");
            expectRejectedObjectName(i, ZERO64.substring(1) + ".json");
            expectRejectedObjectName(i, ZERO64 + "0" + ".json");
            expectRejectedObjectName(i, ZERO64.substring(1) + ".ndjson.gz");
            expectRejectedObjectName(i, ZERO64 + "0" + ".ndjson.gz");
            expectRejectedObjectName(i, ".." + ZERO64.substring(2) + ".json");
            expectRejectedObjectName(i, ".." + ZERO64.substring(2) + ".ndjson.gz");
            expectRejectedObjectName(i, "/" + ZERO64.substring(1) + ".json");
            expectRejectedObjectName(i, ZERO64.substring(1) + "/.json");
            expectRejectedObjectName(i, ZERO64 + ".gz.bak");
            expectRejectedObjectName(i, ZERO64 + ".json.json");
            expectRejectedObjectName(i, ZERO64 + ".JSON");
            expectRejectedObjectName(i, ZERO64);
            expectRejectedObjectName(i, "");
            expectRejectedObjectName(i, null);
        }
        expectRejectedMirrorIndex(-1, groupName);
        expectRejectedMirrorIndex(expectedReads.length, groupName);

        String expectedWrite =
                "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports";
        String actualWrite = ReportEndpoint.writeUrl().toExternalForm();
        if (!expectedWrite.equals(actualWrite)) {
            throw new AssertionError("unexpected write endpoint: " + actualWrite);
        }
        String expectedStats =
                "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/installs";
        String actualStats = ReportEndpoint.statsUrl().toExternalForm();
        if (!expectedStats.equals(actualStats)) {
            throw new AssertionError("unexpected statistics endpoint: " + actualStats);
        }
        if (actualStats.equals(actualWrite)) {
            throw new AssertionError("statistics and report paths must differ");
        }
        CloneBlockerEndpoints.validateConfiguration();
        System.out.println("PASS reads=3 write=" + actualWrite + " stats=" + actualStats);
    }

    private static void expectRejectedObjectName(int mirror, String name) throws Exception {
        boolean rejected = false;
        try {
            CloneBlockerEndpoints.objectUrl(mirror, name);
        } catch (SecurityException expected) {
            rejected = true;
        }
        if (!rejected) {
            throw new AssertionError("object name was not rejected for mirror " + mirror);
        }
    }

    private static void expectRejectedMirrorIndex(int mirror, String name) throws Exception {
        boolean manifestRejected = false;
        try {
            CloneBlockerEndpoints.manifestUrl(mirror);
        } catch (SecurityException expected) {
            manifestRejected = true;
        }
        boolean objectRejected = false;
        try {
            CloneBlockerEndpoints.objectUrl(mirror, name);
        } catch (SecurityException expected) {
            objectRejected = true;
        }
        if (!manifestRejected || !objectRejected) {
            throw new AssertionError("mirror index was not rejected: " + mirror);
        }
    }
}
