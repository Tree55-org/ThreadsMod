package threadsmod.update;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Arrays;
import java.util.Locale;

/** Host-only boundary checks for exact update endpoints and strict JSON framing. */
public final class UpdatePolicyHarness {
    private static final String[] METADATA = new String[] {
            "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/threadsmod-update.json",
            "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json",
            "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/threadsmod-update.json"
    };

    public static void main(String[] args) throws Exception {
        UpdateEndpoints.validateConfiguration();
        if (UpdateEndpoints.metadataMirrorCount() != METADATA.length) {
            throw new AssertionError("metadata mirror count drifted");
        }
        for (int i = 0; i < METADATA.length; i++) {
            if (!METADATA[i].equals(UpdateEndpoints.metadataMirror(i).toExternalForm())) {
                throw new AssertionError("metadata mirror order drifted");
            }
        }

        String apk = "ThreadsMod-415.0.0.26.77-threadsmod.2.apk";
        String github = "https://github.com/nsc55/cloneblocker-mirror/releases/download/mod-2/" + apk;
        String aws = "https://threadsmod-updates.s3.ap-southeast-1.amazonaws.com/" + apk;
        if (UpdateEndpoints.artifactProvider(UpdateEndpoints.validateArtifactUrl(github, apk))
                        != UpdateEndpoints.PROVIDER_GITHUB
                || UpdateEndpoints.artifactProvider(UpdateEndpoints.validateArtifactUrl(aws, apk))
                        != UpdateEndpoints.PROVIDER_AWS) {
            throw new AssertionError("artifact providers drifted");
        }
        if (UpdateEndpoints.artifactProvider(UpdateEndpoints.validateRedirect(
                UpdateEndpoints.validateArtifactUrl(github, apk),
                "https://release-assets.githubusercontent.com/12345/asset-token?sp=read",
                apk, 1)) != UpdateEndpoints.PROVIDER_GITHUB) {
            throw new AssertionError("same-provider GitHub redirect was rejected");
        }
        assertRejected("tree55 artifact",
                "https://tree55.com/releases/" + apk, apk, null);
        assertRejected("HTTP artifact",
                "http://github.com/nsc55/cloneblocker-mirror/releases/download/mod-2/" + apk,
                apk, null);
        assertRejected("cross-provider redirect", github, apk, aws);
        assertRejected("private-IP artifact", "https://127.0.0.1/" + apk, apk, null);
        assertRejected("initial query", github + "?download=1", apk, null);
        assertRejected("empty initial query", github + "?", apk, null);
        assertRejected("initial fragment", github + "#sha256", apk, null);
        assertRejected("empty initial fragment", github + "#", apk, null);
        assertRejected("initial user-info",
                "https://user@github.com/nsc55/cloneblocker-mirror/releases/download/mod-2/"
                        + apk, apk, null);
        assertRejected("empty initial user-info",
                "https://@github.com/nsc55/cloneblocker-mirror/releases/download/mod-2/"
                        + apk, apk, null);
        assertRejected("short S3 bucket",
                "https://ab.s3.ap-southeast-1.amazonaws.com/" + apk, apk, null);
        assertRejected("long S3 bucket",
                "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        + ".s3.ap-southeast-1.amazonaws.com/" + apk, apk, null);
        assertRejected("numeric S3 bucket",
                "https://127.0.0.1.s3.ap-southeast-1.amazonaws.com/" + apk, apk, null);
        assertRejected("empty S3 label",
                "https://bad..bucket.s3.ap-southeast-1.amazonaws.com/" + apk, apk, null);
        assertRejected("trailing-hyphen S3 label",
                "https://bad-.bucket.s3.ap-southeast-1.amazonaws.com/" + apk, apk, null);
        assertRejected("greedy S3 prefix",
                "https://foo.s3.bad-.s3.ap-southeast-1.amazonaws.com/" + apk, apk, null);
        assertRedirectRejected(
                "HTTP redirect", github, apk, "http://release-assets.githubusercontent.com/a", 1);
        assertRedirectRejected(
                "over-hop redirect", github, apk,
                "https://release-assets.githubusercontent.com/a", 4);
        assertRejected("oversized initial URL",
                "https://github.com/nsc55/cloneblocker-mirror/releases/download/"
                        + repeat('a', 1100) + "/" + apk, apk, null);
        assertRedirectRejected("oversized redirect Location", github, apk,
                "https://release-assets.githubusercontent.com/" + repeat('a', 4200), 1);
        assertRedirectRejected("oversized redirect path", github, apk,
                "https://release-assets.githubusercontent.com/" + repeat('a', 2100), 1);
        assertRedirectRejected("oversized redirect query", github, apk,
                "https://release-assets.githubusercontent.com/a?q=" + repeat('a', 2100), 1);

        String strict = "{\"payload\":{\"v\":1},\"sig\":\"x\",\"alg\":\"ed25519\"}";
        if (!UpdateJson.isCompleteObject(strict)
                || !"{\"v\":1}".equals(UpdateJson.extractTopLevelValue(strict, "payload"))) {
            throw new AssertionError("strict update JSON was rejected");
        }
        String supplementary = "{\"notes\":\"🚀\"}";
        if (!UpdateJson.isCompleteObject(supplementary)) {
            throw new AssertionError("valid supplementary Unicode JSON was rejected");
        }
        for (String invalid : Arrays.asList(
                strict + " trailing",
                "{\"payload\":{},\"payload\":{},\"sig\":\"x\",\"alg\":\"ed25519\"}",
                "{\"payload\":{\"v\":01},\"sig\":\"x\",\"alg\":\"ed25519\"}",
                "{\"payload\":[\"\\uD800\"],\"sig\":\"x\",\"alg\":\"ed25519\"}")) {
            if (UpdateJson.isCompleteObject(invalid)) {
                throw new AssertionError("non-strict update JSON was accepted");
            }
        }
        byte[] malformedUtf8 = new byte[] {(byte) 0xc3, (byte) 0x28};
        if (UpdateJson.decodeUtf8(malformedUtf8) != null
                || !strict.equals(UpdateJson.decodeUtf8(strict.getBytes(StandardCharsets.UTF_8)))) {
            throw new AssertionError("update UTF-8 boundary drifted");
        }
        assertCanonicalTimestamp("2026-09-03T12:34:56.789Z", true);
        assertCanonicalTimestamp("2026-09-03T12:34:56Z", false);
        assertCanonicalTimestamp("2026-09-03T12:34:56.789+00:00", false);
        assertCanonicalTimestamp("2026-09-03T12:34:56.7890Z", false);
        assertCanonicalTimestamp("2026-09-03T12:34:56.789z", false);
        System.out.println(
                "PASS update-policy metadata=3 providers=github,aws redirects=same-provider json=strict utf8=strict");
    }

    private static void assertRejected(
            String label, String initial, String apk, String redirect) throws Exception {
        try {
            if (redirect == null) {
                UpdateEndpoints.validateArtifactUrl(initial, apk);
            } else {
                UpdateEndpoints.validateRedirect(
                        UpdateEndpoints.validateArtifactUrl(initial, apk), redirect, apk, 1);
            }
        } catch (SecurityException expected) {
            return;
        }
        throw new AssertionError(label + " was accepted");
    }

    private static void assertRedirectRejected(
            String label, String initial, String apk, String redirect, int hop) throws Exception {
        try {
            UpdateEndpoints.validateRedirect(
                    UpdateEndpoints.validateArtifactUrl(initial, apk), redirect, apk, hop);
        } catch (SecurityException expected) {
            return;
        }
        throw new AssertionError(label + " was accepted");
    }

    private static void assertCanonicalTimestamp(String value, boolean expected) {
        boolean accepted = false;
        try {
            DateTimeFormatter formatter = DateTimeFormatter
                    .ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
                    .withZone(ZoneOffset.UTC);
            long epoch = Instant.parse(value).toEpochMilli();
            accepted = value.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}T"
                    + "[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z")
                    && value.equals(formatter.format(Instant.ofEpochMilli(epoch)));
        } catch (RuntimeException rejected) {
            accepted = false;
        }
        if (accepted != expected) {
            throw new AssertionError("canonical timestamp result drifted: " + value);
        }
    }

    private static String repeat(char value, int count) {
        char[] values = new char[count];
        Arrays.fill(values, value);
        return new String(values);
    }
}
