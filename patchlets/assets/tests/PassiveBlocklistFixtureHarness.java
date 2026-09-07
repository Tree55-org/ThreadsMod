import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

import net.i2p.crypto.eddsa.EdDSAEngine;
import net.i2p.crypto.eddsa.EdDSAPublicKey;
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable;
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec;

/**
 * Host proof for the chunked v3 blocklist fixture: the Ed25519-signed root, its
 * content-addressed group table and gzip NDJSON chunks, bucket placement, and the
 * passive ID/username import boundary. Compiled without android.jar, so it uses only
 * the JDK plus the pinned Ed25519 library.
 */
public final class PassiveBlocklistFixtureHarness {
    private static final long SIGNED_LIST_MAX_AGE_MS = 30L * 24L * 60L * 60L * 1000L;
    private static final long MAX_FUTURE_MS = 24L * 60L * 60L * 1000L;
    // CloneBlocker's raw 32-byte Ed25519 public key, identical to AutoBlockSync.LIST_KEY_RAW.
    private static final String KEY = "fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk";
    private static final String PLATFORM = "threads";
    private static final String HASH_SCHEME = "sha256-hi32";
    private static final String GROUP_SUFFIX = ".json";
    private static final String CHUNK_SUFFIX = ".ndjson.gz";
    private static final String OBJECTS_DIRECTORY = "objects";
    // Local caps, identical to the AutoBlockSync v3 limits.
    private static final int MAX_ROOT_BYTES = 512 * 1024;
    private static final int MAX_GROUP_BYTES = 64 * 1024;
    private static final int MAX_CHUNK_GZ_BYTES = 256 * 1024;
    private static final int MAX_CHUNK_INFLATED_BYTES = 4 * 1024 * 1024;
    private static final int MAX_CHUNK_ROWS = 8192;
    private static final int MAX_INDEX_ROWS = 2000000;
    private static final int MAX_BUCKET_BITS = 16;
    private static final int MAX_GROUP_BITS = 8;
    private static final int MAX_FIXTURE_OBJECTS = 4096;
    private static final int MAX_JSON_DEPTH = 16;
    private static final int MAX_BUCKET_SEARCH = 100000;

    public static void main(String[] args) throws Exception {
        runFocusedBoundaryCases();
        File manifest = new File(args[0]).getAbsoluteFile();
        byte[] rootBytes = readBounded(manifest, MAX_ROOT_BYTES);
        Map<String, byte[]> objects =
                readObjects(new File(manifest.getParentFile(), OBJECTS_DIRECTORY));
        Root root = parseRoot(verifyEnvelope(rootBytes));
        Set<String> referenced = new HashSet<String>();
        RowCounts counts = validatePartition(
                root.partition, root.maxChunkRows, root.maxChunkBytes, objects, referenced);
        if (!referenced.equals(objects.keySet())) {
            throw new AssertionError(
                    "fixture objects directory does not hold exactly the referenced objects");
        }
        if (counts.chunks == 0 || counts.idRows == 0 || counts.handleRows == 0) {
            throw new AssertionError("captured fixture lost its chunk, id, or handle-only rows");
        }
        System.out.println("PASS passive-fixture-v3 k=" + root.partition.bucketBits
                + " chunks=" + counts.chunks
                + " idRows=" + counts.idRows
                + " handleRows=" + counts.handleRows
                + " unique=" + counts.uniqueIds);
    }

    // ---- signed root -------------------------------------------------------------------

    /** Proves the envelope and returns the exact signed payload text. */
    private static String verifyEnvelope(byte[] rootBytes) throws Exception {
        if (rootBytes.length > MAX_ROOT_BYTES) {
            throw reject("signed root exceeds the local byte cap");
        }
        String body = decodeUtf8(rootBytes, "signed root");
        Map<String, Object> envelope = requireObject(Json.parse(body), "signed root envelope");
        if (!"ed25519".equalsIgnoreCase(requireString(envelope.get("alg"), "signed root alg"))) {
            throw reject("signed root algorithm is not Ed25519");
        }
        String signature = requireString(envelope.get("sig"), "signed root sig");
        if (signature.length() < 40 || signature.length() > 160) {
            throw reject("signed root signature is malformed");
        }
        String payloadJson = extractPayloadJson(body);
        if (payloadJson == null || payloadJson.length() == 0) {
            throw reject("signed root payload is missing");
        }
        boolean valid;
        try {
            valid = verify(payloadJson, signature);
        } catch (IllegalArgumentException malformedEncoding) {
            valid = false;
        }
        if (!valid) {
            throw reject("signed root signature verification failed");
        }
        String tampered = payloadJson.substring(0, payloadJson.length() - 1) + " ";
        if (verify(tampered, signature)) {
            throw reject("tampered signed root payload was accepted");
        }
        return payloadJson;
    }

    private static Root parseRoot(String payloadJson) {
        Map<String, Object> payload = requireObject(Json.parse(payloadJson), "signed root payload");
        if (requireInt(payload.get("v"), "signed root version") != 3) {
            throw reject("signed root version is not 3");
        }
        String updatedAt = requireString(payload.get("updatedAt"), "signed root updatedAt");
        long publishedAtMs = parseInstant(updatedAt);
        if (publishedAtMs <= 0L
                || !validVerifiedTimestamp(
                        updatedAt, publishedAtMs, publishedAtMs + 60L * 60L * 1000L)) {
            throw reject("signed root updatedAt does not bind to its epoch milliseconds");
        }
        if (!HASH_SCHEME.equals(requireString(payload.get("hash"), "signed root hash scheme"))) {
            throw reject("signed root hash scheme is not sha256-hi32");
        }
        int maxChunkRows = requireInt(payload.get("maxChunkRows"), "signed root maxChunkRows");
        int maxChunkBytes = requireInt(payload.get("maxChunkBytes"), "signed root maxChunkBytes");
        if (maxChunkRows < 1 || maxChunkRows > MAX_CHUNK_ROWS) {
            throw reject("signed root maxChunkRows is outside the local cap");
        }
        if (maxChunkBytes < 1 || maxChunkBytes > MAX_CHUNK_GZ_BYTES) {
            throw reject("signed root maxChunkBytes is outside the local cap");
        }
        Map<String, Object> platforms =
                requireObject(payload.get("platforms"), "signed root platforms");
        Partition partition = parsePartition(
                requireObject(platforms.get(PLATFORM), "signed root threads partition"));
        return new Root(updatedAt, publishedAtMs, maxChunkRows, maxChunkBytes, partition);
    }

    private static Partition parsePartition(Map<String, Object> value) {
        int bucketBits = requireInt(value.get("k"), "partition bucket bits");
        int groupBits = requireInt(value.get("g"), "partition group bits");
        int total = requireInt(value.get("total"), "partition total");
        if (bucketBits < 0 || bucketBits > MAX_BUCKET_BITS) {
            throw reject("partition bucket bits are outside the local cap");
        }
        if (groupBits < 0 || groupBits > MAX_GROUP_BITS || groupBits > bucketBits) {
            throw reject("partition group bits are outside the local cap");
        }
        if (total < 0 || total > MAX_INDEX_ROWS) {
            throw reject("partition total is outside the local cap");
        }
        List<Object> groupValues = requireArray(value.get("groups"), "partition groups");
        if (groupValues.size() != 1 << groupBits) {
            throw reject("partition group count does not match its group bits");
        }
        String[] groups = new String[groupValues.size()];
        Set<String> distinct = new HashSet<String>();
        for (int index = 0; index < groups.length; index++) {
            groups[index] = requireHex64(groupValues.get(index), "partition group name");
            if (!distinct.add(groups[index])) {
                throw reject("partition group names repeat");
            }
        }
        return new Partition(bucketBits, groupBits, total, groups);
    }

    // ---- group tables and chunks -------------------------------------------------------

    /**
     * Stages every group table and chunk of one partition the way the client does: the
     * content address is proven before a group table is parsed or a chunk is inflated, the
     * byte count is proven before inflating, inflation is capped, every row is parsed on its
     * own line, and ids/usernames stay unique across the whole build.
     */
    private static RowCounts validatePartition(
            Partition partition, int maxChunkRows, int maxChunkBytes,
            Map<String, byte[]> objects, Set<String> referenced) {
        Set<String> ids = new HashSet<String>();
        Set<String> usernames = new HashSet<String>();
        Set<String> chunkNames = new HashSet<String>();
        RowCounts counts = new RowCounts();
        int chunksPerGroup = 1 << (partition.bucketBits - partition.groupBits);
        long rows = 0L;
        for (int group = 0; group < partition.groups.length; group++) {
            byte[] tableBytes = requireContent(
                    objects, partition.groups[group] + GROUP_SUFFIX, MAX_GROUP_BYTES, referenced);
            Map<String, Object> table = requireObject(
                    Json.parse(decodeUtf8(tableBytes, "group table")), "group table");
            if (requireInt(table.get("v"), "group table version") != 3) {
                throw reject("group table version is not 3");
            }
            if (!PLATFORM.equals(requireString(table.get("platform"), "group table platform"))) {
                throw reject("group table platform does not match the partition");
            }
            if (requireInt(table.get("k"), "group table bucket bits") != partition.bucketBits) {
                throw reject("group table bucket bits do not match the partition");
            }
            if (requireInt(table.get("g"), "group table group bits") != partition.groupBits) {
                throw reject("group table group bits do not match the partition");
            }
            if (requireInt(table.get("group"), "group table index") != group) {
                throw reject("group table index does not match its position");
            }
            List<Object> entries = requireArray(table.get("chunks"), "group table chunks");
            if (entries.size() != chunksPerGroup) {
                throw reject("group table chunk count does not match its bucket bits");
            }
            for (int index = 0; index < chunksPerGroup; index++) {
                Object entry = entries.get(index);
                if (entry == null) {
                    continue;
                }
                List<Object> triple = requireArray(entry, "chunk entry");
                if (triple.size() != 3) {
                    throw reject("chunk entry is not a sha/rows/bytes triple");
                }
                String sha = requireHex64(triple.get(0), "chunk sha");
                int entryRows = requireInt(triple.get(1), "chunk entry rows");
                int entryBytes = requireInt(triple.get(2), "chunk entry bytes");
                if (entryRows < 1 || entryRows > maxChunkRows) {
                    throw reject("chunk entry rows are outside the signed cap");
                }
                if (entryBytes < 1 || entryBytes > maxChunkBytes) {
                    throw reject("chunk entry bytes are outside the signed cap");
                }
                if (!chunkNames.add(sha)) {
                    throw reject("chunk sha repeats across the partition");
                }
                int bucket = (group << (partition.bucketBits - partition.groupBits)) + index;
                byte[] compressed =
                        requireContent(objects, sha + CHUNK_SUFFIX, maxChunkBytes, referenced);
                if (compressed.length != entryBytes) {
                    throw reject("chunk byte count does not match its group entry");
                }
                String text = decodeUtf8(
                        inflateBounded(compressed, MAX_CHUNK_INFLATED_BYTES), "chunk");
                validateChunkRows(
                        text, bucket, partition.bucketBits, entryRows, ids, usernames, counts);
                counts.chunks++;
                rows += entryRows;
            }
        }
        if (rows != partition.total) {
            throw reject("partition total does not match the staged row count");
        }
        counts.uniqueIds = ids.size();
        return counts;
    }

    private static void validateChunkRows(
            String text, int bucket, int bits, int expectedRows,
            Set<String> ids, Set<String> usernames, RowCounts counts) {
        if (text.indexOf('\r') >= 0) {
            throw reject("chunk carries a carriage return");
        }
        int rows = 0;
        int start = 0;
        int length = text.length();
        while (start < length) {
            int end = text.indexOf('\n', start);
            if (end < 0) {
                end = length;
            }
            if (end == start) {
                throw reject("chunk carries an empty line");
            }
            if (++rows > expectedRows) {
                throw reject("chunk row count does not match its group entry");
            }
            validateRow(text.substring(start, end), bucket, bits, ids, usernames, counts);
            start = end + 1;
        }
        if (rows != expectedRows) {
            throw reject("chunk row count does not match its group entry");
        }
    }

    private static void validateRow(
            String line, int bucket, int bits,
            Set<String> ids, Set<String> usernames, RowCounts counts) {
        Map<String, Object> row = requireObject(Json.parse(line), "chunk row");
        for (String key : row.keySet()) {
            if (!"i".equals(key) && !"u".equals(key) && !"d".equals(key) && !"t".equals(key)) {
                throw reject("chunk row carries an unknown key");
            }
        }
        String published = requireString(row.get("u"), "chunk row username");
        String username = cleanSignedUsername(published);
        if (username.length() == 0) {
            throw reject("chunk row username is malformed");
        }
        String key;
        if (row.containsKey("i")) {
            String id = requireString(row.get("i"), "chunk row id");
            if (!numericId(id)) {
                throw reject("chunk row id is malformed");
            }
            if (!ids.add(id)) {
                throw reject("chunk row id repeats an earlier row");
            }
            key = "threads:" + id;
            counts.idRows++;
        } else {
            key = "threads:@" + published;
            counts.handleRows++;
        }
        if (!usernames.add(username.toLowerCase(Locale.US))) {
            throw reject("chunk row username collides with an earlier row");
        }
        if (bucketOf(key, bits) != bucket) {
            throw reject("chunk row is staged in the wrong bucket");
        }
    }

    /** First 4 bytes of SHA-256(UTF-8 key) as an unsigned big-endian value. */
    private static long bucketHash(String key) {
        byte[] digest = sha256(key.getBytes(StandardCharsets.UTF_8));
        return ((digest[0] & 0xffL) << 24)
                | ((digest[1] & 0xffL) << 16)
                | ((digest[2] & 0xffL) << 8)
                | (digest[3] & 0xffL);
    }

    private static int bucketOf(String key, int bits) {
        long h32 = bucketHash(key);
        return bits == 0 ? 0 : (int) (h32 >>> (32 - bits));
    }

    /** Strips one leading '@' and returns "" unless the rest is a canonical username. */
    private static String cleanSignedUsername(String raw) {
        String value = raw.startsWith("@") ? raw.substring(1) : raw;
        return value.matches("[A-Za-z0-9._]{1,64}") ? value : "";
    }

    private static boolean numericId(String value) {
        return value.matches("[1-9][0-9]{3,23}");
    }

    // ---- focused boundary cases --------------------------------------------------------

    private static void runFocusedBoundaryCases() throws Exception {
        String zeroSha = sha256Hex(new byte[0]);
        Root root = parseRoot(rootJson(3, HASH_SCHEME, 4, 0, "[\"" + zeroSha + "\"]"));
        if (root.partition.bucketBits != 4 || root.partition.groupBits != 0
                || root.partition.total != 1 || root.partition.groups.length != 1
                || root.maxChunkRows != MAX_CHUNK_ROWS || root.maxChunkBytes != MAX_CHUNK_GZ_BYTES) {
            throw new AssertionError("valid root payload was misread");
        }
        assertRootRejected(
                "wrong root version",
                rootJson(2, HASH_SCHEME, 4, 0, "[\"" + zeroSha + "\"]"),
                "signed root version is not 3");
        assertRootRejected(
                "wrong hash scheme",
                rootJson(3, "sha256-lo32", 4, 0, "[\"" + zeroSha + "\"]"),
                "signed root hash scheme is not sha256-hi32");
        assertRootRejected(
                "bucket bits over the cap",
                rootJson(3, HASH_SCHEME, 17, 0, "[\"" + zeroSha + "\"]"),
                "partition bucket bits are outside the local cap");
        assertRootRejected(
                "group bits over bucket bits",
                rootJson(3, HASH_SCHEME, 4, 5, "[\"" + zeroSha + "\"]"),
                "partition group bits are outside the local cap");
        assertRootRejected(
                "group count mismatch",
                rootJson(3, HASH_SCHEME, 4, 1, "[\"" + zeroSha + "\"]"),
                "partition group count does not match its group bits");
        assertRootRejected(
                "malformed group name",
                rootJson(3, HASH_SCHEME, 4, 0, "[\"" + zeroSha.toUpperCase(Locale.US) + "\"]"),
                "partition group name is not 64 lowercase hex characters");
        assertRootRejected(
                "missing threads partition",
                "{\"v\":3,\"updatedAt\":\"2026-09-06T07:14:05.577Z\",\"hash\":\"sha256-hi32\","
                        + "\"maxChunkRows\":8192,\"maxChunkBytes\":262144,\"platforms\":{}}",
                "signed root threads partition is not a JSON object");
        assertRootRejected(
                "duplicate root key",
                "{\"v\":3,\"v\":3}",
                "JSON object repeats a key");

        SyntheticBuild valid = new SyntheticBuild(0);
        valid.chunk(lines(idRow("1000", "Alpha"), idRow("2000", "BRAVO")));
        RowCounts validCounts = validate(valid, valid.partition(), MAX_CHUNK_ROWS);
        if (validCounts.idRows != 2 || validCounts.uniqueIds != 2 || validCounts.chunks != 1) {
            throw new AssertionError("valid case-normalized unique rows were rejected");
        }

        SyntheticBuild duplicateObject = new SyntheticBuild(0);
        duplicateObject.chunk(lines(idRow("1000", "alpha"), idRow("1000", "alpha")));
        assertPartitionRejected(
                "duplicate target object", duplicateObject,
                "chunk row id repeats an earlier row");

        SyntheticBuild duplicateId = new SyntheticBuild(0);
        duplicateId.chunk(lines(idRow("1000", "alpha"), idRow("1000", "bravo")));
        assertPartitionRejected(
                "duplicate id in a chunk", duplicateId,
                "chunk row id repeats an earlier row");

        SyntheticBuild collision = new SyntheticBuild(0);
        collision.chunk(lines(idRow("1000", "Alpha"), idRow("2000", "aLPHA")));
        assertPartitionRejected(
                "normalized username collision", collision,
                "chunk row username collides with an earlier row");

        SyntheticBuild crossChunkCollision = new SyntheticBuild(1);
        crossChunkCollision.chunk(lines(idRow(idForBucket(1, 0), "Alpha")));
        crossChunkCollision.chunk(lines(idRow(idForBucket(1, 1), "ALPHA")));
        assertPartitionRejected(
                "normalized username collision across chunks", crossChunkCollision,
                "chunk row username collides with an earlier row");

        SyntheticBuild handleCollision = new SyntheticBuild(0);
        handleCollision.chunk(lines(idRow("1000", "alpha"), handleRow("@Alpha")));
        assertPartitionRejected(
                "handle-only row colliding with an id row", handleCollision,
                "chunk row username collides with an earlier row");

        SyntheticBuild wrongBucket = new SyntheticBuild(1);
        wrongBucket.chunk(lines(idRow(idForBucket(1, 1), "alpha")));
        wrongBucket.empty();
        assertPartitionRejected(
                "row in the wrong bucket", wrongBucket,
                "chunk row is staged in the wrong bucket");

        SyntheticBuild wrongHandleBucket = new SyntheticBuild(1);
        wrongHandleBucket.empty();
        wrongHandleBucket.chunk(lines(handleRow(handleForBucket(1, 0))));
        assertPartitionRejected(
                "handle-only row in the wrong bucket", wrongHandleBucket,
                "chunk row is staged in the wrong bucket");

        SyntheticBuild rowCount = new SyntheticBuild(0);
        rowCount.chunk(lines(idRow("1000", "alpha")), 2, 0);
        assertPartitionRejected(
                "row-count mismatch", rowCount,
                "chunk row count does not match its group entry");

        SyntheticBuild byteCount = new SyntheticBuild(0);
        byteCount.chunk(lines(idRow("1000", "alpha")), 1, 1);
        assertPartitionRejected(
                "byte-count mismatch", byteCount,
                "chunk byte count does not match its group entry");

        SyntheticBuild shaMismatch = new SyntheticBuild(0);
        shaMismatch.garbage(zeroSha, 1);
        assertPartitionRejected(
                "sha mismatch", shaMismatch,
                "object content does not match its content address");

        SyntheticBuild missingObject = new SyntheticBuild(0);
        missingObject.chunk(lines(idRow("1000", "alpha")));
        Partition missingPartition = missingObject.partition();
        missingObject.objects.clear();
        assertPartitionRejected(
                "missing group object", missingPartition, missingObject.objects, MAX_CHUNK_ROWS,
                "referenced object is missing from the fixture");

        SyntheticBuild totalMismatch = new SyntheticBuild(0);
        totalMismatch.chunk(lines(idRow("1000", "alpha")));
        assertPartitionRejected(
                "partition total mismatch", totalMismatch.partition(2), totalMismatch.objects,
                MAX_CHUNK_ROWS, "partition total does not match the staged row count");

        SyntheticBuild shortTable = new SyntheticBuild(1);
        shortTable.chunk(lines(idRow(idForBucket(1, 0), "alpha")));
        assertPartitionRejected(
                "chunk table length mismatch", shortTable,
                "group table chunk count does not match its bucket bits");

        SyntheticBuild overCap = new SyntheticBuild(0);
        overCap.chunk(lines(idRow("1000", "alpha"), idRow("2000", "bravo")));
        assertPartitionRejected(
                "chunk rows over the signed cap", overCap.partition(), overCap.objects, 1,
                "chunk entry rows are outside the signed cap");

        SyntheticBuild wrongPlatform = new SyntheticBuild(0);
        wrongPlatform.chunk(lines(idRow("1000", "alpha")));
        assertPartitionRejected(
                "group table platform mismatch",
                wrongPlatform.table("{\"v\":3,\"platform\":\"facebook\",\"k\":0,\"g\":0,"
                        + "\"group\":0,\"chunks\":[" + wrongPlatform.entries + "]}", 1),
                wrongPlatform.objects, MAX_CHUNK_ROWS,
                "group table platform does not match the partition");

        SyntheticBuild wrongBits = new SyntheticBuild(0);
        wrongBits.chunk(lines(idRow("1000", "alpha")));
        assertPartitionRejected(
                "group table bucket bits mismatch",
                wrongBits.table("{\"v\":3,\"platform\":\"threads\",\"k\":1,\"g\":0,"
                        + "\"group\":0,\"chunks\":[" + wrongBits.entries + "]}", 1),
                wrongBits.objects, MAX_CHUNK_ROWS,
                "group table bucket bits do not match the partition");

        SyntheticBuild malformedId = new SyntheticBuild(0);
        malformedId.chunk(lines(idRow("0123", "alpha")));
        assertPartitionRejected(
                "malformed Threads id", malformedId, "chunk row id is malformed");

        SyntheticBuild shortId = new SyntheticBuild(0);
        shortId.chunk(lines(idRow("123", "alpha")));
        assertPartitionRejected(
                "short Threads id", shortId, "chunk row id is malformed");

        SyntheticBuild missingUsername = new SyntheticBuild(0);
        missingUsername.chunk(lines("{\"i\":\"1000\"}"));
        assertPartitionRejected(
                "id row without username", missingUsername,
                "chunk row username is not a string");

        SyntheticBuild malformedUsername = new SyntheticBuild(0);
        malformedUsername.chunk(lines(idRow("1000", "al pha")));
        assertPartitionRejected(
                "malformed username", malformedUsername, "chunk row username is malformed");

        SyntheticBuild unknownKey = new SyntheticBuild(0);
        unknownKey.chunk(lines("{\"i\":\"1000\",\"u\":\"alpha\",\"x\":1}"));
        assertPartitionRejected(
                "unknown row key", unknownKey, "chunk row carries an unknown key");

        SyntheticBuild nonObjectRow = new SyntheticBuild(0);
        nonObjectRow.chunk(lines("[\"1000\"]"));
        assertPartitionRejected(
                "non-object row", nonObjectRow, "chunk row is not a JSON object");

        SyntheticBuild emptyLine = new SyntheticBuild(0);
        emptyLine.chunk(lines(idRow("1000", "alpha"), ""), 1, 0);
        assertPartitionRejected(
                "empty chunk line", emptyLine, "chunk carries an empty line");

        SyntheticBuild emptyBucket = new SyntheticBuild(1);
        emptyBucket.empty();
        emptyBucket.chunk(lines(idRow(idForBucket(1, 1), "alpha")));
        RowCounts emptyCounts = validate(emptyBucket, emptyBucket.partition(), MAX_CHUNK_ROWS);
        if (emptyCounts.chunks != 1 || emptyCounts.idRows != 1 || emptyCounts.handleRows != 0) {
            throw new AssertionError("empty bucket was not handled as null");
        }

        SyntheticBuild placed = new SyntheticBuild(1);
        placed.chunk(lines(idRow(idForBucket(1, 0), "alpha"), handleRow(handleForBucket(1, 0))));
        placed.chunk(lines(idRow(idForBucket(1, 1), "bravo"), handleRow(handleForBucket(1, 1))));
        RowCounts placedCounts = validate(placed, placed.partition(), MAX_CHUNK_ROWS);
        if (placedCounts.chunks != 2 || placedCounts.idRows != 2 || placedCounts.handleRows != 2
                || placedCounts.uniqueIds != 2) {
            throw new AssertionError("correctly placed two-bucket rows were rejected");
        }

        SyntheticBuild handleOnly = new SyntheticBuild(0);
        handleOnly.chunk(lines(idRow("1000", "alpha"), handleRow("bravo")));
        RowCounts handleCounts = validate(handleOnly, handleOnly.partition(), MAX_CHUNK_ROWS);
        if (handleCounts.idRows != 1 || handleCounts.handleRows != 1
                || handleCounts.uniqueIds != 1) {
            throw new AssertionError("handle-only row was not skipped from the id import");
        }

        String exactText = "2026-09-02T12:34:56Z";
        long exactMillis = Instant.parse(exactText).toEpochMilli();
        long referenceNow = exactMillis + 60L * 60L * 1000L;
        if (!validVerifiedTimestamp(exactText, exactMillis, referenceNow)) {
            throw new AssertionError("exact ISO timestamp binding was rejected");
        }
        assertTimestampRejected("off-by-one timestamp", exactText, exactMillis + 1L, referenceNow);
        String staleText = "2026-07-01T00:00:00Z";
        assertTimestampRejected(
                "stale timestamp", staleText, Instant.parse(staleText).toEpochMilli(), referenceNow);
        assertTimestampRejected("malformed timestamp", "not-an-instant", exactMillis, referenceNow);
    }

    private static String rootJson(
            int version, String hash, int bucketBits, int groupBits, String groupsJson) {
        return "{\"v\":" + version + ",\"updatedAt\":\"2026-09-06T07:14:05.577Z\",\"hash\":\""
                + hash + "\",\"maxChunkRows\":8192,\"maxChunkBytes\":262144,\"platforms\":{"
                + "\"threads\":{\"k\":" + bucketBits + ",\"g\":" + groupBits
                + ",\"total\":1,\"groups\":" + groupsJson + "}}}";
    }

    private static void assertRootRejected(String label, String payloadJson, String reason) {
        try {
            parseRoot(payloadJson);
        } catch (Rejection rejected) {
            if (reason.equals(rejected.reason)) {
                return;
            }
            throw new AssertionError(label + " was rejected for an unexpected reason");
        }
        throw new AssertionError(label + " was silently accepted");
    }

    private static RowCounts validate(SyntheticBuild build, Partition partition, int maxChunkRows) {
        return validatePartition(
                partition, maxChunkRows, MAX_CHUNK_GZ_BYTES, build.objects, new HashSet<String>());
    }

    private static void assertPartitionRejected(String label, SyntheticBuild build, String reason) {
        assertPartitionRejected(label, build.partition(), build.objects, MAX_CHUNK_ROWS, reason);
    }

    private static void assertPartitionRejected(
            String label, Partition partition, Map<String, byte[]> objects,
            int maxChunkRows, String reason) {
        try {
            validatePartition(
                    partition, maxChunkRows, MAX_CHUNK_GZ_BYTES, objects, new HashSet<String>());
        } catch (Rejection rejected) {
            if (reason.equals(rejected.reason)) {
                return;
            }
            throw new AssertionError(label + " was rejected for an unexpected reason");
        }
        throw new AssertionError(label + " was silently accepted");
    }

    private static boolean validVerifiedTimestamp(String text, long millis, long now) {
        if (text == null || text.length() == 0 || text.length() > 64
                || millis <= 0L || now <= 0L) {
            return false;
        }
        try {
            long parsed = Instant.parse(text).toEpochMilli();
            return parsed == millis
                    && parsed >= now - SIGNED_LIST_MAX_AGE_MS
                    && parsed <= now + MAX_FUTURE_MS;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static void assertTimestampRejected(
            String label, String text, long millis, long now) {
        if (validVerifiedTimestamp(text, millis, now)) {
            throw new AssertionError(label + " was silently accepted");
        }
    }

    private static long parseInstant(String text) {
        try {
            return Instant.parse(text).toEpochMilli();
        } catch (Throwable ignored) {
            return -1L;
        }
    }

    // ---- synthetic builds --------------------------------------------------------------

    private static String[] lines(String first) {
        String[] result = new String[1];
        result[0] = first;
        return result;
    }

    private static String[] lines(String first, String second) {
        String[] result = new String[2];
        result[0] = first;
        result[1] = second;
        return result;
    }

    private static String idRow(String id, String username) {
        return "{\"i\":\"" + id + "\",\"u\":\"" + username + "\",\"d\":\"@" + username
                + "\",\"t\":\"synthetic\"}";
    }

    private static String handleRow(String username) {
        return "{\"u\":\"" + username + "\",\"t\":\"synthetic\"}";
    }

    private static String idForBucket(int bits, int bucket) {
        for (int offset = 0; offset < MAX_BUCKET_SEARCH; offset++) {
            String id = Long.toString(100000L + offset);
            if (bucketOf("threads:" + id, bits) == bucket) {
                return id;
            }
        }
        throw new AssertionError("no synthetic id landed in the requested bucket");
    }

    private static String handleForBucket(int bits, int bucket) {
        for (int offset = 0; offset < MAX_BUCKET_SEARCH; offset++) {
            String username = "handle_" + offset;
            if (bucketOf("threads:@" + username, bits) == bucket) {
                return username;
            }
        }
        throw new AssertionError("no synthetic handle landed in the requested bucket");
    }

    /** One unsigned in-memory group table plus its content-addressed chunk objects. */
    private static final class SyntheticBuild {
        final Map<String, byte[]> objects = new HashMap<String, byte[]>();
        final StringBuilder entries = new StringBuilder();
        final int bucketBits;
        int total;

        SyntheticBuild(int bucketBits) {
            this.bucketBits = bucketBits;
        }

        void empty() {
            separator();
            entries.append("null");
        }

        void chunk(String[] rows) {
            chunk(rows, rows.length, 0);
        }

        /** Stages the rows under their real content address, declaring the given counts. */
        void chunk(String[] rows, int declaredRows, int byteDelta) {
            byte[] compressed = gzipLines(rows);
            String sha = sha256Hex(compressed);
            objects.put(sha + CHUNK_SUFFIX, compressed);
            entry(sha, declaredRows, compressed.length + byteDelta);
        }

        /** Stores bytes that are not gzip under a foreign content address. */
        void garbage(String storedAs, int declaredRows) {
            byte[] bytes = "not a gzip stream".getBytes(StandardCharsets.UTF_8);
            objects.put(storedAs + CHUNK_SUFFIX, bytes);
            entry(storedAs, declaredRows, bytes.length);
        }

        private void entry(String sha, int declaredRows, int declaredBytes) {
            separator();
            entries.append("[\"").append(sha).append("\",").append(declaredRows)
                    .append(',').append(declaredBytes).append(']');
            total += declaredRows;
        }

        private void separator() {
            if (entries.length() > 0) {
                entries.append(',');
            }
        }

        Partition partition() {
            return partition(total);
        }

        Partition partition(int declaredTotal) {
            return table("{\"v\":3,\"platform\":\"threads\",\"k\":" + bucketBits
                    + ",\"g\":0,\"group\":0,\"chunks\":[" + entries + "]}", declaredTotal);
        }

        Partition table(String tableJson, int declaredTotal) {
            byte[] bytes = tableJson.getBytes(StandardCharsets.UTF_8);
            String sha = sha256Hex(bytes);
            objects.put(sha + GROUP_SUFFIX, bytes);
            String[] groups = new String[1];
            groups[0] = sha;
            return new Partition(bucketBits, 0, declaredTotal, groups);
        }
    }

    private static byte[] gzipLines(String[] rows) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        StringBuilder text = new StringBuilder();
        for (String row : rows) {
            text.append(row).append('\n');
        }
        try {
            GZIPOutputStream gzip = new GZIPOutputStream(out);
            gzip.write(text.toString().getBytes(StandardCharsets.UTF_8));
            gzip.close();
        } catch (IOException unexpected) {
            throw new AssertionError("synthetic chunk could not be compressed");
        }
        return out.toByteArray();
    }

    // ---- value holders -----------------------------------------------------------------

    private static final class Root {
        final String updatedAt;
        final long publishedAtMs;
        final int maxChunkRows;
        final int maxChunkBytes;
        final Partition partition;

        Root(String updatedAt, long publishedAtMs, int maxChunkRows, int maxChunkBytes,
                Partition partition) {
            this.updatedAt = updatedAt;
            this.publishedAtMs = publishedAtMs;
            this.maxChunkRows = maxChunkRows;
            this.maxChunkBytes = maxChunkBytes;
            this.partition = partition;
        }
    }

    private static final class Partition {
        final int bucketBits;
        final int groupBits;
        final int total;
        final String[] groups;

        Partition(int bucketBits, int groupBits, int total, String[] groups) {
            this.bucketBits = bucketBits;
            this.groupBits = groupBits;
            this.total = total;
            this.groups = groups;
        }
    }

    private static final class RowCounts {
        int chunks;
        int idRows;
        int handleRows;
        int uniqueIds;
    }

    /** A fixed-literal rejection; the focused cases match the exact reason. */
    private static final class Rejection extends AssertionError {
        private static final long serialVersionUID = 1L;
        final String reason;

        Rejection(String reason) {
            super(reason);
            this.reason = reason;
        }
    }

    private static Rejection reject(String reason) {
        return new Rejection(reason);
    }

    // ---- objects, hashing, and bounded IO ----------------------------------------------

    private static byte[] readBounded(File file, int cap) throws IOException {
        if (!file.isFile() || file.length() > cap) {
            throw reject("fixture file is missing or exceeds its local byte cap");
        }
        return Files.readAllBytes(file.toPath());
    }

    private static Map<String, byte[]> readObjects(File directory) throws IOException {
        File[] files = directory.listFiles();
        if (files == null) {
            throw new AssertionError("fixture objects directory is missing");
        }
        if (files.length > MAX_FIXTURE_OBJECTS) {
            throw new AssertionError("fixture objects directory exceeds the local file cap");
        }
        Map<String, byte[]> objects = new HashMap<String, byte[]>();
        for (File file : files) {
            String name = file.getName();
            if (!allowlistedObjectName(name)) {
                throw new AssertionError("fixture object name is not allowlisted");
            }
            objects.put(name, readBounded(file, MAX_ROOT_BYTES));
        }
        return objects;
    }

    /** Exactly 64 lowercase hex characters followed by ".json" or ".ndjson.gz". */
    private static boolean allowlistedObjectName(String name) {
        if (name.length() != 64 + GROUP_SUFFIX.length()
                && name.length() != 64 + CHUNK_SUFFIX.length()) {
            return false;
        }
        if (!lowercaseHex(name.substring(0, 64))) {
            return false;
        }
        String suffix = name.substring(64);
        return GROUP_SUFFIX.equals(suffix) || CHUNK_SUFFIX.equals(suffix);
    }

    private static boolean lowercaseHex(String value) {
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (!((next >= '0' && next <= '9') || (next >= 'a' && next <= 'f'))) {
                return false;
            }
        }
        return true;
    }

    /** Returns an object's bytes only after its size cap and content address hold. */
    private static byte[] requireContent(
            Map<String, byte[]> objects, String name, int cap, Set<String> referenced) {
        byte[] bytes = objects.get(name);
        if (bytes == null) {
            throw reject("referenced object is missing from the fixture");
        }
        if (bytes.length > cap) {
            throw reject("object exceeds its local byte cap");
        }
        if (!sha256Hex(bytes).equals(name.substring(0, 64))) {
            throw reject("object content does not match its content address");
        }
        referenced.add(name);
        return bytes;
    }

    private static byte[] inflateBounded(byte[] compressed, int cap) {
        try {
            GZIPInputStream in = new GZIPInputStream(new ByteArrayInputStream(compressed));
            try {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int total = 0;
                int read = in.read(buffer);
                while (read >= 0) {
                    total += read;
                    if (total > cap) {
                        throw reject("inflated chunk exceeds the local byte cap");
                    }
                    out.write(buffer, 0, read);
                    read = in.read(buffer);
                }
                return out.toByteArray();
            } finally {
                in.close();
            }
        } catch (IOException malformed) {
            throw reject("chunk gzip stream is malformed");
        }
    }

    private static String decodeUtf8(byte[] bytes, String label) {
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString();
        } catch (CharacterCodingException malformed) {
            throw reject(label + " is not valid UTF-8");
        }
    }

    private static byte[] sha256(byte[] bytes) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(bytes);
        } catch (NoSuchAlgorithmException missing) {
            throw new AssertionError("SHA-256 is unavailable");
        }
    }

    private static String sha256Hex(byte[] bytes) {
        byte[] digest = sha256(bytes);
        StringBuilder hex = new StringBuilder(digest.length * 2);
        for (int index = 0; index < digest.length; index++) {
            int value = digest[index] & 0xff;
            hex.append(Character.forDigit(value >>> 4, 16));
            hex.append(Character.forDigit(value & 0xf, 16));
        }
        return hex.toString();
    }

    // ---- signature (identical to VerifierHarness) --------------------------------------

    private static boolean verify(String payload, String signature) throws Exception {
        byte[] encodedKey = Base64.getUrlDecoder().decode(KEY);
        byte[] signatureBytes = Base64.getUrlDecoder().decode(signature);
        if (encodedKey.length != 32 || signatureBytes.length != 64) {
            return false;
        }
        EdDSAPublicKey key = new EdDSAPublicKey(
                new EdDSAPublicKeySpec(
                        encodedKey,
                        EdDSANamedCurveTable.ED_25519_CURVE_SPEC));
        EdDSAEngine verifier = new EdDSAEngine();
        verifier.initVerify(key);
        return verifier.verifyOneShot(payload.getBytes(StandardCharsets.UTF_8), signatureBytes);
    }

    /** Extracts the exact compact JSON bytes the server signed. */
    private static String extractPayloadJson(String document) {
        int key = document.indexOf("\"payload\"");
        if (key < 0) {
            return null;
        }
        int colon = document.indexOf(':', key + 9);
        if (colon < 0) {
            return null;
        }
        int start = colon + 1;
        while (start < document.length() && Character.isWhitespace(document.charAt(start))) {
            start++;
        }
        if (start >= document.length()) {
            return null;
        }
        int end = scanJsonValue(document, start);
        return end <= start ? null : document.substring(start, end);
    }

    private static int scanJsonValue(String text, int start) {
        char first = text.charAt(start);
        if (first != '{' && first != '[') {
            return -1;
        }
        int depth = 0;
        boolean inString = false;
        boolean escaped = false;
        for (int index = start; index < text.length(); index++) {
            char next = text.charAt(index);
            if (inString) {
                if (escaped) {
                    escaped = false;
                } else if (next == '\\') {
                    escaped = true;
                } else if (next == '"') {
                    inString = false;
                }
                continue;
            }
            if (next == '"') {
                inString = true;
            } else if (next == '{' || next == '[') {
                depth++;
            } else if (next == '}' || next == ']') {
                depth--;
                if (depth == 0) {
                    return index + 1;
                }
            }
        }
        return -1;
    }

    // ---- typed JSON access -------------------------------------------------------------

    @SuppressWarnings("unchecked")
    private static Map<String, Object> requireObject(Object value, String label) {
        if (!(value instanceof Map)) {
            throw reject(label + " is not a JSON object");
        }
        return (Map<String, Object>) value;
    }

    @SuppressWarnings("unchecked")
    private static List<Object> requireArray(Object value, String label) {
        if (!(value instanceof List)) {
            throw reject(label + " is not a JSON array");
        }
        return (List<Object>) value;
    }

    private static String requireString(Object value, String label) {
        if (!(value instanceof String)) {
            throw reject(label + " is not a string");
        }
        return (String) value;
    }

    private static int requireInt(Object value, String label) {
        if (!(value instanceof Long)) {
            throw reject(label + " is not an integer");
        }
        long number = ((Long) value).longValue();
        if (number < Integer.MIN_VALUE || number > Integer.MAX_VALUE) {
            throw reject(label + " is outside the integer range");
        }
        return (int) number;
    }

    private static String requireHex64(Object value, String label) {
        String text = requireString(value, label);
        if (text.length() != 64 || !lowercaseHex(text)) {
            throw reject(label + " is not 64 lowercase hex characters");
        }
        return text;
    }

    /**
     * Strict, bounded JSON reader: objects become insertion-ordered maps that reject
     * repeated keys, arrays become lists, integers become Long, other numbers Double.
     */
    private static final class Json {
        private final String text;
        private int index;

        private Json(String text) {
            this.text = text;
        }

        static Object parse(String text) {
            Json parser = new Json(text);
            parser.skipWhitespace();
            Object value = parser.value(0);
            parser.skipWhitespace();
            if (parser.index != text.length()) {
                throw reject("JSON document carries trailing data");
            }
            return value;
        }

        private Object value(int depth) {
            if (depth > MAX_JSON_DEPTH) {
                throw reject("JSON document nests too deeply");
            }
            char next = peek();
            if (next == '{') {
                return object(depth);
            }
            if (next == '[') {
                return array(depth);
            }
            if (next == '"') {
                return string();
            }
            if (next == 't') {
                literal("true");
                return Boolean.TRUE;
            }
            if (next == 'f') {
                literal("false");
                return Boolean.FALSE;
            }
            if (next == 'n') {
                literal("null");
                return null;
            }
            return number();
        }

        private Map<String, Object> object(int depth) {
            Map<String, Object> result = new LinkedHashMap<String, Object>();
            index++;
            skipWhitespace();
            if (peek() == '}') {
                index++;
                return result;
            }
            while (true) {
                skipWhitespace();
                if (peek() != '"') {
                    throw reject("JSON object key is not a string");
                }
                String key = string();
                skipWhitespace();
                if (peek() != ':') {
                    throw reject("JSON object key is not followed by a colon");
                }
                index++;
                skipWhitespace();
                Object value = value(depth + 1);
                if (result.containsKey(key)) {
                    throw reject("JSON object repeats a key");
                }
                result.put(key, value);
                skipWhitespace();
                char next = peek();
                index++;
                if (next == '}') {
                    return result;
                }
                if (next != ',') {
                    throw reject("JSON object member is not followed by a comma or brace");
                }
            }
        }

        private List<Object> array(int depth) {
            List<Object> result = new ArrayList<Object>();
            index++;
            skipWhitespace();
            if (peek() == ']') {
                index++;
                return result;
            }
            while (true) {
                skipWhitespace();
                result.add(value(depth + 1));
                skipWhitespace();
                char next = peek();
                index++;
                if (next == ']') {
                    return result;
                }
                if (next != ',') {
                    throw reject("JSON array element is not followed by a comma or bracket");
                }
            }
        }

        private String string() {
            index++;
            StringBuilder result = new StringBuilder();
            while (true) {
                char next = peek();
                index++;
                if (next == '"') {
                    return result.toString();
                }
                if (next < 0x20) {
                    throw reject("JSON string carries a control character");
                }
                if (next != '\\') {
                    result.append(next);
                    continue;
                }
                char escape = peek();
                index++;
                if (escape == '"' || escape == '\\' || escape == '/') {
                    result.append(escape);
                } else if (escape == 'b') {
                    result.append('\b');
                } else if (escape == 'f') {
                    result.append('\f');
                } else if (escape == 'n') {
                    result.append('\n');
                } else if (escape == 'r') {
                    result.append('\r');
                } else if (escape == 't') {
                    result.append('\t');
                } else if (escape == 'u') {
                    result.append(unicodeEscape());
                } else {
                    throw reject("JSON string carries an unknown escape");
                }
            }
        }

        private char unicodeEscape() {
            int code = 0;
            for (int count = 0; count < 4; count++) {
                int digit = Character.digit(peek(), 16);
                index++;
                if (digit < 0) {
                    throw reject("JSON unicode escape is malformed");
                }
                code = (code << 4) | digit;
            }
            return (char) code;
        }

        private Object number() {
            int start = index;
            if (peek() == '-') {
                index++;
            }
            char first = peek();
            if (first == '0') {
                index++;
            } else if (first >= '1' && first <= '9') {
                digits();
            } else {
                throw reject("JSON value is malformed");
            }
            boolean integral = true;
            if (index < text.length() && text.charAt(index) == '.') {
                integral = false;
                index++;
                requireDigit();
                digits();
            }
            if (index < text.length() && (text.charAt(index) == 'e' || text.charAt(index) == 'E')) {
                integral = false;
                index++;
                if (index < text.length()
                        && (text.charAt(index) == '+' || text.charAt(index) == '-')) {
                    index++;
                }
                requireDigit();
                digits();
            }
            String token = text.substring(start, index);
            try {
                if (integral) {
                    return Long.valueOf(token);
                }
                return Double.valueOf(token);
            } catch (NumberFormatException outOfRange) {
                throw reject("JSON number is out of range");
            }
        }

        private void requireDigit() {
            char next = peek();
            if (next < '0' || next > '9') {
                throw reject("JSON number is malformed");
            }
        }

        private void digits() {
            while (index < text.length()
                    && text.charAt(index) >= '0' && text.charAt(index) <= '9') {
                index++;
            }
        }

        private void literal(String expected) {
            if (!text.startsWith(expected, index)) {
                throw reject("JSON literal is malformed");
            }
            index += expected.length();
        }

        private char peek() {
            if (index >= text.length()) {
                throw reject("JSON document ended early");
            }
            return text.charAt(index);
        }

        private void skipWhitespace() {
            while (index < text.length()) {
                char next = text.charAt(index);
                if (next != ' ' && next != '\t' && next != '\n' && next != '\r') {
                    return;
                }
                index++;
            }
        }
    }
}
