import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import net.i2p.crypto.eddsa.EdDSAEngine;
import net.i2p.crypto.eddsa.EdDSAPublicKey;
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable;
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec;

/** Host-side proof for the exact-payload extraction and Ed25519 envelope. */
public final class VerifierHarness {
    private static final String KEY =
            "fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk";
    private static final byte[] GROUP_ORDER_L = hex(
            "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");

    public static void main(String[] args) throws Exception {
        URL url = new URL(args.length == 0
                ? "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json"
                : args[0]);
        byte[] bodyBytes;
        try (InputStream in = url.openStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int total = 0;
            for (int n; (n = in.read(buffer)) >= 0; ) {
                total += n;
                if (total > 4 * 1024 * 1024) {
                    throw new IllegalStateException("oversized response");
                }
                out.write(buffer, 0, n);
            }
            bodyBytes = out.toByteArray();
        }
        String body = new String(bodyBytes, StandardCharsets.UTF_8);
        String payload = extractPayloadJson(body);
        Matcher sigMatch = Pattern.compile("\\\"sig\\\":\\\"([^\\\"]+)\\\"").matcher(body);
        if (payload == null || !sigMatch.find()) {
            throw new IllegalStateException("missing envelope fields");
        }
        String sig = sigMatch.group(1);
        boolean valid = verify(payload, sig);
        String tampered = payload.substring(0, payload.length() - 1) + " ";
        boolean tamperAccepted = verify(tampered, sig);
        byte[] canonicalSignature = Base64.getUrlDecoder().decode(sig);
        boolean nonCanonicalAccepted = verify(payload, malleateScalar(canonicalSignature));
        boolean shortSignatureAccepted = verify(
                payload,
                Arrays.copyOf(canonicalSignature, canonicalSignature.length - 1));
        if (!valid || tamperAccepted || nonCanonicalAccepted || shortSignatureAccepted) {
            throw new AssertionError("signature checks did not fail closed");
        }
        boolean v3Root = payload.contains("\"v\":3")
                && payload.contains("\"hash\":\"sha256-hi32\"")
                && payload.contains("\"threads\":{");
        if (!v3Root) {
            throw new AssertionError("verified payload is not a v3 blocklist root");
        }
        System.out.println("PASS signature=true tamper=false noncanonical=false short=false bytes=" + bodyBytes.length
                + " v3=true");
    }

    private static boolean verify(String payload, String signature) throws Exception {
        return verify(payload, Base64.getUrlDecoder().decode(signature));
    }

    private static boolean verify(String payload, byte[] signature) throws Exception {
        byte[] encodedKey = Base64.getUrlDecoder().decode(KEY);
        if (encodedKey.length != 32 || signature.length != 64) {
            return false;
        }
        EdDSAPublicKey key = new EdDSAPublicKey(
                new EdDSAPublicKeySpec(
                        encodedKey,
                        EdDSANamedCurveTable.ED_25519_CURVE_SPEC));
        EdDSAEngine verifier = new EdDSAEngine();
        verifier.initVerify(key);
        return verifier.verifyOneShot(payload.getBytes(StandardCharsets.UTF_8), signature);
    }

    private static byte[] malleateScalar(byte[] signature) {
        byte[] result = signature.clone();
        int carry = 0;
        for (int i = 0; i < 32; i++) {
            int sum = (result[32 + i] & 0xff) + (GROUP_ORDER_L[i] & 0xff) + carry;
            result[32 + i] = (byte) sum;
            carry = sum >>> 8;
        }
        return result;
    }

    private static byte[] hex(String value) {
        byte[] result = new byte[value.length() / 2];
        for (int i = 0; i < result.length; i++) {
            result[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return result;
    }

    private static String extractPayloadJson(String document) {
        int key = document.indexOf("\"payload\"");
        if (key < 0) return null;
        int colon = document.indexOf(':', key + 9);
        if (colon < 0) return null;
        int start = colon + 1;
        while (start < document.length() && Character.isWhitespace(document.charAt(start))) start++;
        if (start >= document.length()) return null;
        int end = scanJsonValue(document, start);
        return end <= start ? null : document.substring(start, end);
    }

    private static int scanJsonValue(String text, int start) {
        char first = text.charAt(start);
        if (first != '{' && first != '[') return -1;
        int depth = 0;
        boolean inString = false;
        boolean escaped = false;
        for (int i = start; i < text.length(); i++) {
            char c = text.charAt(i);
            if (inString) {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
                continue;
            }
            if (c == '"') inString = true;
            else if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') {
                depth--;
                if (depth == 0) return i + 1;
            }
        }
        return -1;
    }
}
