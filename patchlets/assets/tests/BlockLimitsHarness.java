package threadsmod.autoblock;

/** Host-JVM checks for the exact passive-delay configuration contract. */
public final class BlockLimitsHarness {
    private BlockLimitsHarness() {}

    public static void main(String[] args) {
        verifyPublishedConstants();
        verifyDefaults();
        verifyExactCheckedContract();
        verifySanitizedFallbacks();
        System.out.println(
                "PASS passive-limits fields=2 defaults=4,10 ranges=2-60,3-60 steps=whole-second ordering=true failclosed=true");
    }

    private static void verifyPublishedConstants() {
        require(BlockLimits.MIN_PASSIVE_MIN_DELAY_MS == 2000,
                "passive minimum lower bound");
        require(BlockLimits.MAX_PASSIVE_MIN_DELAY_MS == 60000,
                "passive minimum upper bound");
        require(BlockLimits.MIN_PASSIVE_MAX_DELAY_MS == 3000,
                "passive maximum lower bound");
        require(BlockLimits.MAX_PASSIVE_MAX_DELAY_MS == 60000,
                "passive maximum upper bound");
        require(BlockLimits.DEFAULT_PASSIVE_MIN_DELAY_MS == 4000,
                "passive minimum default");
        require(BlockLimits.DEFAULT_PASSIVE_MAX_DELAY_MS == 10000,
                "passive maximum default");
    }

    private static void verifyDefaults() {
        BlockLimits defaults = BlockLimits.defaults();
        require(defaults.passiveMinDelayMs() == 4000, "default passive minimum");
        require(defaults.passiveMaxDelayMs() == 10000, "default passive maximum");
    }

    private static void verifyExactCheckedContract() {
        expectValid("lower bounds", 2000, 3000);
        expectValid("upper bounds", 60000, 60000);
        expectValid("ordinary whole seconds", 4000, 10000);

        expectInvalid("minimum below range", 1000, 3000);
        expectInvalid("minimum above range", 61000, 61000);
        expectInvalid("minimum half-second step", 2500, 3000);
        expectInvalid("maximum below range", 2000, 2000);
        expectInvalid("maximum above range", 2000, 61000);
        expectInvalid("maximum half-second step", 2000, 3500);
        expectInvalid("inverted ordering", 4000, 3000);
    }

    private static void verifySanitizedFallbacks() {
        BlockLimits invalidSteps = BlockLimits.sanitized(2001, 3001);
        require(invalidSteps.passiveMinDelayMs() == 4000,
                "invalid minimum step fallback");
        require(invalidSteps.passiveMaxDelayMs() == 10000,
                "invalid maximum step fallback");

        BlockLimits inverted = BlockLimits.sanitized(60000, 3000);
        require(inverted.passiveMinDelayMs() == 4000,
                "inverted minimum fallback");
        require(inverted.passiveMaxDelayMs() == 10000,
                "inverted maximum fallback");

        BlockLimits valid = BlockLimits.sanitized(2000, 60000);
        require(valid.passiveMinDelayMs() == 2000, "valid minimum retained");
        require(valid.passiveMaxDelayMs() == 60000, "valid maximum retained");
    }

    private static void expectInvalid(String label, int passiveMin, int passiveMax) {
        try {
            BlockLimits.checked(passiveMin, passiveMax);
            throw new AssertionError("invalid passive delay was accepted: " + label);
        } catch (IllegalArgumentException expected) {
            // Expected fail-closed validation.
        }
    }

    private static void expectValid(String label, int passiveMin, int passiveMax) {
        try {
            BlockLimits.checked(passiveMin, passiveMax);
        } catch (IllegalArgumentException invalid) {
            throw new AssertionError("valid passive delay was rejected: " + label, invalid);
        }
    }

    private static void require(boolean value, String label) {
        if (!value) {
            throw new AssertionError(label);
        }
    }
}
