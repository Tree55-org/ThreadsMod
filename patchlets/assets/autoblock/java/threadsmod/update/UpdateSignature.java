package threadsmod.update;

import android.util.Base64;

import net.i2p.crypto.eddsa.EdDSAEngine;
import net.i2p.crypto.eddsa.EdDSAPublicKey;
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable;
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec;

import java.nio.charset.StandardCharsets;

/** Canonical Ed25519 verifier whose production entry always uses the pinned release key. */
final class UpdateSignature {
    static final String PRODUCTION_PUBLIC_KEY =
            "fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk";
    private static final byte[] GROUP_ORDER_L = hex(
            "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");

    private UpdateSignature() {}

    static boolean verifyProduction(String payload, String encodedSignature) throws Exception {
        if (payload == null) return false;
        byte[] signature = decodeCanonicalSignature(encodedSignature);
        if (signature == null) return false;
        byte[] key = Base64.decode(
                PRODUCTION_PUBLIC_KEY, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
        return verifyWithKey(key, payload.getBytes(StandardCharsets.UTF_8), signature);
    }

    static byte[] decodeCanonicalSignature(String encodedSignature) {
        if (encodedSignature == null
                || !encodedSignature.matches("^[A-Za-z0-9_-]{86}$")) return null;
        try {
            byte[] signature = Base64.decode(
                    encodedSignature, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
            if (signature.length != 64 || !encodedSignature.equals(Base64.encodeToString(
                    signature, Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP))) return null;
            return signature;
        } catch (Throwable invalidEncoding) {
            return null;
        }
    }

    /** Package-private pure seam used by the host harness with an RFC 8032 test key. */
    static boolean verifyWithKey(byte[] rawPublicKey, byte[] message, byte[] signature)
            throws Exception {
        if (rawPublicKey == null || rawPublicKey.length != 32 || message == null
                || signature == null || signature.length != 64
                || !isCanonicalScalar(signature)) return false;
        EdDSAPublicKey key = new EdDSAPublicKey(new EdDSAPublicKeySpec(
                rawPublicKey, EdDSANamedCurveTable.ED_25519_CURVE_SPEC));
        EdDSAEngine verifier = new EdDSAEngine();
        verifier.initVerify(key);
        return verifier.verifyOneShot(message, signature);
    }

    private static boolean isCanonicalScalar(byte[] signature) {
        for (int i = 31; i >= 0; i--) {
            int scalar = signature[32 + i] & 0xff;
            int order = GROUP_ORDER_L[i] & 0xff;
            if (scalar < order) return true;
            if (scalar > order) return false;
        }
        return false;
    }

    private static byte[] hex(String value) {
        byte[] result = new byte[value.length() / 2];
        for (int i = 0; i < result.length; i++) {
            result[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return result;
    }
}
