import jadx.api.JadxArgs;
import jadx.api.JadxDecompiler;
import jadx.api.JavaClass;
import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public final class TargetedJadxRecovery {
    private TargetedJadxRecovery() {}

    private static String json(String value) {
        StringBuilder out = new StringBuilder(value.length() + 16);
        out.append('"');
        for (int index = 0; index < value.length(); index++) {
            char current = value.charAt(index);
            switch (current) {
                case '"': out.append("\\\""); break;
                case '\\': out.append("\\\\"); break;
                case '\b': out.append("\\b"); break;
                case '\f': out.append("\\f"); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default:
                    if (current < 0x20) {
                        out.append(String.format("\\u%04x", (int) current));
                    } else {
                        out.append(current);
                    }
            }
        }
        return out.append('"').toString();
    }

    private static JavaClass resolve(List<JavaClass> classes, String target) {
        JavaClass match = null;
        for (JavaClass candidate : classes) {
            if (target.equals(candidate.getRawName()) || target.equals(candidate.getFullName())) {
                if (match != null && match != candidate) {
                    throw new IllegalStateException("JADX target is ambiguous: " + target);
                }
                match = candidate;
            }
        }
        if (match == null) {
            throw new IllegalStateException("JADX target was not found: " + target);
        }
        return match;
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            throw new IllegalArgumentException(
                    "usage: TargetedJadxRecovery <apk> <output-directory> <class> [<class> ...]");
        }

        File apk = new File(args[0]).getCanonicalFile();
        if (!apk.isFile()) {
            throw new IllegalArgumentException("APK does not exist: " + apk);
        }
        Path output = new File(args[1]).getCanonicalFile().toPath();
        Files.createDirectories(output);

        Set<String> targets = new LinkedHashSet<>();
        for (int index = 2; index < args.length; index++) {
            if (!targets.add(args[index])) {
                throw new IllegalArgumentException("Duplicate JADX target: " + args[index]);
            }
        }

        Logger rootLogger = (Logger) LoggerFactory.getLogger(Logger.ROOT_LOGGER_NAME);
        rootLogger.setLevel(Level.OFF);

        JadxArgs jadxArgs = new JadxArgs();
        jadxArgs.setInputFiles(Collections.singletonList(apk));
        jadxArgs.setSkipResources(true);
        jadxArgs.setSkipFilesSave(true);
        jadxArgs.setIncludeDependencies(false);
        jadxArgs.setShowInconsistentCode(true);
        jadxArgs.setClassFilter(targets::contains);
        jadxArgs.setThreadsCount(2);

        JadxDecompiler jadx = new JadxDecompiler(jadxArgs);
        List<String> recovered = new ArrayList<>();
        try {
            jadx.load();
            List<JavaClass> classes = jadx.getClassesWithInners();
            for (int index = 2; index < args.length; index++) {
                String target = args[index];
                JavaClass javaClass = resolve(classes, target);
                String code = javaClass.getCode();
                if (code == null || code.trim().isEmpty()) {
                    throw new IllegalStateException("JADX returned empty code for: " + target);
                }
                String fileName = String.format("target-%02d.java", index - 1);
                Files.write(output.resolve(fileName), code.getBytes(StandardCharsets.UTF_8));
                recovered.add(target);
            }
        } finally {
            jadx.close();
            jadxArgs.close();
        }

        StringBuilder result = new StringBuilder("{\"status\":\"passed\",\"recoveredClasses\":[");
        for (int index = 0; index < recovered.size(); index++) {
            if (index != 0) result.append(',');
            result.append(json(recovered.get(index)));
        }
        result.append("]}");
        System.out.println(result);
    }
}
