package threadsmod.update;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URL;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** Immutable, signature-verified update policy and artifact description. */
public final class UpdateManifest {
    static final String APPLICATION_ID = "app.tree55.threads";
    static final String PURPOSE = "threadsmod-app-update";
    // Initial updater reuses the reviewed Clone Blocker Ed25519 key.
    static final String REQUIRED_SIGNER_SHA256 =
            "317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079";
    private static final long FUTURE_TOLERANCE_MS = 24L * 60L * 60L * 1000L;
    private static final long MAX_INTEGER = 2147483647L;
    private static final long MIN_APK_BYTES = 1024L * 1024L;
    static final long MAX_APK_BYTES = 200L * 1024L * 1024L;
    private static final DateTimeFormatter CANONICAL_TIMESTAMP =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
                    .withZone(ZoneOffset.UTC);

    final long revision;
    final long modBuild;
    final long minimumModBuild;
    final String publishedAt;
    final long publishedAtMs;
    final long versionCode;
    final String versionName;
    final String notes;
    final String apkName;
    final long apkSize;
    final String apkSha256;
    final String signerSha256;
    final List<URL> downloadUrls;
    final String signedPayload;
    final String envelope;

    private UpdateManifest(
            long revision, long modBuild, long minimumModBuild,
            String publishedAt, long publishedAtMs,
            long versionCode, String versionName, String notes,
            String apkName, long apkSize, String apkSha256,
            String signerSha256, List<URL> downloadUrls,
            String signedPayload, String envelope) {
        this.revision = revision;
        this.modBuild = modBuild;
        this.minimumModBuild = minimumModBuild;
        this.publishedAt = publishedAt;
        this.publishedAtMs = publishedAtMs;
        this.versionCode = versionCode;
        this.versionName = versionName;
        this.notes = notes;
        this.apkName = apkName;
        this.apkSize = apkSize;
        this.apkSha256 = apkSha256;
        this.signerSha256 = signerSha256;
        this.downloadUrls = downloadUrls;
        this.signedPayload = signedPayload;
        this.envelope = envelope;
    }

    public static UpdateManifest parseAndVerify(String document, long nowMs) throws Exception {
        return parseAndVerify(document, nowMs, true);
    }

    static UpdateManifest parseStored(String document) throws Exception {
        return parseAndVerify(document, 0L, false);
    }

    private static UpdateManifest parseAndVerify(
            String document, long nowMs, boolean enforceFutureBound) throws Exception {
        if (!UpdateJson.isCompleteObject(document)) {
            throw new SecurityException("update envelope is not strict JSON");
        }
        JSONObject root = new JSONObject(document);
        requireExactKeys(root, "payload", "sig", "alg");
        if (!"ed25519".equals(requireString(root, "alg", 16))) {
            throw new SecurityException("update signature algorithm is invalid");
        }
        String signature = requireString(root, "sig", 160);
        String payloadJson = UpdateJson.extractTopLevelValue(document, "payload");
        if (payloadJson == null || !UpdateSignature.verifyProduction(payloadJson, signature)) {
            throw new SecurityException("update signature verification failed");
        }
        JSONObject payload = new JSONObject(payloadJson);
        requireExactKeys(payload,
                "v", "purpose", "packageName", "revision", "publishedAt", "modBuild",
                "minimumModBuild", "versionCode", "versionName", "notes", "apkSize",
                "apkSha256", "signerSha256", "downloadUrls");
        if (requireLong(payload, "v") != 1L
                || !PURPOSE.equals(requireString(payload, "purpose", 64))) {
            throw new SecurityException("update payload purpose or schema is invalid");
        }
        String publishedAt = requireString(payload, "publishedAt", 64);
        long publishedAtMs = Instant.parse(publishedAt).toEpochMilli();
        if (!publishedAt.matches(
                "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")
                || publishedAtMs <= 0L
                || !publishedAt.equals(CANONICAL_TIMESTAMP.format(
                Instant.ofEpochMilli(publishedAtMs)))
                || enforceFutureBound
                && (nowMs > Long.MAX_VALUE - FUTURE_TOLERANCE_MS
                || publishedAtMs > nowMs + FUTURE_TOLERANCE_MS)) {
            throw new SecurityException("update publication timestamp is invalid");
        }
        if (!APPLICATION_ID.equals(requireString(payload, "packageName", 128))) {
            throw new SecurityException("update application id is invalid");
        }
        long revision = requirePositiveLong(payload, "revision");
        long modBuild = requirePositiveLong(payload, "modBuild");
        long minimumModBuild = requireLong(payload, "minimumModBuild");
        if (revision > MAX_INTEGER || modBuild > MAX_INTEGER
                || minimumModBuild < 0L || minimumModBuild > modBuild) {
            throw new SecurityException("update minimum mod build is invalid");
        }
        long versionCode = requirePositiveLong(payload, "versionCode");
        if (versionCode > MAX_INTEGER) {
            throw new SecurityException("update version code is invalid");
        }
        String versionName = requireString(payload, "versionName", 64);
        if (!versionName.matches("^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")) {
            throw new SecurityException("update version name is invalid");
        }
        String notes = requireStringAllowEmpty(payload, "notes", 2000);
        long apkSize = requirePositiveLong(payload, "apkSize");
        if (apkSize < MIN_APK_BYTES || apkSize > MAX_APK_BYTES) {
            throw new SecurityException("update artifact size is invalid");
        }
        String apkSha256 = requireString(payload, "apkSha256", 64);
        if (!apkSha256.matches("^[0-9a-f]{64}$")) {
            throw new SecurityException("update artifact hash is invalid");
        }
        String signerSha = requireString(payload, "signerSha256", 64);
        if (!REQUIRED_SIGNER_SHA256.equals(signerSha)) {
            throw new SecurityException("update signer pin is invalid");
        }
        Object urlsValue = payload.opt("downloadUrls");
        if (!(urlsValue instanceof JSONArray)) {
            throw new SecurityException("update artifact URLs are invalid");
        }
        JSONArray urlsJson = (JSONArray) urlsValue;
        if (urlsJson.length() < 2 || urlsJson.length() > 3) {
            throw new SecurityException("update artifact mirror count is invalid");
        }
        List<URL> urls = new ArrayList<URL>();
        Set<String> unique = new HashSet<String>();
        Set<Integer> providers = new HashSet<Integer>();
        String apkName = null;
        for (int i = 0; i < urlsJson.length(); i++) {
            Object value = urlsJson.opt(i);
            if (!(value instanceof String) || ((String) value).length() > 1024
                    || !unique.add((String) value)) {
                throw new SecurityException("update artifact mirror is invalid");
            }
            URL rawUrl = new URL((String) value);
            String path = rawUrl.getPath();
            int slash = path.lastIndexOf('/');
            String candidateName = slash < 0 ? "" : path.substring(slash + 1);
            if (!candidateName.matches("^[A-Za-z0-9][A-Za-z0-9._-]{0,150}\\.apk$")
                    || apkName != null && !apkName.equals(candidateName)) {
                throw new SecurityException("update artifact names do not agree");
            }
            apkName = candidateName;
            URL url = UpdateEndpoints.validateArtifactUrl((String) value, apkName);
            providers.add(UpdateEndpoints.artifactProvider(url));
            urls.add(url);
        }
        if (!providers.contains(UpdateEndpoints.PROVIDER_GITHUB)
                || !providers.contains(UpdateEndpoints.PROVIDER_AWS)) {
            throw new SecurityException("update artifacts lack independent providers");
        }
        return new UpdateManifest(
                revision, modBuild, minimumModBuild, publishedAt, publishedAtMs,
                versionCode, versionName, notes, apkName, apkSize,
                apkSha256, signerSha,
                urls, payloadJson, document);
    }

    boolean sameSignedRelease(UpdateManifest other) {
        return other != null && revision == other.revision && signedPayload.equals(other.signedPayload);
    }

    boolean sameBinary(UpdateManifest other) {
        return other != null && modBuild == other.modBuild
                && versionCode == other.versionCode
                && versionName.equals(other.versionName)
                && apkSize == other.apkSize
                && apkSha256.equals(other.apkSha256)
                && signerSha256.equals(other.signerSha256);
    }

    private static void requireExactKeys(JSONObject object, String... expected) {
        Set<String> remaining = new HashSet<String>();
        for (String name : expected) remaining.add(name);
        Iterator<String> names = object.keys();
        int count = 0;
        while (names.hasNext()) {
            count++;
            if (!remaining.remove(names.next())) {
                throw new SecurityException("update JSON contains an unknown field");
            }
        }
        if (count != expected.length || !remaining.isEmpty()) {
            throw new SecurityException("update JSON is missing a field");
        }
    }

    private static String requireString(JSONObject object, String name, int max) {
        String value = requireStringAllowEmpty(object, name, max);
        if (value.length() == 0) throw new SecurityException("update string is empty");
        return value;
    }

    private static String requireStringAllowEmpty(JSONObject object, String name, int max) {
        Object value = object.opt(name);
        if (!(value instanceof String)) throw new SecurityException("update string type is invalid");
        String text = (String) value;
        if (text.length() > max || !text.equals(text.trim())) {
            throw new SecurityException("update string bounds are invalid");
        }
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c <= 0x08 || c == 0x0b || c == 0x0c
                    || c >= 0x0e && c <= 0x1f || c == 0x7f) {
                throw new SecurityException("update string contains a control character");
            }
        }
        return text;
    }

    private static long requirePositiveLong(JSONObject object, String name) {
        long value = requireLong(object, name);
        if (value <= 0L) throw new SecurityException("update number is not positive");
        return value;
    }

    private static long requireLong(JSONObject object, String name) {
        Object value = object.opt(name);
        if (value instanceof Integer || value instanceof Long) return ((Number) value).longValue();
        throw new SecurityException("update number type is invalid");
    }
}
