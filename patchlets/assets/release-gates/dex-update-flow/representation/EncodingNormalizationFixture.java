package threadsmod.update;

final class EncodingNormalizationFixture {
    private EncodingNormalizationFixture() {}

    static String branchTryAndSwitch(int value) {
        try {
            switch (value) {
                case 1:
                    return "encoding-one";
                case 4:
                    return "encoding-four";
                case 9:
                    return "encoding-nine";
                default:
                    return "encoding-other";
            }
        } catch (RuntimeException ignored) {
            return "encoding-failure";
        }
    }
}
