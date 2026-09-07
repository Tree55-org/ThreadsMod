import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.Adler32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public final class DexInspector {
    private static byte[] readAll(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[65536];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }

    private static long uint32le(byte[] bytes, int offset) {
        return ((long) bytes[offset] & 0xffL)
                | (((long) bytes[offset + 1] & 0xffL) << 8)
                | (((long) bytes[offset + 2] & 0xffL) << 16)
                | (((long) bytes[offset + 3] & 0xffL) << 24);
    }

    private static boolean contains(byte[] haystack, byte[] needle) {
        if (needle.length == 0) return true;
        outer:
        for (int i = 0; i <= haystack.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) continue outer;
            }
            return true;
        }
        return false;
    }

    private static boolean containsAsciiIgnoreCase(byte[] haystack, byte[] needle) {
        if (needle.length == 0) return true;
        outer:
        for (int i = 0; i <= haystack.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                int left = haystack[i + j] & 0xff;
                int right = needle[j] & 0xff;
                if (left >= 'A' && left <= 'Z') left += 'a' - 'A';
                if (right >= 'A' && right <= 'Z') right += 'a' - 'A';
                if (left != right) continue outer;
            }
            return true;
        }
        return false;
    }

    private static int verifyDex(String name, byte[] dex) throws Exception {
        if (dex.length < 112 || dex[0] != 'd' || dex[1] != 'e' || dex[2] != 'x' || dex[3] != '\n' || dex[7] != 0) {
            throw new IllegalStateException(name + " is not a supported DEX file");
        }
        long storedChecksum = uint32le(dex, 8);
        Adler32 adler = new Adler32();
        adler.update(dex, 12, dex.length - 12);
        if (storedChecksum != adler.getValue()) {
            throw new IllegalStateException(name + " has an invalid Adler32 header checksum");
        }
        MessageDigest sha1 = MessageDigest.getInstance("SHA-1");
        byte[] calculatedSignature = sha1.digest(Arrays.copyOfRange(dex, 32, dex.length));
        byte[] storedSignature = Arrays.copyOfRange(dex, 12, 32);
        if (!Arrays.equals(storedSignature, calculatedSignature)) {
            throw new IllegalStateException(name + " has an invalid SHA-1 header signature");
        }
        long methods = uint32le(dex, 88);
        if (methods > Integer.MAX_VALUE) throw new IllegalStateException(name + " method count is invalid");
        return (int) methods;
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }

    private static String stringArray(List<String> values) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < values.size(); i++) {
            if (i > 0) json.append(',');
            json.append('\"').append(escape(values.get(i))).append('\"');
        }
        return json.append(']').toString();
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: DexInspector APK [--expected-root-dex=N] [--max-primary-methods=N] [--require=TEXT] [--forbid=TEXT]");
            System.exit(2);
        }
        String apkPath = args[0];
        int expectedRootDex = -1;
        int maxPrimaryMethods = 65535;
        List<String> required = new ArrayList<>();
        List<String> forbidden = new ArrayList<>();
        for (int i = 1; i < args.length; i++) {
            String arg = args[i];
            if (arg.startsWith("--expected-root-dex=")) expectedRootDex = Integer.parseInt(arg.substring(20));
            else if (arg.startsWith("--max-primary-methods=")) maxPrimaryMethods = Integer.parseInt(arg.substring(22));
            else if (arg.startsWith("--require=")) required.add(arg.substring(10));
            else if (arg.startsWith("--forbid=")) forbidden.add(arg.substring(9));
            else throw new IllegalArgumentException("unknown argument: " + arg);
        }

        Map<String, Boolean> requiredFound = new LinkedHashMap<>();
        Map<String, Boolean> forbiddenFound = new LinkedHashMap<>();
        for (String value : required) requiredFound.put(value, false);
        for (String value : forbidden) forbiddenFound.put(value, false);
        List<String> rootDexNames = new ArrayList<>();
        List<String> allDexNames = new ArrayList<>();
        Set<String> uniqueDexNames = new HashSet<>();
        int primaryMethods = -1;

        try (ZipFile apk = new ZipFile(apkPath)) {
            List<? extends ZipEntry> entries = Collections.list(apk.entries());
            entries.sort((left, right) -> left.getName().compareTo(right.getName()));
            for (ZipEntry entry : entries) {
                if (entry.isDirectory()) continue;
                String name = entry.getName();
                if (!name.endsWith(".dex")) continue;
                if (!uniqueDexNames.add(name)) {
                    throw new IllegalStateException("duplicate DEX ZIP entry name: " + name);
                }
                byte[] bytes;
                try (InputStream input = apk.getInputStream(entry)) {
                    bytes = readAll(input);
                }
                int methods = verifyDex(name, bytes);
                for (String value : required) {
                    if (!requiredFound.get(value) && contains(bytes, value.getBytes(StandardCharsets.US_ASCII))) requiredFound.put(value, true);
                }
                for (String value : forbidden) {
                    if (!forbiddenFound.get(value)
                            && containsAsciiIgnoreCase(
                                    bytes, value.getBytes(StandardCharsets.US_ASCII))) {
                        forbiddenFound.put(value, true);
                    }
                }
                allDexNames.add(name);
                if (name.matches("classes(?:[0-9]+)?\\.dex")) {
                    rootDexNames.add(name);
                    if (name.equals("classes.dex")) primaryMethods = methods;
                }
            }
        }

        Collections.sort(rootDexNames);
        Collections.sort(allDexNames);
        if (expectedRootDex >= 0) {
            List<String> expectedRootDexNames = new ArrayList<>();
            expectedRootDexNames.add("classes.dex");
            for (int index = 2; index <= expectedRootDex; index++) {
                expectedRootDexNames.add("classes" + index + ".dex");
            }
            Collections.sort(expectedRootDexNames);
            if (!rootDexNames.equals(expectedRootDexNames)) {
                throw new IllegalStateException(
                        "root DEX inventory differs from exact expected names: expected="
                                + expectedRootDexNames + " observed=" + rootDexNames);
            }
        }
        if (primaryMethods < 0) throw new IllegalStateException("classes.dex is missing");
        if (primaryMethods > maxPrimaryMethods) {
            throw new IllegalStateException("primary method references " + primaryMethods + " exceed " + maxPrimaryMethods);
        }
        List<String> missing = new ArrayList<>();
        for (Map.Entry<String, Boolean> item : requiredFound.entrySet()) if (!item.getValue()) missing.add(item.getKey());
        List<String> presentForbidden = new ArrayList<>();
        for (Map.Entry<String, Boolean> item : forbiddenFound.entrySet()) if (item.getValue()) presentForbidden.add(item.getKey());
        if (!missing.isEmpty()) throw new IllegalStateException("required DEX strings are missing: " + missing);
        if (!presentForbidden.isEmpty()) throw new IllegalStateException("forbidden DEX strings are present: " + presentForbidden);

        System.out.println("{\"status\":\"passed\",\"rootDexCount\":" + rootDexNames.size()
                + ",\"allDexCount\":" + allDexNames.size()
                + ",\"primaryMethodReferences\":" + primaryMethods
                + ",\"rootDexNames\":" + stringArray(rootDexNames)
                + ",\"allDexNames\":" + stringArray(allDexNames)
                + ",\"requiredStrings\":" + stringArray(required)
                + ",\"forbiddenStrings\":" + stringArray(forbidden) + "}");
    }
}
