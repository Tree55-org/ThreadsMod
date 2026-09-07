package android.os;

/** Mutable SDK selector used only by the host route-plan harness. */
public final class Build {
    private Build() {}

    public static final class VERSION {
        private VERSION() {}

        public static int SDK_INT = 33;
    }
}
