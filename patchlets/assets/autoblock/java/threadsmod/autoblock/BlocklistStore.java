package threadsmod.autoblock;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.DatabaseErrorHandler;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteException;
import android.database.sqlite.SQLiteOpenHelper;
import android.database.sqlite.SQLiteStatement;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.BitSet;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Transactional local index for the verified Clone Blocker target list.
 *
 * <p>The signature and freshness checks remain the caller's responsibility. Verified chunk rows
 * are staged with {@link #stageChunk}, and a caller may pass an {@link InstallPlan} to
 * {@link #replaceVerified} only after the complete signed root, every group table and every
 * staged chunk have passed those checks. This store validates the bounded database
 * representation, preserves the previous generation until the complete replacement commits, and
 * treats every storage or invariant failure as an unusable list.</p>
 *
 * <p>Rows are partitioned by the high bits of {@code h32}, the first four bytes of the SHA-256 of
 * the signed bucket key, so one changed chunk replaces exactly one bucket range and every other
 * bucket keeps its committed rows.</p>
 *
 * <p>Only {@link #lookupId} and {@link #isCurrentIdMatch} establish mutation membership. Username
 * username lookup deliberately returns aggregate metadata without target IDs, so a recycled username can
 * never become Block authority.</p>
 */
public final class BlocklistStore {
    public static final String DATABASE_NAME = "threadsmod_blocklist.db";
    public static final int MAX_INDEX_ROWS = 2000000;
    public static final int NEW_TARGET_COUNT_UNKNOWN = -1;

    public static final String STATE_VALID = "valid";
    public static final String STATE_MISSING = "missing";
    public static final String STATE_CORRUPT = "corrupt";
    public static final String STATE_UNAVAILABLE = "unavailable";
    public static final String STATE_INVALID_INPUT = "invalid_input";

    private static final String TABLE_TARGETS = "blocklist_targets";
    private static final String TABLE_METADATA = "blocklist_metadata";
    private static final String TABLE_CHUNKS = "blocklist_chunks";
    private static final String TABLE_GROUPS = "blocklist_groups";
    private static final String TABLE_STAGING = "blocklist_staging";
    private static final String INDEX_USERNAME = "blocklist_targets_username_idx";
    private static final String INDEX_H32 = "blocklist_targets_h32_idx";
    private static final int DATABASE_VERSION = 3;
    private static final int MAX_USERNAME = 64;
    private static final int MAX_UPDATED_AT = 64;
    /** Rows one staged chunk may carry; equal to the signed root's chunk cap. */
    private static final int MAX_CHUNK_ROWS = 8192;
    /** Widest partition the chunk table can record; the accepted root is capped lower. */
    private static final int MAX_STORED_BUCKET_BITS = 24;
    /** Distinct staged digests a reader enumerates before treating staging as corrupt. */
    private static final int MAX_STAGED_CHUNKS = 1 << 16;
    private static final long MAX_H32 = 4294967295L;

    /** Retained v2 texts: a migrated install is validated against them before the v3 rebuild. */
    private static final String TARGETS_SQL_V2 =
            "CREATE TABLE blocklist_targets ("
                    + "target_id TEXT PRIMARY KEY NOT NULL "
                    + "CHECK(length(target_id) BETWEEN 4 AND 24 "
                    + "AND substr(target_id,1,1) BETWEEN '1' AND '9' "
                    + "AND target_id NOT GLOB '*[^0-9]*'),"
                    + "username TEXT NOT NULL "
                    + "CHECK(length(username) BETWEEN 1 AND 64 "
                    + "AND username NOT GLOB '*[^A-Za-z0-9._]*'),"
                    + "username_key TEXT NOT NULL "
                    + "CHECK(length(username_key) BETWEEN 1 AND 64 "
                    + "AND username_key NOT GLOB '*[^a-z0-9._]*' "
                    + "AND username_key = lower(username)),"
                    + "list_order INTEGER NOT NULL CHECK(list_order BETWEEN 0 AND 4999))";
    private static final String USERNAME_INDEX_SQL_V2 =
            "CREATE INDEX blocklist_targets_username_idx ON blocklist_targets"
                    + "(username_key,target_id)";
    private static final String METADATA_SQL_V1 =
            "CREATE TABLE blocklist_metadata ("
                    + "singleton_id INTEGER PRIMARY KEY NOT NULL CHECK(singleton_id = 1),"
                    + "valid INTEGER NOT NULL CHECK(valid = 1),"
                    + "generation INTEGER NOT NULL CHECK(generation >= 1),"
                    + "verified_updated_at TEXT NOT NULL "
                    + "CHECK(length(verified_updated_at) BETWEEN 1 AND 64),"
                    + "verified_updated_at_ms INTEGER NOT NULL CHECK(verified_updated_at_ms > 0),"
                    + "fetched_at_ms INTEGER NOT NULL CHECK(fetched_at_ms > 0),"
                    + "target_count INTEGER NOT NULL CHECK(target_count BETWEEN 0 AND 5000))";
    private static final String NEW_TARGET_COUNT_COLUMN_SQL =
            "new_target_count INTEGER NOT NULL DEFAULT -1 "
                    + "CHECK(new_target_count BETWEEN -1 AND 5000)";
    private static final String METADATA_SQL_V2 =
            "CREATE TABLE blocklist_metadata ("
                    + "singleton_id INTEGER PRIMARY KEY NOT NULL CHECK(singleton_id = 1),"
                    + "valid INTEGER NOT NULL CHECK(valid = 1),"
                    + "generation INTEGER NOT NULL CHECK(generation >= 1),"
                    + "verified_updated_at TEXT NOT NULL "
                    + "CHECK(length(verified_updated_at) BETWEEN 1 AND 64),"
                    + "verified_updated_at_ms INTEGER NOT NULL CHECK(verified_updated_at_ms > 0),"
                    + "fetched_at_ms INTEGER NOT NULL CHECK(fetched_at_ms > 0),"
                    + "target_count INTEGER NOT NULL CHECK(target_count BETWEEN 0 AND 5000),"
                    + NEW_TARGET_COUNT_COLUMN_SQL + ")";

    /** Live v3 schema; onCreate and the migration execute exactly these texts. */
    private static final String TARGETS_SQL =
            "CREATE TABLE blocklist_targets ("
                    + "target_id TEXT PRIMARY KEY NOT NULL "
                    + "CHECK(length(target_id) BETWEEN 4 AND 24 "
                    + "AND substr(target_id,1,1) BETWEEN '1' AND '9' "
                    + "AND target_id NOT GLOB '*[^0-9]*'),"
                    + "username TEXT NOT NULL "
                    + "CHECK(length(username) BETWEEN 1 AND 64 "
                    + "AND username NOT GLOB '*[^A-Za-z0-9._]*'),"
                    + "username_key TEXT NOT NULL "
                    + "CHECK(length(username_key) BETWEEN 1 AND 64 "
                    + "AND username_key NOT GLOB '*[^a-z0-9._]*' "
                    + "AND username_key = lower(username)),"
                    + "h32 INTEGER NOT NULL CHECK(h32 BETWEEN 0 AND 4294967295))";
    private static final String USERNAME_INDEX_SQL =
            "CREATE UNIQUE INDEX blocklist_targets_username_idx ON blocklist_targets"
                    + "(username_key)";
    private static final String H32_INDEX_SQL =
            "CREATE INDEX blocklist_targets_h32_idx ON blocklist_targets(h32)";
    private static final String METADATA_SQL =
            "CREATE TABLE blocklist_metadata ("
                    + "singleton_id INTEGER PRIMARY KEY NOT NULL CHECK(singleton_id = 1),"
                    + "valid INTEGER NOT NULL CHECK(valid = 1),"
                    + "generation INTEGER NOT NULL CHECK(generation >= 1),"
                    + "verified_updated_at TEXT NOT NULL "
                    + "CHECK(length(verified_updated_at) BETWEEN 1 AND 64),"
                    + "verified_updated_at_ms INTEGER NOT NULL CHECK(verified_updated_at_ms > 0),"
                    + "fetched_at_ms INTEGER NOT NULL CHECK(fetched_at_ms > 0),"
                    + "target_count INTEGER NOT NULL CHECK(target_count BETWEEN 0 AND 16777216),"
                    + "new_target_count INTEGER NOT NULL DEFAULT -1 "
                    + "CHECK(new_target_count BETWEEN -1 AND 16777216),"
                    + "bucket_bits INTEGER NOT NULL DEFAULT 0 CHECK(bucket_bits BETWEEN 0 AND 24))";
    private static final String CHUNKS_SQL =
            "CREATE TABLE blocklist_chunks ("
                    + "bucket INTEGER PRIMARY KEY NOT NULL CHECK(bucket BETWEEN 0 AND 16777215),"
                    + "sha256 TEXT NOT NULL "
                    + "CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),"
                    + "row_count INTEGER NOT NULL CHECK(row_count BETWEEN 1 AND 16777216),"
                    + "id_count INTEGER NOT NULL CHECK(id_count BETWEEN 0 AND row_count))";
    private static final String GROUPS_SQL =
            "CREATE TABLE blocklist_groups ("
                    + "group_index INTEGER PRIMARY KEY NOT NULL "
                    + "CHECK(group_index BETWEEN 0 AND 16777215),"
                    + "sha256 TEXT NOT NULL "
                    + "CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'))";
    private static final String STAGING_SQL =
            "CREATE TABLE blocklist_staging ("
                    + "sha256 TEXT NOT NULL "
                    + "CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),"
                    + "target_id TEXT NOT NULL "
                    + "CHECK(length(target_id) BETWEEN 4 AND 24 "
                    + "AND substr(target_id,1,1) BETWEEN '1' AND '9' "
                    + "AND target_id NOT GLOB '*[^0-9]*'),"
                    + "username TEXT NOT NULL "
                    + "CHECK(length(username) BETWEEN 1 AND 64 "
                    + "AND username NOT GLOB '*[^A-Za-z0-9._]*'),"
                    + "username_key TEXT NOT NULL "
                    + "CHECK(length(username_key) BETWEEN 1 AND 64 "
                    + "AND username_key NOT GLOB '*[^a-z0-9._]*' "
                    + "AND username_key = lower(username)),"
                    + "h32 INTEGER NOT NULL CHECK(h32 BETWEEN 0 AND 4294967295),"
                    + "PRIMARY KEY (sha256, target_id))";

    private static DatabaseHelper databaseHelper;
    private static boolean schemaValidated;
    private BlocklistStore() {}

    /** One fully verified signed-list row, before transactional persistence. */
    public static final class Entry {
        public final String targetId;
        public final String username;
        /** Unsigned bucket hash of the row's signed key, see {@link BlocklistStore#bucketHash}. */
        public final long h32;

        public Entry(String targetId, String username, long h32) {
            this.targetId = targetId;
            this.username = username;
            this.h32 = h32;
        }
    }

    /** Exact-ID membership plus display-only username metadata. */
    public static final class IdMatch {
        public final boolean storeValid;
        public final boolean matched;
        public final long generation;
        public final String username;
        public final String state;

        private IdMatch(
                boolean storeValid,
                boolean matched,
                long generation,
                String username,
                String state) {
            this.storeValid = storeValid;
            this.matched = matched;
            this.generation = generation;
            this.username = username;
            this.state = state;
        }

        private static IdMatch invalid(String state) {
            return invalid(state, 0L);
        }

        private static IdMatch invalid(String state, long observedGeneration) {
            return new IdMatch(
                    false, false, Math.max(0L, observedGeneration), "", state);
        }
    }

    /** Aggregate username-index result. It intentionally carries no target ID. */
    public static final class UsernameMetadata {
        public final boolean storeValid;
        public final boolean matched;
        public final int matchCount;
        public final long generation;
        public final String normalizedUsername;
        public final String state;

        private UsernameMetadata(
                boolean storeValid,
                boolean matched,
                int matchCount,
                long generation,
                String normalizedUsername,
                String state) {
            this.storeValid = storeValid;
            this.matched = matched;
            this.matchCount = matchCount;
            this.generation = generation;
            this.normalizedUsername = normalizedUsername;
            this.state = state;
        }

        private static UsernameMetadata invalid(String state) {
            return new UsernameMetadata(false, false, 0, 0L, "", state);
        }
    }

    /** Bounded metadata for Settings and Activity status rendering. */
    public static final class Snapshot {
        public final boolean valid;
        public final String state;
        public final long generation;
        public final String verifiedUpdatedAt;
        public final long verifiedUpdatedAtMs;
        public final long fetchedAtMs;
        public final int targetCount;
        /**
         * IDs introduced by the last successful refresh. A value of -1 means the current
         * generation predates this metric and was preserved by the reviewed v1-to-v2 migration.
         */
        public final int newTargetCount;

        private Snapshot(
                boolean valid,
                String state,
                long generation,
                String verifiedUpdatedAt,
                long verifiedUpdatedAtMs,
                long fetchedAtMs,
                int targetCount,
                int newTargetCount) {
            this.valid = valid;
            this.state = state;
            this.generation = generation;
            this.verifiedUpdatedAt = verifiedUpdatedAt;
            this.verifiedUpdatedAtMs = verifiedUpdatedAtMs;
            this.fetchedAtMs = fetchedAtMs;
            this.targetCount = targetCount;
            this.newTargetCount = newTargetCount;
        }

        private static Snapshot invalid(String state) {
            return new Snapshot(
                    false, state, 0L, "", 0L, 0L, 0, NEW_TARGET_COUNT_UNKNOWN);
        }
    }
    /**
     * One verified root's complete chunk table plus the buckets whose stored rows it replaces.
     *
     * <p>{@code chunkBuckets}, {@code chunkShas} and {@code chunkRows} describe every non-empty
     * bucket of the root in ascending bucket order. {@code replaced} marks the buckets that are
     * rewritten from staging, or emptied when the root has no chunk for them; every other bucket
     * keeps its committed rows and chunk-table entry.</p>
     */
    public static final class InstallPlan {
        public final int bucketBits;
        public final int groupBits;
        public final String[] groups;
        public final int[] chunkBuckets;
        public final String[] chunkShas;
        public final int[] chunkRows;
        public final BitSet replaced;
        public final long totalRows;

        public InstallPlan(
                int bucketBits,
                int groupBits,
                String[] groups,
                int[] chunkBuckets,
                String[] chunkShas,
                int[] chunkRows,
                BitSet replaced,
                long totalRows) {
            if (bucketBits < 0 || bucketBits > MAX_STORED_BUCKET_BITS
                    || groupBits < 0 || groupBits > MAX_STORED_BUCKET_BITS
                    || groups == null || groups.length != (1 << groupBits)
                    || chunkBuckets == null || chunkShas == null || chunkRows == null
                    || chunkShas.length != chunkBuckets.length
                    || chunkRows.length != chunkBuckets.length
                    || replaced == null || replaced.length() > (1 << bucketBits)) {
                throw new IllegalArgumentException("blocklist install plan is malformed");
            }
            for (int index = 0; index < groups.length; index++) {
                if (!isSha256Hex(groups[index])) {
                    throw new IllegalArgumentException("blocklist install plan group is malformed");
                }
            }
            long rows = 0L;
            int previousBucket = -1;
            for (int index = 0; index < chunkBuckets.length; index++) {
                int bucket = chunkBuckets[index];
                if (bucket <= previousBucket
                        || bucket >= (1 << bucketBits)
                        || !isSha256Hex(chunkShas[index])
                        || chunkRows[index] < 1) {
                    throw new IllegalArgumentException("blocklist install plan chunk is malformed");
                }
                rows += chunkRows[index];
                previousBucket = bucket;
            }
            if (rows != totalRows) {
                throw new IllegalArgumentException("blocklist install plan total is malformed");
            }
            this.bucketBits = bucketBits;
            this.groupBits = groupBits;
            this.groups = groups.clone();
            this.chunkBuckets = chunkBuckets.clone();
            this.chunkShas = chunkShas.clone();
            this.chunkRows = chunkRows.clone();
            this.replaced = (BitSet) replaced.clone();
            this.totalRows = totalRows;
        }
    }

    /**
     * The committed chunk and group tables. {@code bucketBits} is {@code -1} when they could not
     * be read, which makes a caller treat every bucket as changed.
     */
    public static final class StoredChunks {
        public final int bucketBits;
        public final int[] buckets;
        public final String[] shas;
        public final int[] rowCounts;
        public final int[] idCounts;
        public final String[] groups;

        StoredChunks(
                int bucketBits,
                int[] buckets,
                String[] shas,
                int[] rowCounts,
                int[] idCounts,
                String[] groups) {
            this.bucketBits = bucketBits;
            this.buckets = buckets;
            this.shas = shas;
            this.rowCounts = rowCounts;
            this.idCounts = idCounts;
            this.groups = groups;
        }

        static StoredChunks unreadable() {
            return new StoredChunks(
                    -1, new int[0], new String[0], new int[0], new int[0], new String[0]);
        }
    }

    /**
     * Atomically installs one complete, already signature-verified list generation from the
     * staged chunks named by {@code plan}.
     *
     * <p>Invalid input is rejected before opening the database. Any schema, old-state, staging,
     * insertion, or post-write invariant failure rolls the transaction back and leaves the
     * previous bytes authoritative. New-record counts are measured against the complete previous
     * generation before any bucket is cleared, so they are the exact incoming-ID set
     * difference.</p>
     */
    public static boolean replaceVerified(
            Context context,
            InstallPlan plan,
            String verifiedUpdatedAt,
            long verifiedUpdatedAtMs,
            long fetchedAtMs) {
        String cleanUpdatedAt = prepareUpdatedAt(verifiedUpdatedAt, verifiedUpdatedAtMs);
        if (context == null || plan == null || cleanUpdatedAt == null || fetchedAtMs <= 0L) {
            return false;
        }

        SQLiteDatabase database;
        try {
            database = writableDatabase(context);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return false;
        }

        boolean began = false;
        boolean committed = false;
        try {
            database.beginTransaction();
            began = true;

            StoredMetadata previous = readMetadata(database, true);
            boolean fullReplace = plan.replaced.cardinality() == (1 << plan.bucketBits);
            long generation;
            int newTargetCount = 0;
            if (previous == null) {
                if (countRows(database) != 0 || !fullReplace) {
                    throw new StoreException(STATE_CORRUPT);
                }
                generation = 1L;
            } else {
                requireRowCount(database, previous.targetCount);
                if (verifiedUpdatedAtMs < previous.verifiedUpdatedAtMs
                        || fetchedAtMs < previous.fetchedAtMs
                        || previous.generation == Long.MAX_VALUE) {
                    throw new StoreException(STATE_CORRUPT);
                }
                if (previous.bucketBits != plan.bucketBits && !fullReplace) {
                    throw new StoreException(STATE_CORRUPT);
                }
                generation = previous.generation + 1L;
            }
            if (previous == null || previous.bucketBits != plan.bucketBits) {
                database.delete(TABLE_CHUNKS, null, null);
            }

            // Staged counts and the set difference are measured while the complete previous
            // generation is still present. An ID's bucket range is fixed by its hash, so a row
            // counted as already present here is exactly one the previous generation carried.
            int chunkCount = plan.chunkBuckets.length;
            int[] stagedCounts = new int[chunkCount];
            for (int index = 0; index < chunkCount; index++) {
                stagedCounts[index] = -1;
                if (!plan.replaced.get(plan.chunkBuckets[index])) {
                    continue;
                }
                int stagedCount = countStaged(database, plan.chunkShas[index]);
                if (stagedCount > plan.chunkRows[index]) {
                    throw new StoreException(STATE_CORRUPT);
                }
                stagedCounts[index] = stagedCount;
                newTargetCount += countNewTargets(database, plan.chunkShas[index], stagedCount);
                if (newTargetCount < 0 || newTargetCount > MAX_INDEX_ROWS) {
                    throw new StoreException(STATE_CORRUPT);
                }
            }

            SQLiteStatement deleteRange = null;
            SQLiteStatement dropChunk = null;
            SQLiteStatement copyStaged = null;
            SQLiteStatement putChunk = null;
            SQLiteStatement dropStaged = null;
            SQLiteStatement putGroup = null;
            try {
                deleteRange = database.compileStatement(
                        "DELETE FROM blocklist_targets WHERE h32 BETWEEN ? AND ?");
                dropChunk = database.compileStatement(
                        "DELETE FROM blocklist_chunks WHERE bucket = ?");
                copyStaged = database.compileStatement(
                        "INSERT INTO blocklist_targets (target_id,username,username_key,h32) "
                                + "SELECT target_id,username,username_key,h32 "
                                + "FROM blocklist_staging "
                                + "WHERE sha256 = ? AND h32 BETWEEN ? AND ?");
                putChunk = database.compileStatement(
                        "INSERT INTO blocklist_chunks (bucket,sha256,row_count,id_count) "
                                + "VALUES (?,?,?,?)");
                dropStaged = database.compileStatement(
                        "DELETE FROM blocklist_staging WHERE sha256 = ?");
                putGroup = database.compileStatement(
                        "INSERT INTO blocklist_groups (group_index,sha256) VALUES (?,?)");

                // Every replaced bucket is cleared before any staged chunk is copied, so a
                // username that moved to another bucket never collides with its own old row.
                for (int bucket = plan.replaced.nextSetBit(0);
                        bucket >= 0;
                        bucket = plan.replaced.nextSetBit(bucket + 1)) {
                    deleteRange.bindLong(1, bucketRangeLow(bucket, plan.bucketBits));
                    deleteRange.bindLong(2, bucketRangeHigh(bucket, plan.bucketBits));
                    deleteRange.executeUpdateDelete();
                    dropChunk.bindLong(1, bucket);
                    dropChunk.executeUpdateDelete();
                }
                for (int index = 0; index < chunkCount; index++) {
                    if (stagedCounts[index] < 0) {
                        continue;
                    }
                    int bucket = plan.chunkBuckets[index];
                    String sha256 = plan.chunkShas[index];
                    copyStaged.bindString(1, sha256);
                    copyStaged.bindLong(2, bucketRangeLow(bucket, plan.bucketBits));
                    copyStaged.bindLong(3, bucketRangeHigh(bucket, plan.bucketBits));
                    if (copyStaged.executeUpdateDelete() != stagedCounts[index]) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                    putChunk.bindLong(1, bucket);
                    putChunk.bindString(2, sha256);
                    putChunk.bindLong(3, plan.chunkRows[index]);
                    putChunk.bindLong(4, stagedCounts[index]);
                    putChunk.executeInsert();
                    dropStaged.bindString(1, sha256);
                    dropStaged.executeUpdateDelete();
                }

                database.delete(TABLE_GROUPS, null, null);
                for (int index = 0; index < plan.groups.length; index++) {
                    putGroup.bindLong(1, index);
                    putGroup.bindString(2, plan.groups[index]);
                    putGroup.executeInsert();
                }
            } finally {
                closeStatement(deleteRange);
                closeStatement(dropChunk);
                closeStatement(copyStaged);
                closeStatement(putChunk);
                closeStatement(dropStaged);
                closeStatement(putGroup);
            }

            long installedRows = queryLong(
                    database, "SELECT coalesce(sum(id_count), 0) FROM blocklist_chunks", null);
            if (installedRows < 0L
                    || installedRows > MAX_INDEX_ROWS
                    || installedRows != countRows(database)
                    || newTargetCount < 0
                    || newTargetCount > installedRows) {
                throw new StoreException(STATE_CORRUPT);
            }

            database.delete(TABLE_METADATA, null, null);
            ContentValues metadata = new ContentValues(9);
            metadata.put("singleton_id", 1);
            metadata.put("valid", 1);
            metadata.put("generation", generation);
            metadata.put("verified_updated_at", cleanUpdatedAt);
            metadata.put("verified_updated_at_ms", verifiedUpdatedAtMs);
            metadata.put("fetched_at_ms", fetchedAtMs);
            metadata.put("target_count", installedRows);
            metadata.put("new_target_count", newTargetCount);
            metadata.put("bucket_bits", plan.bucketBits);
            database.insertOrThrow(TABLE_METADATA, null, metadata);

            StoredMetadata persisted = readMetadata(database, false);
            if (persisted == null
                    || persisted.generation != generation
                    || persisted.verifiedUpdatedAtMs != verifiedUpdatedAtMs
                    || persisted.fetchedAtMs != fetchedAtMs
                    || persisted.targetCount != installedRows
                    || persisted.newTargetCount != newTargetCount
                    || persisted.bucketBits != plan.bucketBits
                    || !cleanUpdatedAt.equals(persisted.verifiedUpdatedAt)) {
                throw new StoreException(STATE_CORRUPT);
            }
            requireRowCount(database, (int) installedRows);
            database.setTransactionSuccessful();
            committed = true;
        } catch (Throwable ignored) {
            committed = false;
        } finally {
            if (began) {
                try {
                    database.endTransaction();
                } catch (Throwable ignored) {
                    committed = false;
                    invalidateSchemaCache();
                }
            }
        }
        return committed;
    }

    /** Advances only the fetch time after a valid conditional 304 response. */
    public static boolean markFetchedUnchanged(Context context, long fetchedAtMs) {
        if (context == null || fetchedAtMs <= 0L) {
            return false;
        }
        SQLiteDatabase database;
        try {
            database = writableDatabase(context);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return false;
        }

        boolean began = false;
        boolean committed = false;
        try {
            database.beginTransaction();
            began = true;
            StoredMetadata previous = readMetadata(database, false);
            if (previous == null || fetchedAtMs < previous.fetchedAtMs) {
                throw new StoreException(STATE_CORRUPT);
            }

            ContentValues update = new ContentValues(2);
            update.put("fetched_at_ms", fetchedAtMs);
            update.put("new_target_count", 0);
            int changed = database.update(
                    TABLE_METADATA,
                    update,
                    "singleton_id = 1 AND valid = 1 AND generation = ?",
                    new String[] {Long.toString(previous.generation)});
            if (changed != 1) {
                throw new StoreException(STATE_CORRUPT);
            }
            StoredMetadata current = readMetadata(database, false);
            if (current == null
                    || current.generation != previous.generation
                    || current.fetchedAtMs != fetchedAtMs
                    || current.targetCount != previous.targetCount
                    || current.newTargetCount != 0) {
                throw new StoreException(STATE_CORRUPT);
            }
            database.setTransactionSuccessful();
            committed = true;
        } catch (Throwable ignored) {
            committed = false;
        } finally {
            if (began) {
                try {
                    database.endTransaction();
                } catch (Throwable ignored) {
                    committed = false;
                    invalidateSchemaCache();
                }
            }
        }
        return committed;
    }

    /** Fast exact-primary-key membership lookup for one immutable visible author ID. */
    public static IdMatch lookupId(Context context, String targetId) {
        if (context == null || !isNumericId(targetId)) {
            return IdMatch.invalid(STATE_INVALID_INPUT);
        }
        long observedGeneration = 0L;
        try {
            SQLiteDatabase database = readableDatabase(context);
            StoredMetadata metadata = readMetadata(database, true);
            if (metadata == null) {
                return IdMatch.invalid(
                        countRows(database) == 0 ? STATE_MISSING : STATE_CORRUPT);
            }
            observedGeneration = metadata.generation;
            Cursor cursor = database.query(
                    TABLE_TARGETS,
                    new String[] {"username", "username_key"},
                    "target_id = ?",
                    new String[] {targetId},
                    null,
                    null,
                    null,
                    "1");
            try {
                if (!cursor.moveToFirst()) {
                    return new IdMatch(true, false, metadata.generation, "", STATE_VALID);
                }
                String username = cursor.getString(0);
                String usernameKey = cursor.getString(1);
                if (!validStoredUsername(username, usernameKey)) {
                    return IdMatch.invalid(STATE_CORRUPT, observedGeneration);
                }
                requireUniqueUsername(database, usernameKey);
                return new IdMatch(true, true, metadata.generation, username, STATE_VALID);
            } finally {
                cursor.close();
            }
        } catch (StoreException invalidStore) {
            return IdMatch.invalid(invalidStore.state, observedGeneration);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return IdMatch.invalid(STATE_UNAVAILABLE, observedGeneration);
        }
    }

    /**
     * Rechecks immutable target membership against the same database generation immediately
     * before a scheduler reserves the mutation attempt.
     */
    public static IdMatch isCurrentIdMatch(
            Context context, String targetId, long expectedGeneration) {
        if (context == null || !isNumericId(targetId) || expectedGeneration < 1L) {
            return IdMatch.invalid(STATE_INVALID_INPUT);
        }
        long observedGeneration = 0L;
        try {
            SQLiteDatabase database = readableDatabase(context);
            StoredMetadata metadata = readMetadata(database, true);
            if (metadata == null) {
                return IdMatch.invalid(
                        countRows(database) == 0 ? STATE_MISSING : STATE_CORRUPT);
            }
            observedGeneration = metadata.generation;
            if (metadata.generation != expectedGeneration) {
                return new IdMatch(true, false, metadata.generation, "", STATE_VALID);
            }
            Cursor cursor = database.query(
                    TABLE_TARGETS,
                    new String[] {"target_id", "username", "username_key"},
                    "target_id = ?",
                    new String[] {targetId},
                    null,
                    null,
                    null,
                    "1");
            try {
                if (!cursor.moveToFirst()) {
                    return new IdMatch(true, false, metadata.generation, "", STATE_VALID);
                }
                String storedId = cursor.getString(0);
                String username = cursor.getString(1);
                String usernameKey = cursor.getString(2);
                if (!targetId.equals(storedId)
                        || !validStoredUsername(username, usernameKey)) {
                    return IdMatch.invalid(STATE_CORRUPT, observedGeneration);
                }
                requireUniqueUsername(database, usernameKey);
                return new IdMatch(
                        true, true, metadata.generation, username, STATE_VALID);
            } finally {
                cursor.close();
            }
        } catch (StoreException invalidStore) {
            return IdMatch.invalid(invalidStore.state, observedGeneration);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return IdMatch.invalid(STATE_UNAVAILABLE, observedGeneration);
        }
    }

    /** Indexed username query for UI/diagnostic metadata; it never returns a target ID. */
    public static UsernameMetadata lookupUsernameMetadata(Context context, String username) {
        String usernameKey = normalizeUsername(username);
        if (context == null || usernameKey.length() == 0) {
            return UsernameMetadata.invalid(STATE_INVALID_INPUT);
        }
        try {
            SQLiteDatabase database = readableDatabase(context);
            StoredMetadata metadata = readMetadata(database, true);
            if (metadata == null) {
                return UsernameMetadata.invalid(
                        countRows(database) == 0 ? STATE_MISSING : STATE_CORRUPT);
            }
            Cursor cursor = database.rawQuery(
                    "SELECT count(*) FROM blocklist_targets INDEXED BY "
                            + "blocklist_targets_username_idx WHERE username_key = ?",
                    new String[] {usernameKey});
            try {
                if (!cursor.moveToFirst()) {
                    return UsernameMetadata.invalid(STATE_CORRUPT);
                }
                long count = cursor.getLong(0);
                if (count < 0L || count > 1L) {
                    return UsernameMetadata.invalid(STATE_CORRUPT);
                }
                return new UsernameMetadata(
                        true,
                        count > 0L,
                        (int) count,
                        metadata.generation,
                        usernameKey,
                        STATE_VALID);
            } finally {
                cursor.close();
            }
        } catch (StoreException ignored) {
            return UsernameMetadata.invalid(STATE_CORRUPT);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return UsernameMetadata.invalid(STATE_UNAVAILABLE);
        }
    }

    /** Reads and verifies all bounded metadata invariants for Activity/Settings status. */
    public static Snapshot snapshot(Context context) {
        if (context == null) {
            return Snapshot.invalid(STATE_UNAVAILABLE);
        }
        try {
            SQLiteDatabase database = readableDatabase(context);
            StoredMetadata metadata = readMetadata(database, true);
            if (metadata == null) {
                if (countRows(database) == 0) {
                    return Snapshot.invalid(STATE_MISSING);
                }
                return Snapshot.invalid(STATE_CORRUPT);
            }
            return new Snapshot(
                    true,
                    STATE_VALID,
                    metadata.generation,
                    metadata.verifiedUpdatedAt,
                    metadata.verifiedUpdatedAtMs,
                    metadata.fetchedAtMs,
                    metadata.targetCount,
                    metadata.newTargetCount);
        } catch (StoreException ignored) {
            return Snapshot.invalid(STATE_CORRUPT);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return Snapshot.invalid(STATE_UNAVAILABLE);
        }
    }
    /**
     * Stages one verified chunk's ID rows under its content digest. Staging never touches the
     * committed rows or metadata, so it needs no admission lock; a later replacement copies each
     * staged chunk into its bucket range inside one transaction.
     */
    public static boolean stageChunk(Context context, String sha256, List<Entry> rows) {
        if (context == null || !isSha256Hex(sha256)) {
            return false;
        }
        PreparedBatch batch = prepareBatch(rows);
        if (batch == null) {
            return false;
        }

        SQLiteDatabase database;
        try {
            database = writableDatabase(context);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return false;
        }

        boolean began = false;
        boolean committed = false;
        try {
            database.beginTransaction();
            began = true;
            database.delete(TABLE_STAGING, "sha256 = ?", new String[] {sha256});
            SQLiteStatement insert = database.compileStatement(
                    "INSERT INTO blocklist_staging (sha256,target_id,username,username_key,h32) "
                            + "VALUES (?,?,?,?,?)");
            try {
                for (int index = 0; index < batch.entries.size(); index++) {
                    PreparedEntry entry = batch.entries.get(index);
                    insert.bindString(1, sha256);
                    insert.bindString(2, entry.targetId);
                    insert.bindString(3, entry.username);
                    insert.bindString(4, entry.usernameKey);
                    insert.bindLong(5, entry.h32);
                    insert.executeInsert();
                }
            } finally {
                insert.close();
            }
            if (countStaged(database, sha256) != batch.entries.size()) {
                throw new StoreException(STATE_CORRUPT);
            }
            database.setTransactionSuccessful();
            committed = true;
        } catch (Throwable ignored) {
            committed = false;
        } finally {
            if (began) {
                try {
                    database.endTransaction();
                } catch (Throwable ignored) {
                    committed = false;
                    invalidateSchemaCache();
                }
            }
        }
        return committed;
    }

    /** Content digests that currently have staged rows; empty when staging cannot be read. */
    public static Set<String> stagedShas(Context context) {
        HashSet<String> staged = new HashSet<String>();
        if (context == null) {
            return staged;
        }
        try {
            SQLiteDatabase database = readableDatabase(context);
            readStagedShas(database, staged);
        } catch (StoreException ignored) {
            staged.clear();
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            staged.clear();
        }
        return staged;
    }

    /** Deletes every staged chunk whose digest is not in {@code keep}. */
    public static boolean pruneStaging(Context context, Set<String> keep) {
        if (context == null || keep == null) {
            return false;
        }
        SQLiteDatabase database;
        try {
            database = writableDatabase(context);
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return false;
        }

        boolean began = false;
        boolean committed = false;
        try {
            database.beginTransaction();
            began = true;
            HashSet<String> staged = new HashSet<String>();
            readStagedShas(database, staged);
            for (String sha256 : staged) {
                if (!keep.contains(sha256)) {
                    database.delete(TABLE_STAGING, "sha256 = ?", new String[] {sha256});
                }
            }
            database.setTransactionSuccessful();
            committed = true;
        } catch (Throwable ignored) {
            committed = false;
        } finally {
            if (began) {
                try {
                    database.endTransaction();
                } catch (Throwable ignored) {
                    committed = false;
                    invalidateSchemaCache();
                }
            }
        }
        return committed;
    }

    /**
     * Reads the committed chunk and group tables so a caller can decide which buckets a new root
     * changes. Any read or invariant failure yields {@code bucketBits == -1}, never an exception.
     */
    public static StoredChunks readChunkTable(Context context) {
        if (context == null) {
            return StoredChunks.unreadable();
        }
        try {
            SQLiteDatabase database = readableDatabase(context);
            StoredMetadata metadata = readMetadata(database, true);
            int bucketBits = metadata == null ? 0 : metadata.bucketBits;
            int[] buckets;
            String[] shas;
            int[] rowCounts;
            int[] idCounts;
            Cursor cursor = database.rawQuery(
                    "SELECT bucket, sha256, row_count, id_count FROM blocklist_chunks "
                            + "ORDER BY bucket",
                    null);
            try {
                int count = cursor.getCount();
                if (count < 0
                        || count > (1 << bucketBits)
                        || (metadata == null && count != 0)) {
                    throw new StoreException(STATE_CORRUPT);
                }
                buckets = new int[count];
                shas = new String[count];
                rowCounts = new int[count];
                idCounts = new int[count];
                int index = 0;
                long previousBucket = -1L;
                while (cursor.moveToNext()) {
                    long bucket = cursor.getLong(0);
                    String sha256 = cursor.getString(1);
                    long rowCount = cursor.getLong(2);
                    long idCount = cursor.getLong(3);
                    if (index >= count
                            || bucket <= previousBucket
                            || bucket >= (1L << bucketBits)
                            || !isSha256Hex(sha256)
                            || rowCount < 1L
                            || rowCount > Integer.MAX_VALUE
                            || idCount < 0L
                            || idCount > rowCount) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                    buckets[index] = (int) bucket;
                    shas[index] = sha256;
                    rowCounts[index] = (int) rowCount;
                    idCounts[index] = (int) idCount;
                    previousBucket = bucket;
                    index++;
                }
                if (index != count) {
                    throw new StoreException(STATE_CORRUPT);
                }
            } finally {
                cursor.close();
            }
            String[] groups;
            Cursor groupCursor = database.rawQuery(
                    "SELECT group_index, sha256 FROM blocklist_groups ORDER BY group_index",
                    null);
            try {
                int count = groupCursor.getCount();
                if (count < 0
                        || count > (1 << MAX_STORED_BUCKET_BITS)
                        || (metadata == null && count != 0)) {
                    throw new StoreException(STATE_CORRUPT);
                }
                groups = new String[count];
                int index = 0;
                while (groupCursor.moveToNext()) {
                    String sha256 = groupCursor.getString(1);
                    if (index >= count
                            || groupCursor.getLong(0) != index
                            || !isSha256Hex(sha256)) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                    groups[index] = sha256;
                    index++;
                }
                if (index != count) {
                    throw new StoreException(STATE_CORRUPT);
                }
            } finally {
                groupCursor.close();
            }
            return new StoredChunks(bucketBits, buckets, shas, rowCounts, idCounts, groups);
        } catch (StoreException ignored) {
            return StoredChunks.unreadable();
        } catch (Throwable ignored) {
            invalidateSchemaCache();
            return StoredChunks.unreadable();
        }
    }

    private static void readStagedShas(SQLiteDatabase database, Set<String> into)
            throws StoreException {
        Cursor cursor = database.rawQuery("SELECT DISTINCT sha256 FROM blocklist_staging", null);
        try {
            while (cursor.moveToNext()) {
                String sha256 = cursor.getString(0);
                if (!isSha256Hex(sha256) || !into.add(sha256) || into.size() > MAX_STAGED_CHUNKS) {
                    throw new StoreException(STATE_CORRUPT);
                }
            }
        } finally {
            cursor.close();
        }
    }

    private static PreparedBatch prepareBatch(List<Entry> source) {
        if (source == null || source.size() > MAX_CHUNK_ROWS) {
            return null;
        }
        ArrayList<PreparedEntry> entries = new ArrayList<PreparedEntry>(source.size());
        Set<String> ids = new HashSet<String>(source.size());
        Set<String> usernames = new HashSet<String>(source.size());
        for (Entry sourceEntry : source) {
            if (sourceEntry == null || !isNumericId(sourceEntry.targetId)
                    || !ids.add(sourceEntry.targetId)) {
                return null;
            }
            String storedUsername = storedUsername(sourceEntry.username);
            String usernameKey = normalizeUsername(storedUsername);
            if (storedUsername.length() == 0 || usernameKey.length() == 0
                    || !usernames.add(usernameKey)) {
                return null;
            }
            if (sourceEntry.h32 < 0L || sourceEntry.h32 > MAX_H32) {
                return null;
            }
            entries.add(new PreparedEntry(
                    sourceEntry.targetId, storedUsername, usernameKey, sourceEntry.h32));
        }
        return new PreparedBatch(entries);
    }

    private static String prepareUpdatedAt(String verifiedUpdatedAt, long verifiedUpdatedAtMs) {
        if (verifiedUpdatedAtMs <= 0L) {
            return null;
        }
        String cleanUpdatedAt = cleanToken(verifiedUpdatedAt, MAX_UPDATED_AT);
        if (cleanUpdatedAt.length() == 0 || !cleanUpdatedAt.equals(verifiedUpdatedAt)) {
            return null;
        }
        try {
            if (Instant.parse(cleanUpdatedAt).toEpochMilli() != verifiedUpdatedAtMs) {
                return null;
            }
        } catch (Throwable ignored) {
            return null;
        }
        return cleanUpdatedAt;
    }

    private static String storedUsername(String value) {
        if (value == null) {
            return "";
        }
        String clean = value.trim();
        while (clean.startsWith("@")) {
            clean = clean.substring(1);
        }
        if (clean.length() == 0 || clean.length() > MAX_USERNAME) {
            return "";
        }
        for (int index = 0; index < clean.length(); index++) {
            char next = clean.charAt(index);
            if (!((next >= 'a' && next <= 'z')
                    || (next >= 'A' && next <= 'Z')
                    || (next >= '0' && next <= '9')
                    || next == '_'
                    || next == '.')) {
                return "";
            }
        }
        return clean;
    }

    private static String normalizeUsername(String value) {
        return storedUsername(value).toLowerCase(Locale.US);
    }

    /** Package-private normalization shared by passive visible-row conflict checks. */
    static String normalizedUsername(String value) {
        return normalizeUsername(value);
    }

    private static boolean validStoredUsername(String username, String usernameKey) {
        return username != null
                && usernameKey != null
                && username.length() > 0
                && username.equals(storedUsername(username))
                && usernameKey.equals(normalizeUsername(username));
    }

    private static boolean isNumericId(String value) {
        if (value == null || value.length() < 4 || value.length() > 24
                || value.charAt(0) == '0') {
            return false;
        }
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (next < '0' || next > '9') {
                return false;
            }
        }
        return true;
    }

    private static String cleanToken(String value, int maxLength) {
        if (value == null || value.length() == 0 || value.length() > maxLength) {
            return "";
        }
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (next < 33 || next > 126) {
                return "";
            }
        }
        return value;
    }
    /** Package-private digest grammar shared with the chunk installer's object names. */
    static boolean isSha256Hex(String value) {
        if (value == null || value.length() != 64) {
            return false;
        }
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (!((next >= '0' && next <= '9') || (next >= 'a' && next <= 'f'))) {
                return false;
            }
        }
        return true;
    }

    /**
     * Unsigned big-endian value of the first four SHA-256 bytes of the UTF-8 {@code key}. Signed
     * rows use {@code "threads:" + id} for ID rows and {@code "threads:@" + username} for
     * handle-only rows; a row's bucket is the high {@code bits} bits of this value.
     */
    static long bucketHash(String key) {
        if (key == null) {
            throw new IllegalArgumentException("bucket key is required");
        }
        byte[] digest;
        try {
            digest = MessageDigest.getInstance("SHA-256")
                    .digest(key.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException ignored) {
            throw new IllegalStateException("bucket digest is unavailable");
        }
        int packed = ((digest[0] & 0xff) << 24)
                | ((digest[1] & 0xff) << 16)
                | ((digest[2] & 0xff) << 8)
                | (digest[3] & 0xff);
        return packed & 0xffffffffL;
    }

    /** Lowest {@code h32} of {@code bucket} under a {@code bits}-bit partition. */
    static long bucketRangeLow(int bucket, int bits) {
        requireBucket(bucket, bits);
        if (bits == 0) {
            return 0L;
        }
        return ((long) bucket) << (32 - bits);
    }

    /** Highest {@code h32} of {@code bucket} under a {@code bits}-bit partition. */
    static long bucketRangeHigh(int bucket, int bits) {
        requireBucket(bucket, bits);
        if (bits == 0) {
            return MAX_H32;
        }
        return (((long) bucket + 1L) << (32 - bits)) - 1L;
    }

    private static void requireBucket(int bucket, int bits) {
        if (bits < 0 || bits > MAX_STORED_BUCKET_BITS || bucket < 0 || bucket >= (1 << bits)) {
            throw new IllegalArgumentException("bucket is outside its partition");
        }
    }

    private static synchronized SQLiteDatabase readableDatabase(Context context)
            throws StoreException {
        return checkedDatabase(context, false);
    }

    private static synchronized SQLiteDatabase writableDatabase(Context context)
            throws StoreException {
        return checkedDatabase(context, true);
    }

    private static SQLiteDatabase checkedDatabase(Context context, boolean writable)
            throws StoreException {
        Context application = context.getApplicationContext();
        Context owner = application == null ? context : application;
        if (databaseHelper == null) {
            databaseHelper = new DatabaseHelper(owner);
            schemaValidated = false;
        }
        SQLiteDatabase database = writable
                ? databaseHelper.getWritableDatabase()
                : databaseHelper.getReadableDatabase();
        if (!schemaValidated) {
            validateSchema(database);
            schemaValidated = true;
        }
        return database;
    }

    private static synchronized void invalidateSchemaCache() {
        schemaValidated = false;
    }

    private static void validateSchema(SQLiteDatabase database) throws StoreException {
        requireSchemaObject(database, "table", TABLE_TARGETS, TARGETS_SQL);
        requireSchemaObject(database, "index", INDEX_USERNAME, USERNAME_INDEX_SQL);
        requireSchemaObject(database, "index", INDEX_H32, H32_INDEX_SQL);
        requireSchemaObject(database, "table", TABLE_METADATA, METADATA_SQL);
        requireSchemaObject(database, "table", TABLE_CHUNKS, CHUNKS_SQL);
        requireSchemaObject(database, "table", TABLE_GROUPS, GROUPS_SQL);
        requireSchemaObject(database, "table", TABLE_STAGING, STAGING_SQL);
    }

    private static void validateSchemaV1(SQLiteDatabase database) throws StoreException {
        requireSchemaObject(database, "table", TABLE_TARGETS, TARGETS_SQL_V2);
        requireSchemaObject(database, "index", INDEX_USERNAME, USERNAME_INDEX_SQL_V2);
        requireSchemaObject(database, "table", TABLE_METADATA, METADATA_SQL_V1);
    }

    private static void validateSchemaV2(SQLiteDatabase database) throws StoreException {
        requireSchemaObject(database, "table", TABLE_TARGETS, TARGETS_SQL_V2);
        requireSchemaObject(database, "index", INDEX_USERNAME, USERNAME_INDEX_SQL_V2);
        requireSchemaObject(database, "table", TABLE_METADATA, METADATA_SQL_V2);
    }

    private static void requireSchemaObject(
            SQLiteDatabase database, String type, String name, String expectedSql)
            throws StoreException {
        Cursor cursor = database.rawQuery(
                "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?",
                new String[] {type, name});
        try {
            if (!cursor.moveToFirst()) {
                throw new StoreException(STATE_CORRUPT);
            }
            String storedSql = cursor.getString(0);
            if (storedSql == null
                    || !normalizeSql(storedSql).equals(normalizeSql(expectedSql))
                    || cursor.moveToNext()) {
                throw new StoreException(STATE_CORRUPT);
            }
        } finally {
            cursor.close();
        }
    }

    private static String normalizeSql(String value) {
        StringBuilder normalized = new StringBuilder(value.length());
        for (int index = 0; index < value.length(); index++) {
            char next = value.charAt(index);
            if (!Character.isWhitespace(next) && next != '`' && next != '"') {
                normalized.append(Character.toLowerCase(next));
            }
        }
        return normalized.toString();
    }

    private static StoredMetadata readMetadata(SQLiteDatabase database, boolean allowMissing)
            throws StoreException {
        return readMetadata(database, allowMissing, 3);
    }

    private static StoredMetadata readMetadataV1(SQLiteDatabase database, boolean allowMissing)
            throws StoreException {
        return readMetadata(database, allowMissing, 1);
    }

    private static StoredMetadata readMetadataV2(SQLiteDatabase database, boolean allowMissing)
            throws StoreException {
        return readMetadata(database, allowMissing, 2);
    }

    private static StoredMetadata readMetadata(
            SQLiteDatabase database, boolean allowMissing, int schemaVersion)
            throws StoreException {
        if (schemaVersion < 1 || schemaVersion > DATABASE_VERSION) {
            throw new StoreException(STATE_CORRUPT);
        }
        int columnCount = schemaVersion == 1 ? 7 : schemaVersion == 2 ? 8 : 9;
        String[] columns = new String[columnCount];
        columns[0] = "singleton_id";
        columns[1] = "valid";
        columns[2] = "generation";
        columns[3] = "verified_updated_at";
        columns[4] = "verified_updated_at_ms";
        columns[5] = "fetched_at_ms";
        columns[6] = "target_count";
        if (columnCount > 7) {
            columns[7] = "new_target_count";
        }
        if (columnCount > 8) {
            columns[8] = "bucket_bits";
        }
        Cursor cursor = database.query(
                TABLE_METADATA,
                columns,
                null,
                null,
                null,
                null,
                null,
                "2");
        try {
            if (!cursor.moveToFirst()) {
                if (allowMissing) {
                    return null;
                }
                throw new StoreException(STATE_CORRUPT);
            }
            int singletonId = cursor.getInt(0);
            int valid = cursor.getInt(1);
            long generation = cursor.getLong(2);
            String updatedAt = cursor.getString(3);
            long updatedAtMs = cursor.getLong(4);
            long fetchedAtMs = cursor.getLong(5);
            long targetCount = cursor.getLong(6);
            long newTargetCount = columnCount > 7
                    ? cursor.getLong(7) : NEW_TARGET_COUNT_UNKNOWN;
            long bucketBits = columnCount > 8 ? cursor.getLong(8) : 0L;
            long parsedUpdatedAtMs;
            try {
                parsedUpdatedAtMs = Instant.parse(updatedAt).toEpochMilli();
            } catch (Throwable invalidTimestamp) {
                throw new StoreException(STATE_CORRUPT);
            }
            if (cursor.moveToNext()
                    || singletonId != 1
                    || valid != 1
                    || generation < 1L
                    || !cleanToken(updatedAt, MAX_UPDATED_AT).equals(updatedAt)
                    || updatedAtMs <= 0L
                    || parsedUpdatedAtMs != updatedAtMs
                    || fetchedAtMs <= 0L
                    || targetCount < 0L
                    || targetCount > MAX_INDEX_ROWS
                    || newTargetCount < -1L
                    || newTargetCount > MAX_INDEX_ROWS
                    || (newTargetCount >= 0L && newTargetCount > targetCount)
                    || bucketBits < 0L
                    || bucketBits > MAX_STORED_BUCKET_BITS) {
                throw new StoreException(STATE_CORRUPT);
            }
            return new StoredMetadata(
                    generation,
                    updatedAt,
                    updatedAtMs,
                    fetchedAtMs,
                    (int) targetCount,
                    (int) newTargetCount,
                    (int) bucketBits);
        } finally {
            cursor.close();
        }
    }

    private static int countNewTargets(
            SQLiteDatabase database, String stagedSha, int declaredIdCount)
            throws StoreException {
        if (!isSha256Hex(stagedSha) || declaredIdCount < 0 || declaredIdCount > MAX_CHUNK_ROWS) {
            throw new StoreException(STATE_CORRUPT);
        }
        Cursor cursor = database.rawQuery(
                "SELECT count(*) FROM blocklist_staging s WHERE s.sha256 = ? "
                        + "AND NOT EXISTS (SELECT 1 FROM blocklist_targets t "
                        + "WHERE t.target_id = s.target_id)",
                new String[] {stagedSha});
        try {
            if (!cursor.moveToFirst()) {
                throw new StoreException(STATE_CORRUPT);
            }
            long counted = cursor.getLong(0);
            if (cursor.moveToNext() || counted < 0L || counted > MAX_CHUNK_ROWS) {
                throw new StoreException(STATE_CORRUPT);
            }
            int newTargetCount = (int) counted;
            if (newTargetCount < 0 || newTargetCount > declaredIdCount) {
                throw new StoreException(STATE_CORRUPT);
            }
            return newTargetCount;
        } finally {
            cursor.close();
        }
    }

    private static long queryLong(SQLiteDatabase database, String sql, String[] arguments)
            throws StoreException {
        Cursor cursor = database.rawQuery(sql, arguments);
        try {
            if (!cursor.moveToFirst() || cursor.isNull(0)) {
                throw new StoreException(STATE_CORRUPT);
            }
            long value = cursor.getLong(0);
            if (cursor.moveToNext()) {
                throw new StoreException(STATE_CORRUPT);
            }
            return value;
        } finally {
            cursor.close();
        }
    }

    private static int countStaged(SQLiteDatabase database, String sha256) throws StoreException {
        long count = queryLong(
                database,
                "SELECT count(*) FROM blocklist_staging WHERE sha256 = ?",
                new String[] {sha256});
        if (count < 0L || count > MAX_CHUNK_ROWS) {
            throw new StoreException(STATE_CORRUPT);
        }
        return (int) count;
    }

    private static void closeStatement(SQLiteStatement statement) {
        if (statement == null) {
            return;
        }
        try {
            statement.close();
        } catch (Throwable ignored) {
            // A close failure cannot change the transaction outcome.
        }
    }

    private static long countRows(SQLiteDatabase database) throws StoreException {
        Cursor cursor = database.rawQuery(
                "SELECT count(*) FROM blocklist_targets", null);
        try {
            if (!cursor.moveToFirst()) {
                throw new StoreException(STATE_CORRUPT);
            }
            long count = cursor.getLong(0);
            if (count < 0L || count > MAX_INDEX_ROWS || cursor.moveToNext()) {
                throw new StoreException(STATE_CORRUPT);
            }
            return count;
        } finally {
            cursor.close();
        }
    }

    private static void requireRowCount(SQLiteDatabase database, int expected)
            throws StoreException {
        if (expected < 0 || expected > MAX_INDEX_ROWS || countRows(database) != expected) {
            throw new StoreException(STATE_CORRUPT);
        }
        Cursor cursor = database.rawQuery(
                "SELECT count(DISTINCT username_key) FROM blocklist_targets", null);
        try {
            if (!cursor.moveToFirst()
                    || cursor.getLong(0) != expected
                    || cursor.moveToNext()) {
                throw new StoreException(STATE_CORRUPT);
            }
        } finally {
            cursor.close();
        }
    }

    private static void requireUniqueUsername(SQLiteDatabase database, String usernameKey)
            throws StoreException {
        Cursor cursor = database.rawQuery(
                "SELECT count(*) FROM blocklist_targets INDEXED BY "
                        + "blocklist_targets_username_idx WHERE username_key = ?",
                new String[] {usernameKey});
        try {
            if (!cursor.moveToFirst()
                    || cursor.getLong(0) != 1L
                    || cursor.moveToNext()) {
                throw new StoreException(STATE_CORRUPT);
            }
        } finally {
            cursor.close();
        }
    }
    /** Copies every retained v2 row into the fresh v3 table together with its bucket hash. */
    private static int copyRetainedTargets(SQLiteDatabase database) throws StoreException {
        SQLiteStatement insert = database.compileStatement(
                "INSERT INTO blocklist_targets (target_id,username,username_key,h32) "
                        + "VALUES (?,?,?,?)");
        try {
            Cursor cursor = database.rawQuery(
                    "SELECT target_id, username, username_key FROM blocklist_targets_v2 "
                            + "ORDER BY target_id",
                    null);
            try {
                int copied = 0;
                while (cursor.moveToNext()) {
                    String targetId = cursor.getString(0);
                    String username = cursor.getString(1);
                    String usernameKey = cursor.getString(2);
                    if (copied >= MAX_INDEX_ROWS
                            || !isNumericId(targetId)
                            || !validStoredUsername(username, usernameKey)) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                    insert.bindString(1, targetId);
                    insert.bindString(2, username);
                    insert.bindString(3, usernameKey);
                    insert.bindLong(4, bucketHash("threads:" + targetId));
                    insert.executeInsert();
                    copied++;
                }
                return copied;
            } finally {
                cursor.close();
            }
        } finally {
            insert.close();
        }
    }

    private static final class PreparedEntry {
        final String targetId;
        final String username;
        final String usernameKey;
        final long h32;

        PreparedEntry(String targetId, String username, String usernameKey, long h32) {
            this.targetId = targetId;
            this.username = username;
            this.usernameKey = usernameKey;
            this.h32 = h32;
        }
    }

    private static final class PreparedBatch {
        final List<PreparedEntry> entries;

        PreparedBatch(List<PreparedEntry> entries) {
            this.entries = entries;
        }
    }

    private static final class StoredMetadata {
        final long generation;
        final String verifiedUpdatedAt;
        final long verifiedUpdatedAtMs;
        final long fetchedAtMs;
        final int targetCount;
        final int newTargetCount;
        final int bucketBits;

        StoredMetadata(
                long generation,
                String verifiedUpdatedAt,
                long verifiedUpdatedAtMs,
                long fetchedAtMs,
                int targetCount,
                int newTargetCount,
                int bucketBits) {
            this.generation = generation;
            this.verifiedUpdatedAt = verifiedUpdatedAt;
            this.verifiedUpdatedAtMs = verifiedUpdatedAtMs;
            this.fetchedAtMs = fetchedAtMs;
            this.targetCount = targetCount;
            this.newTargetCount = newTargetCount;
            this.bucketBits = bucketBits;
        }
    }

    private static final class StoreException extends Exception {
        final String state;

        StoreException(String state) {
            this.state = state;
        }
    }

    private static final class DatabaseHelper extends SQLiteOpenHelper {
        DatabaseHelper(Context context) {
            super(
                    context,
                    DATABASE_NAME,
                    null,
                    DATABASE_VERSION,
                    new DatabaseErrorHandler() {
                        @Override
                        public void onCorruption(SQLiteDatabase database) {
                            throw new SQLiteException(
                                    "blocklist database corruption requires refresh review");
                        }
                    });
        }

        @Override
        public void onCreate(SQLiteDatabase database) {
            database.execSQL(TARGETS_SQL);
            database.execSQL(USERNAME_INDEX_SQL);
            database.execSQL(H32_INDEX_SQL);
            database.execSQL(METADATA_SQL);
            database.execSQL(CHUNKS_SQL);
            database.execSQL(GROUPS_SQL);
            database.execSQL(STAGING_SQL);
            schemaValidated = false;
        }

        @Override
        public void onUpgrade(SQLiteDatabase database, int oldVersion, int newVersion) {
            if (newVersion != 3 || oldVersion < 1 || oldVersion > 2) {
                throw new SQLiteException("blocklist database upgrade requires reviewed migration");
            }
            try {
                if (oldVersion == 1) {
                    validateSchemaV1(database);
                    StoredMetadata previous = readMetadataV1(database, true);
                    if (previous == null) {
                        if (countRows(database) != 0) {
                            throw new StoreException(STATE_CORRUPT);
                        }
                    } else {
                        requireRowCount(database, previous.targetCount);
                    }

                    database.execSQL(
                            "ALTER TABLE blocklist_metadata ADD COLUMN "
                                    + NEW_TARGET_COUNT_COLUMN_SQL);
                    validateSchemaV2(database);

                    StoredMetadata migrated = readMetadataV2(database, true);
                    if (previous == null) {
                        if (migrated != null || countRows(database) != 0) {
                            throw new StoreException(STATE_CORRUPT);
                        }
                    } else if (migrated == null
                            || migrated.generation != previous.generation
                            || !migrated.verifiedUpdatedAt.equals(previous.verifiedUpdatedAt)
                            || migrated.verifiedUpdatedAtMs != previous.verifiedUpdatedAtMs
                            || migrated.fetchedAtMs != previous.fetchedAtMs
                            || migrated.targetCount != previous.targetCount
                            || migrated.newTargetCount != NEW_TARGET_COUNT_UNKNOWN) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                }

                // v2 to v3: SQLite cannot widen a CHECK, so the retained generation moves into
                // fresh tables. The renamed v2 tables stay behind empty and are never read again.
                validateSchemaV2(database);
                StoredMetadata previousV2 = readMetadataV2(database, true);
                if (previousV2 == null) {
                    if (countRows(database) != 0) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                } else {
                    requireRowCount(database, previousV2.targetCount);
                }
                database.execSQL("DROP INDEX blocklist_targets_username_idx");
                database.execSQL("ALTER TABLE blocklist_targets RENAME TO blocklist_targets_v2");
                database.execSQL("ALTER TABLE blocklist_metadata RENAME TO blocklist_metadata_v2");
                database.execSQL(TARGETS_SQL);
                database.execSQL(USERNAME_INDEX_SQL);
                database.execSQL(H32_INDEX_SQL);
                database.execSQL(METADATA_SQL);
                database.execSQL(CHUNKS_SQL);
                database.execSQL(GROUPS_SQL);
                database.execSQL(STAGING_SQL);
                int copied = copyRetainedTargets(database);
                if (copied != (previousV2 == null ? 0 : previousV2.targetCount)) {
                    throw new StoreException(STATE_CORRUPT);
                }
                if (previousV2 != null) {
                    database.execSQL(
                            "INSERT INTO blocklist_metadata (singleton_id,valid,generation,"
                                    + "verified_updated_at,verified_updated_at_ms,fetched_at_ms,"
                                    + "target_count,new_target_count,bucket_bits) "
                                    + "SELECT singleton_id,valid,generation,verified_updated_at,"
                                    + "verified_updated_at_ms,fetched_at_ms,target_count,"
                                    + "new_target_count,0 FROM blocklist_metadata_v2");
                }
                database.execSQL("DELETE FROM blocklist_targets_v2");
                database.execSQL("DELETE FROM blocklist_metadata_v2");
                validateSchema(database);

                StoredMetadata migratedV3 = readMetadata(database, true);
                if (previousV2 == null) {
                    if (migratedV3 != null) {
                        throw new StoreException(STATE_CORRUPT);
                    }
                } else if (migratedV3 == null
                        || migratedV3.generation != previousV2.generation
                        || !migratedV3.verifiedUpdatedAt.equals(previousV2.verifiedUpdatedAt)
                        || migratedV3.verifiedUpdatedAtMs != previousV2.verifiedUpdatedAtMs
                        || migratedV3.fetchedAtMs != previousV2.fetchedAtMs
                        || migratedV3.targetCount != previousV2.targetCount
                        || migratedV3.newTargetCount != previousV2.newTargetCount
                        || migratedV3.bucketBits != 0) {
                    throw new StoreException(STATE_CORRUPT);
                }
                requireRowCount(database, migratedV3 == null ? 0 : migratedV3.targetCount);
                schemaValidated = false;
            } catch (StoreException invalidMigration) {
                throw new SQLiteException(
                        "blocklist database v2 migration requires review");
            }
        }

        @Override
        public void onDowngrade(SQLiteDatabase database, int oldVersion, int newVersion) {
            throw new SQLiteException("blocklist database downgrade requires reviewed migration");
        }
    }
}
