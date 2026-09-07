package threadsmod.autoblock;

import android.content.Context;
import android.util.JsonReader;
import android.util.JsonToken;
import android.util.Log;

import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.BitSet;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.zip.GZIPInputStream;

/**
 * Stages the chunked v3 Threads index that one verified signed root names, without
 * committing anything.
 *
 * <p>The signed root names content-addressed group tables; each group table names one gzip
 * NDJSON chunk per bucket (bucket = high {@code k} bits of SHA-256 over the row key). Every
 * object is fetched through {@link ObjectFetcher}, which proves SHA-256(bytes) against the
 * name before any byte is parsed, so every parse failure below is a schema failure of signed
 * content and is attributed to the mirror that served it. Group tables whose sha already
 * matches the committed table are reused without a fetch; buckets whose chunk sha changed
 * are marked replaced and their chunks are staged one at a time (memory is bounded to one
 * capped compressed buffer plus one row list). The caller commits the returned
 * {@link BlocklistStore.InstallPlan} atomically; this class never opens a connection itself,
 * never calls {@code replaceVerified}, and never takes the passive admission lock.</p>
 */
final class ChunkInstaller {
    private static final String TAG = "ThreadsModAutoBlock";
    private static final int GROUP_FORMAT_VERSION = 3;
    private static final String THREADS_PLATFORM = "threads";
    private static final String ID_KEY_PREFIX = "threads:";
    private static final String HANDLE_KEY_PREFIX = "threads:@";
    private static final int MAX_ROW_LINE_CHARS = 4096;
    private static final int MAX_HANDLE_CHARS = 64;
    private static final int MAX_ID_CHARS = 24;
    private static final int SHA256_HEX_LENGTH = 64;
    private static final int GZIP_BUFFER_BYTES = 16 * 1024;

    private ChunkInstaller() {}

    /**
     * Stages every replaced chunk that {@code root} names and returns the plan that commits
     * them. Every failure surfaces as {@link ObjectFetcher.StageFailure}: an object that no
     * mirror could serve carries the per-mirror tokens; a group or chunk that parsed badly
     * carries its token in the slot of the mirror that served the bytes; a staging or
     * internal failure carries its token in the root mirror's slot.
     */
    static BlocklistStore.InstallPlan stage(
            Context context,
            AutoBlockSync.VerifiedList root,
            BlocklistStore.Snapshot previous)
            throws ObjectFetcher.StageFailure {
        try {
            return stageObjects(context, root, previous);
        } catch (ObjectFetcher.StageFailure objectFailure) {
            throw objectFailure;
        } catch (Exception stageError) {
            Log.w(TAG, "Signed object staging failed with a bounded local error.");
            throw attributedFailure(
                    root == null ? -1 : root.mirror,
                    AutoBlockSync.classifyListFetchFailure(stageError));
        }
    }

    private static BlocklistStore.InstallPlan stageObjects(
            Context context,
            AutoBlockSync.VerifiedList root,
            BlocklistStore.Snapshot previous)
            throws Exception {
        requireStageableRoot(root);
        int bucketBits = root.bucketBits;
        int groupBits = root.groupBits;
        int bucketCount = 1 << bucketBits;
        int groupSpan = 1 << (bucketBits - groupBits);
        int[] mirrorOrder = mirrorOrder(root.mirror);

        // The committed chunk table is reused only while the bucket geometry is unchanged and
        // the committed generation is valid; otherwise every bucket is replaced and no group
        // table may be skipped.
        BlocklistStore.StoredChunks stored = BlocklistStore.readChunkTable(context);
        String[] storedShas = new String[bucketCount];
        int[] storedRows = new int[bucketCount];
        boolean bitsChanged = previous == null || !previous.valid
                || stored == null || stored.bucketBits != bucketBits
                || !indexStoredChunks(stored, bucketCount, storedShas, storedRows);

        String[] shas = new String[bucketCount];
        int[] rows = new int[bucketCount];
        int[] sizes = new int[bucketCount];
        for (int group = 0; group < root.groups.length; group++) {
            int offset = group * groupSpan;
            if (!bitsChanged && storedGroupMatches(stored, root, group)) {
                for (int i = 0; i < groupSpan; i++) {
                    shas[offset + i] = storedShas[offset + i];
                    rows[offset + i] = storedRows[offset + i];
                }
            } else {
                fetchGroupTable(mirrorOrder, root, group, shas, rows, sizes);
            }
        }

        long totalRows = 0L;
        int chunkCount = 0;
        HashSet<String> namedShas = new HashSet<String>();
        BitSet replaced = new BitSet(bucketCount);
        for (int bucket = 0; bucket < bucketCount; bucket++) {
            String sha = shas[bucket];
            if (sha != null) {
                if (!namedShas.add(sha)) {
                    throw schemaFailure("group tables name one chunk for two buckets");
                }
                totalRows += rows[bucket];
                if (totalRows > AutoBlockSync.MAX_INDEX_ROWS) {
                    throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TARGET_CAP,
                            "signed index exceeds the local row cap");
                }
                chunkCount++;
            }
            boolean unchanged = !bitsChanged
                    && (sha == null
                            ? storedShas[bucket] == null
                            : sha.equals(storedShas[bucket]));
            if (!unchanged) {
                replaced.set(bucket);
            }
        }
        if (totalRows != root.total) {
            throw schemaFailure("signed root total differs from its group tables");
        }

        HashSet<String> keep = new HashSet<String>();
        for (int bucket = 0; bucket < bucketCount; bucket++) {
            if (replaced.get(bucket) && shas[bucket] != null) {
                keep.add(shas[bucket]);
            }
        }
        if (!BlocklistStore.pruneStaging(context, keep)) {
            throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_INTERNAL,
                    "chunk staging area could not be pruned");
        }
        Set<String> staged = BlocklistStore.stagedShas(context);
        if (staged == null) {
            throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_INTERNAL,
                    "chunk staging area could not be read");
        }
        for (int bucket = 0; bucket < bucketCount; bucket++) {
            String sha = shas[bucket];
            if (sha == null || !replaced.get(bucket) || staged.contains(sha)) {
                continue;
            }
            stageBucket(context, mirrorOrder, bucket, bucketBits, sha, rows[bucket], sizes[bucket]);
        }

        int[] chunkBuckets = new int[chunkCount];
        String[] chunkShas = new String[chunkCount];
        int[] chunkRows = new int[chunkCount];
        int next = 0;
        for (int bucket = 0; bucket < bucketCount; bucket++) {
            if (shas[bucket] != null) {
                chunkBuckets[next] = bucket;
                chunkShas[next] = shas[bucket];
                chunkRows[next] = rows[bucket];
                next++;
            }
        }
        return new BlocklistStore.InstallPlan(
                bucketBits, groupBits, root.groups,
                chunkBuckets, chunkShas, chunkRows, replaced, totalRows);
    }

    /** Re-checks the root geometry this class relies on; the root parser is the authority. */
    private static void requireStageableRoot(AutoBlockSync.VerifiedList root) throws Exception {
        if (root == null || root.unchanged
                || root.bucketBits < 0 || root.bucketBits > AutoBlockSync.MAX_BUCKET_BITS
                || root.groupBits < 0 || root.groupBits > AutoBlockSync.MAX_GROUP_BITS
                || root.groupBits > root.bucketBits
                || root.groups == null || root.groups.length != 1 << root.groupBits
                || root.total < 0 || root.total > AutoBlockSync.MAX_INDEX_ROWS
                || root.maxChunkRows < 1 || root.maxChunkRows > AutoBlockSync.MAX_CHUNK_ROWS
                || root.maxChunkBytes < 1
                || root.maxChunkBytes > AutoBlockSync.MAX_CHUNK_GZ_BYTES) {
            throw schemaFailure("signed root is not a stageable v3 threads index");
        }
        for (int group = 0; group < root.groups.length; group++) {
            if (!isLowercaseHex64(root.groups[group])) {
                throw schemaFailure("signed root is not a stageable v3 threads index");
            }
        }
    }

    /** Winning root mirror first, then the remaining allowlisted mirrors in declared order. */
    private static int[] mirrorOrder(int first) {
        int count = CloneBlockerEndpoints.blocklistMirrorCount();
        int[] order = new int[count];
        int next = 0;
        if (first >= 0 && first < count) {
            order[next] = first;
            next++;
        }
        for (int mirror = 0; mirror < count; mirror++) {
            if (mirror != first) {
                order[next] = mirror;
                next++;
            }
        }
        return order;
    }

    /** Indexes the committed chunk table by bucket; false when it is absent or inconsistent. */
    private static boolean indexStoredChunks(
            BlocklistStore.StoredChunks stored,
            int bucketCount,
            String[] storedShas,
            int[] storedRows) {
        if (stored.buckets == null || stored.shas == null || stored.rowCounts == null
                || stored.shas.length != stored.buckets.length
                || stored.rowCounts.length != stored.buckets.length) {
            return false;
        }
        for (int i = 0; i < stored.buckets.length; i++) {
            int bucket = stored.buckets[i];
            String sha = stored.shas[i];
            int rowCount = stored.rowCounts[i];
            if (bucket < 0 || bucket >= bucketCount || storedShas[bucket] != null
                    || !isLowercaseHex64(sha)
                    || rowCount < 1 || rowCount > AutoBlockSync.MAX_CHUNK_ROWS) {
                return false;
            }
            storedShas[bucket] = sha;
            storedRows[bucket] = rowCount;
        }
        return true;
    }

    private static boolean storedGroupMatches(
            BlocklistStore.StoredChunks stored, AutoBlockSync.VerifiedList root, int group) {
        return stored.groups != null
                && stored.groups.length == root.groups.length
                && root.groups[group].equals(stored.groups[group]);
    }

    /**
     * Fetches and parses one group table. A parse failure is a schema failure of signed
     * content attributed to the mirror that served the bytes.
     */
    private static void fetchGroupTable(
            int[] mirrorOrder,
            AutoBlockSync.VerifiedList root,
            int group,
            String[] shas,
            int[] rows,
            int[] sizes)
            throws Exception {
        AutoBlockSync.listRefreshPhase = AutoBlockSync.LIST_PHASE_FETCHING;
        ObjectFetcher.Fetched fetched = ObjectFetcher.fetchObject(
                mirrorOrder, root.groups[group] + ".json", "application/json",
                AutoBlockSync.MAX_GROUP_BYTES, -1);
        AutoBlockSync.listRefreshPhase = AutoBlockSync.LIST_PHASE_VERIFYING;
        try {
            parseGroupTable(fetched.bytes, root, group, shas, rows, sizes);
        } catch (Exception parseError) {
            throw attributedFailure(
                    fetched.mirror, AutoBlockSync.classifyListFetchFailure(parseError));
        }
    }

    /**
     * Strict parse of one v3 group table: {@code v} 3, {@code platform} "threads", {@code k},
     * {@code g} and {@code group} equal to the root and the requested group, and
     * {@code chunks} of exactly {@code 1 << (k - g)} entries that are each null or
     * {@code [sha, rows, bytes]}. Unknown keys are skipped; duplicate or missing keys fail.
     */
    private static void parseGroupTable(
            byte[] bytes,
            AutoBlockSync.VerifiedList root,
            int group,
            String[] shas,
            int[] rows,
            int[] sizes)
            throws Exception {
        int span = 1 << (root.bucketBits - root.groupBits);
        int offset = group * span;
        boolean sawVersion = false;
        boolean sawPlatform = false;
        boolean sawBucketBits = false;
        boolean sawGroupBits = false;
        boolean sawGroup = false;
        boolean sawChunks = false;
        try {
            JsonReader reader = new JsonReader(new InputStreamReader(
                    new ByteArrayInputStream(bytes), StandardCharsets.UTF_8.newDecoder()));
            try {
                if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                    throw groupSchemaFailure();
                }
                reader.beginObject();
                while (reader.hasNext()) {
                    String key = reader.nextName();
                    if ("v".equals(key)) {
                        if (sawVersion || readInt(reader) != GROUP_FORMAT_VERSION) {
                            throw groupSchemaFailure();
                        }
                        sawVersion = true;
                    } else if ("platform".equals(key)) {
                        if (sawPlatform || reader.peek() != JsonToken.STRING
                                || !THREADS_PLATFORM.equals(reader.nextString())) {
                            throw groupSchemaFailure();
                        }
                        sawPlatform = true;
                    } else if ("k".equals(key)) {
                        if (sawBucketBits || readInt(reader) != root.bucketBits) {
                            throw groupSchemaFailure();
                        }
                        sawBucketBits = true;
                    } else if ("g".equals(key)) {
                        if (sawGroupBits || readInt(reader) != root.groupBits) {
                            throw groupSchemaFailure();
                        }
                        sawGroupBits = true;
                    } else if ("group".equals(key)) {
                        if (sawGroup || readInt(reader) != group) {
                            throw groupSchemaFailure();
                        }
                        sawGroup = true;
                    } else if ("chunks".equals(key)) {
                        if (sawChunks || reader.peek() != JsonToken.BEGIN_ARRAY) {
                            throw groupSchemaFailure();
                        }
                        sawChunks = true;
                        reader.beginArray();
                        int index = 0;
                        while (reader.hasNext()) {
                            if (index >= span) {
                                throw groupSchemaFailure();
                            }
                            readChunkEntry(reader, root, offset + index, shas, rows, sizes);
                            index++;
                        }
                        reader.endArray();
                        if (index != span) {
                            throw groupSchemaFailure();
                        }
                    } else {
                        reader.skipValue();
                    }
                }
                reader.endObject();
                if (reader.peek() != JsonToken.END_DOCUMENT) {
                    throw groupSchemaFailure();
                }
            } finally {
                reader.close();
            }
        } catch (IOException malformedGroup) {
            throw groupSchemaFailure();
        } catch (IllegalStateException unexpectedToken) {
            throw groupSchemaFailure();
        } catch (IllegalArgumentException malformedNumber) {
            throw groupSchemaFailure();
        }
        if (!sawVersion || !sawPlatform || !sawBucketBits || !sawGroupBits
                || !sawGroup || !sawChunks) {
            throw groupSchemaFailure();
        }
    }

    /** One {@code chunks} entry: null for an empty bucket, else {@code [sha, rows, bytes]}. */
    private static void readChunkEntry(
            JsonReader reader,
            AutoBlockSync.VerifiedList root,
            int bucket,
            String[] shas,
            int[] rows,
            int[] sizes)
            throws Exception {
        JsonToken token = reader.peek();
        if (token == JsonToken.NULL) {
            reader.nextNull();
            return;
        }
        if (token != JsonToken.BEGIN_ARRAY) {
            throw groupSchemaFailure();
        }
        reader.beginArray();
        if (reader.peek() != JsonToken.STRING) {
            throw groupSchemaFailure();
        }
        String sha = reader.nextString();
        if (!isLowercaseHex64(sha)) {
            throw groupSchemaFailure();
        }
        int entryRows = readInt(reader);
        int entryBytes = readInt(reader);
        if (reader.hasNext()) {
            throw groupSchemaFailure();
        }
        reader.endArray();
        if (entryRows < 1 || entryBytes < 1) {
            throw groupSchemaFailure();
        }
        if (entryRows > root.maxChunkRows) {
            throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TARGET_CAP,
                    "group table names a chunk above the signed row cap");
        }
        if (entryBytes > root.maxChunkBytes) {
            throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TOO_LARGE,
                    "group table names a chunk above the signed byte cap");
        }
        shas[bucket] = sha;
        rows[bucket] = entryRows;
        sizes[bucket] = entryBytes;
    }

    private static int readInt(JsonReader reader) throws Exception {
        if (reader.peek() != JsonToken.NUMBER) {
            throw groupSchemaFailure();
        }
        return reader.nextInt();
    }

    /**
     * Fetches, parses and stages one replaced bucket's chunk. The compressed buffer and the
     * row list die with this frame, so at most one chunk is resident at a time.
     */
    private static void stageBucket(
            Context context,
            int[] mirrorOrder,
            int bucket,
            int bucketBits,
            String sha,
            int declaredRows,
            int declaredBytes)
            throws Exception {
        AutoBlockSync.listRefreshPhase = AutoBlockSync.LIST_PHASE_FETCHING;
        ObjectFetcher.Fetched fetched = ObjectFetcher.fetchObject(
                mirrorOrder, sha + ".ndjson.gz", "application/gzip",
                Math.min(declaredBytes, AutoBlockSync.MAX_CHUNK_GZ_BYTES), declaredBytes);
        AutoBlockSync.listRefreshPhase = AutoBlockSync.LIST_PHASE_VERIFYING;
        ArrayList<BlocklistStore.Entry> entries;
        try {
            entries = parseChunk(fetched.bytes, bucket, bucketBits, declaredRows);
        } catch (Exception parseError) {
            throw attributedFailure(
                    fetched.mirror, AutoBlockSync.classifyListFetchFailure(parseError));
        }
        fetched = null;
        if (!BlocklistStore.stageChunk(context, sha, entries)) {
            throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_INTERNAL,
                    "chunk could not be staged");
        }
    }

    /**
     * Verify-then-parse: {@link ObjectFetcher} already proved SHA-256(bytes) equals the signed
     * chunk name, so a gzip, UTF-8, or JSON fault here is a schema failure of signed content
     * and must never look like a transport failure. Inflation is capped independently of the
     * gzip trailer. Every line is one compact JSON object; id rows are validated and staged,
     * handle-only rows are validated and counted but not staged.
     */
    private static ArrayList<BlocklistStore.Entry> parseChunk(
            byte[] bytes, int bucket, int bucketBits, int declaredRows) throws Exception {
        ArrayList<BlocklistStore.Entry> entries = new ArrayList<BlocklistStore.Entry>();
        HashSet<String> ids = new HashSet<String>();
        HashSet<String> usernameKeys = new HashSet<String>();
        int rowCount = 0;
        try {
            BufferedReader lines = new BufferedReader(new InputStreamReader(
                    new CountingInputStream(
                            new GZIPInputStream(
                                    new ByteArrayInputStream(bytes), GZIP_BUFFER_BYTES),
                            AutoBlockSync.MAX_CHUNK_INFLATED_BYTES),
                    StandardCharsets.UTF_8.newDecoder()));
            try {
                while (true) {
                    String line = lines.readLine();
                    if (line == null) {
                        break;
                    }
                    rowCount++;
                    if (rowCount > declaredRows) {
                        throw schemaFailure("chunk row count differs from the signed group entry");
                    }
                    if (line.length() == 0 || line.length() > MAX_ROW_LINE_CHARS) {
                        throw schemaFailure("chunk line is not one compact JSON object");
                    }
                    parseRow(line, bucket, bucketBits, entries, ids, usernameKeys);
                }
            } finally {
                lines.close();
            }
        } catch (TooLargeException inflatedTooLarge) {
            throw new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_TOO_LARGE,
                    "chunk exceeds the inflated byte cap");
        } catch (IOException malformedChunk) {
            throw schemaFailure("chunk is not valid gzip NDJSON");
        }
        if (rowCount != declaredRows) {
            throw schemaFailure("chunk row count differs from the signed group entry");
        }
        return entries;
    }

    /**
     * One NDJSON row in strict mode. Keys {@code i} and {@code u} must be strings and may
     * appear once; {@code d}, {@code t} and unknown keys are skipped. An id row must carry a
     * canonical 4-24 digit id and a valid username and must hash into {@code bucket}; a
     * handle-only row must carry a 1-64 character username that hashes into {@code bucket}.
     */
    private static void parseRow(
            String line,
            int bucket,
            int bucketBits,
            ArrayList<BlocklistStore.Entry> entries,
            HashSet<String> ids,
            HashSet<String> usernameKeys)
            throws Exception {
        String id = null;
        String username = null;
        JsonReader reader = new JsonReader(new StringReader(line));
        try {
            if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                throw schemaFailure("chunk row is not a JSON object");
            }
            reader.beginObject();
            while (reader.hasNext()) {
                String key = reader.nextName();
                if ("i".equals(key)) {
                    if (id != null || reader.peek() != JsonToken.STRING) {
                        throw schemaFailure("chunk row has malformed numeric id");
                    }
                    id = reader.nextString();
                } else if ("u".equals(key)) {
                    if (username != null || reader.peek() != JsonToken.STRING) {
                        throw schemaFailure("chunk row has malformed username metadata");
                    }
                    username = reader.nextString();
                } else {
                    reader.skipValue();
                }
            }
            reader.endObject();
            if (reader.peek() != JsonToken.END_DOCUMENT) {
                throw schemaFailure("chunk line is not one compact JSON object");
            }
        } catch (IllegalStateException unexpectedToken) {
            throw schemaFailure("chunk line is not one compact JSON object");
        } finally {
            reader.close();
        }

        if (id != null) {
            if (!AutoBlockSync.isDecimalId(id) || id.length() > MAX_ID_CHARS) {
                throw schemaFailure("chunk row has malformed numeric id");
            }
            String clean = username == null ? "" : AutoBlockSync.cleanSignedUsername(username);
            if (clean.length() == 0) {
                throw schemaFailure("chunk threads id row has malformed username metadata");
            }
            long h32 = BlocklistStore.bucketHash(ID_KEY_PREFIX + id);
            if (bucketOf(h32, bucketBits) != bucket) {
                throw schemaFailure("chunk row belongs to a different bucket");
            }
            if (!ids.add(id)) {
                throw schemaFailure("chunk rows contain a duplicate numeric id");
            }
            if (!usernameKeys.add(clean.toLowerCase(Locale.US))) {
                throw schemaFailure("chunk rows have conflicting normalized usernames");
            }
            entries.add(new BlocklistStore.Entry(id, clean, h32));
            return;
        }
        // Canonical handle-only row: counted toward the signed row total, hashed under its
        // published form, never staged (this client keys passive membership by numeric id).
        if (username == null || username.length() == 0
                || username.length() > MAX_HANDLE_CHARS) {
            throw schemaFailure("chunk handle row has malformed username metadata");
        }
        long handleHash = BlocklistStore.bucketHash(HANDLE_KEY_PREFIX + username);
        if (bucketOf(handleHash, bucketBits) != bucket) {
            throw schemaFailure("chunk row belongs to a different bucket");
        }
    }

    /** Bucket of one 32-bit key hash: its high {@code bits} bits, or 0 when bits is 0. */
    private static int bucketOf(long h32, int bits) {
        return bits == 0 ? 0 : (int) (h32 >>> (32 - bits));
    }

    private static boolean isLowercaseHex64(String value) {
        if (value == null || value.length() != SHA256_HEX_LENGTH) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            boolean allowed = c >= '0' && c <= '9' || c >= 'a' && c <= 'f';
            if (!allowed) {
                return false;
            }
        }
        return true;
    }

    private static AutoBlockSync.ListFetchFailure schemaFailure(String detail) {
        return new AutoBlockSync.ListFetchFailure(AutoBlockSync.FAILURE_SCHEMA, detail);
    }

    private static AutoBlockSync.ListFetchFailure groupSchemaFailure() {
        return schemaFailure("group table is not the v3 threads group the root named");
    }

    /** One closed token in one mirror's slot; every other slot reads as internal in status. */
    private static ObjectFetcher.StageFailure attributedFailure(int mirror, String failureClass) {
        String[] mirrorFailures = new String[CloneBlockerEndpoints.blocklistMirrorCount()];
        String token = failureClass == null ? AutoBlockSync.FAILURE_INTERNAL : failureClass;
        if (mirror >= 0 && mirror < mirrorFailures.length) {
            mirrorFailures[mirror] = token;
        }
        return new ObjectFetcher.StageFailure(mirrorFailures, token);
    }

    /** Fails closed once the inflated chunk passes the local cap; the gzip trailer is not trusted. */
    private static final class CountingInputStream extends FilterInputStream {
        private final long limit;
        private long count;

        CountingInputStream(InputStream in, long limit) {
            super(in);
            this.limit = limit;
        }

        @Override
        public int read() throws IOException {
            int value = in.read();
            if (value >= 0) {
                account(1L);
            }
            return value;
        }

        @Override
        public int read(byte[] buffer, int offset, int length) throws IOException {
            int read = in.read(buffer, offset, length);
            if (read > 0) {
                account(read);
            }
            return read;
        }

        @Override
        public long skip(long n) throws IOException {
            long skipped = in.skip(n);
            if (skipped > 0L) {
                account(skipped);
            }
            return skipped;
        }

        @Override
        public boolean markSupported() {
            return false;
        }

        private void account(long delta) throws TooLargeException {
            count += delta;
            if (count > limit) {
                throw new TooLargeException();
            }
        }
    }

    /** Raised by {@link CountingInputStream}; caught before the generic IOException mapping. */
    private static final class TooLargeException extends IOException {
        TooLargeException() {
            super("chunk exceeds the inflated byte cap");
        }
    }
}
