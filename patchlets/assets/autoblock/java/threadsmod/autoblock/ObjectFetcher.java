package threadsmod.autoblock;

import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.CookieHandler;
import java.net.URL;
import java.security.MessageDigest;

import javax.net.ssl.HttpsURLConnection;

/**
 * Fetches one content-addressed v3 blocklist object (a group table or a gzip NDJSON chunk)
 * from the reviewed mirror allowlist and proves its bytes against the name that the signed
 * root chain assigned to it.
 *
 * <p>This class carries no parser and no store reference. It returns the exact bytes whose
 * SHA-256 equals the object name, or a {@link StageFailure} whose per-mirror tokens come from
 * the same closed failure-class set as the signed-root fetch. Mirrors are consulted in the
 * caller's order (the winning root mirror first); a mirror is retried once only after a
 * transport failure and never after an HTTP status, oversized, cookie-refused, byte-count, or
 * hash result. Nothing that names a URL, header, object, or throwable ever reaches a log.</p>
 */
final class ObjectFetcher {
    private static final String TAG = "ThreadsModAutoBlock";
    private static final int READ_BUFFER_BYTES = 16 * 1024;
    private static final int OBJECT_HASH_HEX_LENGTH = 64;

    private ObjectFetcher() {}

    /**
     * Every allowlisted mirror failed (or refused) one object. {@code mirrorFailures} holds
     * one closed token per declared mirror in declared order and feeds the retained
     * "mirror N token" status grammar; {@code failureClass} is the token of the serving (or
     * last failed) mirror and is never null. The detail text is a fixed literal.
     */
    static final class StageFailure extends Exception {
        final String[] mirrorFailures;
        final String failureClass;

        StageFailure(String[] mirrorFailures, String failureClass) {
            super("signed objects could not be staged");
            this.mirrorFailures = mirrorFailures;
            this.failureClass = failureClass == null
                    ? AutoBlockSync.FAILURE_INTERNAL : failureClass;
        }
    }

    /** Exact bytes of one proven object plus the allowlisted mirror index that served them. */
    static final class Fetched {
        final int mirror;
        final byte[] bytes;

        Fetched(int mirror, byte[] bytes) {
            this.mirror = mirror;
            this.bytes = bytes;
        }
    }

    /**
     * Fetches one object from the first mirror in {@code mirrorOrder} that serves bytes whose
     * SHA-256 equals the object name. {@code exactBytes < 0} means "no exact byte count".
     */
    static byte[] fetch(int[] mirrorOrder, String name, String accept, int cap, int exactBytes)
            throws StageFailure {
        return fetchObject(mirrorOrder, name, accept, cap, exactBytes).bytes;
    }

    /**
     * Same as {@link #fetch} but also reports which mirror served the proven bytes, so a
     * later parse failure of signed content can be attributed to that mirror's status slot.
     */
    static Fetched fetchObject(
            int[] mirrorOrder, String name, String accept, int cap, int exactBytes)
            throws StageFailure {
        String[] mirrorFailures = new String[CloneBlockerEndpoints.blocklistMirrorCount()];
        String lastFailureClass = AutoBlockSync.FAILURE_INTERNAL;
        int attempts = mirrorOrder == null ? 0 : mirrorOrder.length;
        for (int position = 0; position < attempts; position++) {
            int mirror = mirrorOrder[position];
            if (mirror < 0 || mirror >= mirrorFailures.length) {
                continue;
            }
            try {
                return new Fetched(mirror, fetchMirror(mirror, name, accept, cap, exactBytes));
            } catch (Exception fetchError) {
                lastFailureClass = AutoBlockSync.classifyListFetchFailure(fetchError);
                mirrorFailures[mirror] = lastFailureClass;
                Log.w(TAG, "Object mirror " + (mirror + 1)
                        + " failed with a bounded local error.");
            }
        }
        throw new StageFailure(mirrorFailures, lastFailureClass);
    }

    /**
     * One immediate retry per mirror, only after a transport failure (the IOException
     * family). An HTTP status, oversized body, cookie refusal, byte-count mismatch, or hash
     * mismatch is never retried. Each try is a fresh connection.
     */
    private static byte[] fetchMirror(
            int mirror, String name, String accept, int cap, int exactBytes)
            throws Exception {
        try {
            return fetchOnce(mirror, name, accept, cap, exactBytes);
        } catch (Exception firstError) {
            if (!AutoBlockSync.isTransportFailure(firstError)) {
                throw firstError;
            }
            Log.w(TAG, "Object mirror " + (mirror + 1)
                    + " is retried once after a transport failure.");
        }
        return fetchOnce(mirror, name, accept, cap, exactBytes);
    }

    /**
     * One unconditional GET of {@code name} from one allowlisted mirror. The object name is
     * validated inside {@link CloneBlockerEndpoints#objectUrl} before any URL text exists.
     * The response Content-Type is never interpreted (CDNs vary); the bytes are bound by the
     * caller's cap, by the exact signed byte count when one is known, and by SHA-256 against
     * the name. {@code Accept-Encoding: identity} is mandatory: without it the platform client
     * adds gzip and transparently inflates a Content-Encoding hop, which would break the hash
     * of the received bytes and hide Content-Length.
     */
    static byte[] fetchOnce(int mirror, String name, String accept, int cap, int exactBytes)
            throws Exception {
        HttpsURLConnection connection = null;
        try {
            if (CookieHandler.getDefault() != null) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_COOKIE_REFUSED,
                        "object fetch refused while a process-wide CookieHandler is installed");
            }
            URL url = CloneBlockerEndpoints.objectUrl(mirror, name);
            String expectedHash = name.substring(0, OBJECT_HASH_HEX_LENGTH);
            connection = (HttpsURLConnection) url.openConnection();
            connection.setConnectTimeout(10000);
            connection.setReadTimeout(15000);
            connection.setInstanceFollowRedirects(false);
            connection.setUseCaches(false);
            connection.setRequestMethod("GET");
            connection.setRequestProperty("Accept", accept);
            connection.setRequestProperty("Accept-Encoding", "identity");

            if (CookieHandler.getDefault() != null) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_COOKIE_REFUSED,
                        "object fetch refused before connect because cookies could be inherited");
            }

            int status = connection.getResponseCode();
            if (status != HttpsURLConnection.HTTP_OK) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.httpFailureClass(status),
                        "object mirror rejected the request");
            }

            int contentLength = connection.getContentLength();
            if (contentLength > cap) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TOO_LARGE,
                        "object exceeds the local byte cap");
            }
            if (exactBytes >= 0 && contentLength >= 0 && contentLength != exactBytes) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_SCHEMA,
                        "chunk byte count differs from the signed group entry");
            }
            byte[] bytes;
            InputStream input = connection.getInputStream();
            try {
                bytes = readBounded(input, contentLength, cap);
            } finally {
                input.close();
            }
            if (exactBytes >= 0 && bytes.length != exactBytes) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_SCHEMA,
                        "chunk byte count differs from the signed group entry");
            }
            if (!sha256Hex(bytes).equals(expectedHash)) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_SIGNATURE,
                        "signed root names an object whose bytes do not match");
            }
            return bytes;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    /**
     * Reads the whole body under {@code cap}. Content-Length is only a sizing hint (it is -1
     * for chunked bodies); the cap is enforced on the bytes actually read. The result stays a
     * byte array so the hash is taken over exactly what the mirror sent.
     */
    private static byte[] readBounded(InputStream input, int sizeHint, int cap)
            throws Exception {
        int initialCapacity = sizeHint > 0 && sizeHint <= cap
                ? sizeHint : Math.min(Math.max(cap, 0), READ_BUFFER_BYTES);
        ByteArrayOutputStream output = new ByteArrayOutputStream(initialCapacity);
        byte[] buffer = new byte[READ_BUFFER_BYTES];
        int total = 0;
        while (true) {
            int read = input.read(buffer);
            if (read < 0) {
                break;
            }
            total += read;
            if (total > cap) {
                throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TOO_LARGE,
                        "object exceeds the local byte cap");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    /** Lowercase hex SHA-256 built with a nibble loop; no formatting helper is involved. */
    static String sha256Hex(byte[] bytes) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(bytes);
        StringBuilder hex = new StringBuilder(hash.length * 2);
        for (int i = 0; i < hash.length; i++) {
            int value = hash[i] & 0xff;
            hex.append(hexDigit(value >>> 4));
            hex.append(hexDigit(value & 0x0f));
        }
        return hex.toString();
    }

    private static char hexDigit(int nibble) {
        return (char) (nibble < 10 ? '0' + nibble : 'a' + (nibble - 10));
    }
}
