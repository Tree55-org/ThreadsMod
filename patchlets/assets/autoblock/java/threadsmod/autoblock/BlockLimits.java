package threadsmod.autoblock;

/** Immutable, validated pacing configuration for passive block work. */
public final class BlockLimits {
    public static final int MIN_PASSIVE_MIN_DELAY_MS = 2000;
    public static final int MAX_PASSIVE_MIN_DELAY_MS = 60000;
    public static final int MIN_PASSIVE_MAX_DELAY_MS = 3000;
    public static final int MAX_PASSIVE_MAX_DELAY_MS = 60000;

    public static final int DEFAULT_PASSIVE_MIN_DELAY_MS = 4000;
    public static final int DEFAULT_PASSIVE_MAX_DELAY_MS = 10000;

    private final int passiveMinDelayMs;
    private final int passiveMaxDelayMs;

    private BlockLimits(int passiveMinDelayMs, int passiveMaxDelayMs) {
        this.passiveMinDelayMs = passiveMinDelayMs;
        this.passiveMaxDelayMs = passiveMaxDelayMs;
    }

    public static BlockLimits defaults() {
        return new BlockLimits(
                DEFAULT_PASSIVE_MIN_DELAY_MS,
                DEFAULT_PASSIVE_MAX_DELAY_MS);
    }

    /** Creates one passive-delay snapshot, rejecting invalid or inverted input. */
    public static BlockLimits checked(int passiveMinDelayMs, int passiveMaxDelayMs) {
        requireRange(
                "passive minimum delay",
                passiveMinDelayMs,
                MIN_PASSIVE_MIN_DELAY_MS,
                MAX_PASSIVE_MIN_DELAY_MS);
        requireRange(
                "passive maximum delay",
                passiveMaxDelayMs,
                MIN_PASSIVE_MAX_DELAY_MS,
                MAX_PASSIVE_MAX_DELAY_MS);
        requireWholeSecond("passive minimum delay", passiveMinDelayMs);
        requireWholeSecond("passive maximum delay", passiveMaxDelayMs);
        if (passiveMinDelayMs > passiveMaxDelayMs) {
            throw new IllegalArgumentException(
                    "Passive minimum delay cannot exceed its maximum.");
        }
        return new BlockLimits(passiveMinDelayMs, passiveMaxDelayMs);
    }

    static BlockLimits sanitized(int passiveMinDelayMs, int passiveMaxDelayMs) {
        int passiveMin = sanitizeWholeSecond(
                passiveMinDelayMs,
                MIN_PASSIVE_MIN_DELAY_MS,
                MAX_PASSIVE_MIN_DELAY_MS,
                DEFAULT_PASSIVE_MIN_DELAY_MS);
        int passiveMax = sanitizeWholeSecond(
                passiveMaxDelayMs,
                MIN_PASSIVE_MAX_DELAY_MS,
                MAX_PASSIVE_MAX_DELAY_MS,
                DEFAULT_PASSIVE_MAX_DELAY_MS);
        if (passiveMin > passiveMax) {
            return defaults();
        }
        return new BlockLimits(passiveMin, passiveMax);
    }

    private static void requireRange(String label, int value, int minimum, int maximum) {
        if (value < minimum || value > maximum) {
            throw new IllegalArgumentException(
                    label + " must be between " + minimum + " and " + maximum + ".");
        }
    }

    private static void requireWholeSecond(String label, int value) {
        if (value % 1000 != 0) {
            throw new IllegalArgumentException(label + " must use whole-second steps.");
        }
    }

    private static int sanitizeWholeSecond(
            int value, int minimum, int maximum, int fallback) {
        if (value < minimum || value > maximum || value % 1000 != 0) {
            return fallback;
        }
        return value;
    }

    public int passiveMinDelayMs() { return passiveMinDelayMs; }
    public int passiveMaxDelayMs() { return passiveMaxDelayMs; }
}
