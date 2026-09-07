package threadsmod.update;

import android.util.Base64;

import java.util.Arrays;

/** RFC 8032 Ed25519 vector plus tamper/canonical-scalar negative checks. */
public final class UpdateSignatureHarness {
    public static void main(String[] args) throws Exception {
        byte[] publicKey = hex(
                "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
        byte[] signature = hex(
                "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                        + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
        if (!UpdateSignature.verifyWithKey(publicKey, new byte[0], signature)) {
            throw new AssertionError("RFC 8032 positive vector failed");
        }
        byte[] tampered = signature.clone();
        tampered[0] ^= 1;
        if (UpdateSignature.verifyWithKey(publicKey, new byte[0], tampered)) {
            throw new AssertionError("tampered update signature was accepted");
        }
        byte[] noncanonical = signature.clone();
        byte[] order = hex(
                "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");
        System.arraycopy(order, 0, noncanonical, 32, order.length);
        if (UpdateSignature.verifyWithKey(publicKey, new byte[0], noncanonical)) {
            throw new AssertionError("noncanonical update signature scalar was accepted");
        }
        int flags = Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP;
        String canonicalEncoding = Base64.encodeToString(signature, flags);
        if (!Arrays.equals(
                signature, UpdateSignature.decodeCanonicalSignature(canonicalEncoding))) {
            throw new AssertionError("canonical update signature encoding was rejected");
        }
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        int last = alphabet.indexOf(canonicalEncoding.charAt(canonicalEncoding.length() - 1));
        String alias = canonicalEncoding.substring(0, canonicalEncoding.length() - 1)
                + alphabet.charAt(last + 1);
        if (!Arrays.equals(signature, Base64.decode(alias, flags))
                || UpdateSignature.decodeCanonicalSignature(alias) != null) {
            throw new AssertionError("noncanonical base64url signature alias was accepted");
        }
        System.out.println("PASS update-signature rfc8032=true tamper=false noncanonical=false");
    }

    private static byte[] hex(String value) {
        byte[] result = new byte[value.length() / 2];
        for (int i = 0; i < result.length; i++) {
            result[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return result;
    }
}
