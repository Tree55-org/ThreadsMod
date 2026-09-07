package threadsmod.update;

import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;

/** Strict RFC-8259 gate used before Android's permissive JSONObject parser. */
final class UpdateJson {
    private static final int MAX_CHARS = 24 * 1024;
    private static final int MAX_DEPTH = 24;

    private UpdateJson() {}

    static String decodeUtf8(byte[] input) {
        if (input == null) return null;
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(input)).toString();
        } catch (Throwable ignored) {
            return null;
        }
    }

    static boolean isCompleteObject(String input) {
        if (input == null || input.length() == 0 || input.length() > MAX_CHARS) return false;
        Parser parser = new Parser(input);
        parser.ws();
        if (!parser.object(0)) return false;
        parser.ws();
        return parser.end();
    }

    static String extractTopLevelValue(String input, String wantedName) {
        if (!isCompleteObject(input) || wantedName == null) return null;
        Parser parser = new Parser(input);
        parser.ws();
        if (!parser.take('{')) return null;
        parser.ws();
        if (parser.take('}')) return null;
        while (true) {
            parser.ws();
            String name = parser.string();
            parser.ws();
            if (name == null || !parser.take(':')) return null;
            parser.ws();
            int start = parser.index;
            if (!parser.value(1)) return null;
            int end = parser.index;
            if (wantedName.equals(name)) return input.substring(start, end);
            parser.ws();
            if (parser.take('}')) return null;
            if (!parser.take(',')) return null;
        }
    }

    private static final class Parser {
        final String text;
        int index;
        Parser(String text) { this.text = text; }
        boolean end() { return index == text.length(); }
        void ws() { while (!end() && " \t\r\n".indexOf(text.charAt(index)) >= 0) index++; }
        boolean take(char c) { if (!end() && text.charAt(index) == c) { index++; return true; } return false; }
        boolean value(int depth) {
            if (depth > MAX_DEPTH) return false;
            ws();
            if (end()) return false;
            char c = text.charAt(index);
            if (c == '{') return object(depth);
            if (c == '[') return array(depth);
            if (c == '"') return string() != null;
            if (c == 't') return literal("true");
            if (c == 'f') return literal("false");
            if (c == 'n') return literal("null");
            return c == '-' || digit(c) ? number() : false;
        }
        boolean object(int depth) {
            if (depth > MAX_DEPTH || !take('{')) return false;
            ws();
            if (take('}')) return true;
            Set<String> names = new HashSet<String>();
            while (true) {
                ws();
                String name = string();
                ws();
                if (name == null || !names.add(name) || !take(':') || !value(depth + 1)) return false;
                ws();
                if (take('}')) return true;
                if (!take(',')) return false;
            }
        }
        boolean array(int depth) {
            if (depth > MAX_DEPTH || !take('[')) return false;
            ws();
            if (take(']')) return true;
            while (true) {
                if (!value(depth + 1)) return false;
                ws();
                if (take(']')) return true;
                if (!take(',')) return false;
            }
        }
        String string() {
            if (!take('"')) return null;
            StringBuilder out = new StringBuilder();
            while (!end()) {
                char c = text.charAt(index++);
                if (c == '"') return out.toString();
                if (c < 0x20) return null;
                if (Character.isHighSurrogate(c)) {
                    if (end() || !Character.isLowSurrogate(text.charAt(index))) return null;
                    out.append(c).append(text.charAt(index++));
                    continue;
                }
                if (Character.isLowSurrogate(c)) return null;
                if (c != '\\') { out.append(c); continue; }
                if (end()) return null;
                char escaped = text.charAt(index++);
                if (escaped == '"' || escaped == '\\' || escaped == '/') out.append(escaped);
                else if (escaped == 'b') out.append('\b');
                else if (escaped == 'f') out.append('\f');
                else if (escaped == 'n') out.append('\n');
                else if (escaped == 'r') out.append('\r');
                else if (escaped == 't') out.append('\t');
                else if (escaped == 'u') {
                    if (index + 4 > text.length()) return null;
                    int code = 0;
                    for (int i = 0; i < 4; i++) {
                        int hex = Character.digit(text.charAt(index++), 16);
                        if (hex < 0) return null;
                        code = code * 16 + hex;
                    }
                    char decoded = (char) code;
                    if (Character.isHighSurrogate(decoded)) {
                        if (index + 6 > text.length() || text.charAt(index++) != '\\'
                                || text.charAt(index++) != 'u') return null;
                        int lowCode = 0;
                        for (int i = 0; i < 4; i++) {
                            int hex = Character.digit(text.charAt(index++), 16);
                            if (hex < 0) return null;
                            lowCode = lowCode * 16 + hex;
                        }
                        char low = (char) lowCode;
                        if (!Character.isLowSurrogate(low)) return null;
                        out.append(decoded).append(low);
                    } else if (Character.isLowSurrogate(decoded)) return null;
                    else out.append(decoded);
                } else return null;
            }
            return null;
        }
        boolean literal(String literal) {
            if (!text.regionMatches(index, literal, 0, literal.length())) return false;
            index += literal.length();
            return true;
        }
        boolean number() {
            int start = index;
            take('-');
            if (take('0')) {
                if (!end() && digit(text.charAt(index))) return false;
            } else {
                if (end() || !nonzero(text.charAt(index))) return false;
                while (!end() && digit(text.charAt(index))) index++;
            }
            if (take('.')) {
                int fractional = index;
                while (!end() && digit(text.charAt(index))) index++;
                if (fractional == index) return false;
            }
            if (!end() && (text.charAt(index) == 'e' || text.charAt(index) == 'E')) {
                index++;
                if (!end() && (text.charAt(index) == '+' || text.charAt(index) == '-')) index++;
                int exponent = index;
                while (!end() && digit(text.charAt(index))) index++;
                if (exponent == index) return false;
            }
            return index > start;
        }
        static boolean digit(char c) { return c >= '0' && c <= '9'; }
        static boolean nonzero(char c) { return c >= '1' && c <= '9'; }
    }
}
