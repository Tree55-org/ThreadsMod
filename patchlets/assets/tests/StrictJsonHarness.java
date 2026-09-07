package threadsmod.reporting;

import java.nio.charset.StandardCharsets;

public final class StrictJsonHarness {
    public static void main(String[] args) {
        expect(true, "{\"ok\":true}");
        expect(true, " \r\n {\"ok\":true,\"duplicate\":false,\"meta\":[1,-2.5e+3,null,\"x\\u0020y\"]} \t");
        expect(false, "{\"ok\":true} trailing");
        expect(false, "{ok:true}");
        expect(false, "{'ok':true}");
        expect(false, "{/*comment*/\"ok\":true}");
        expect(false, "{\"ok\":true,}");
        expect(false, "{\"ok\":false,\"ok\":true}");
        expect(false, "{\"ok\":false,\"o\\u006b\":true}");
        expect(false, "{\"ok\":01}");
        expect(false, "[ {\"ok\":true} ]");
        expect(false, "{\"ok\":true");
        expect(false, "{\"ok\":true,\"broken\":\"\\uD800\"}");
        expectUtf8("{\"ok\":true}", "{\"ok\":true}".getBytes(StandardCharsets.UTF_8));
        expectUtf8(null, new byte[] {'{', '"', 'x', '"', ':', '"', (byte) 0xff, '"', '}'});
        System.out.println(
                "PASS report-json strict=true trailing=false lenient=false duplicates=false utf8=false");
    }

    private static void expect(boolean expected, String input) {
        boolean actual = ReportJson.isCompleteObject(input);
        if (actual != expected) {
            throw new AssertionError("Unexpected strict JSON result for: " + input);
        }
    }

    private static void expectUtf8(String expected, byte[] input) {
        String actual = ReportJson.decodeUtf8(input);
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("Unexpected strict UTF-8 result");
        }
    }
}
