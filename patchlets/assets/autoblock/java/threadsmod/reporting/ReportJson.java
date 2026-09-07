package threadsmod.reporting;

import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;

/** Small strict RFC-8259 syntax gate used before Android's lenient JSONObject parser. */
final class ReportJson {
    private static final int MAX_JSON_CHARS = 8 * 1024;
    private static final int MAX_DEPTH = 32;

    private ReportJson() {}

    /** Decodes without replacement characters so byte-invalid relay bodies cannot be acknowledged. */
    static String decodeUtf8(byte[] input) {
        if (input == null) {
            return null;
        }
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(input))
                    .toString();
        } catch (Throwable invalidEncoding) {
            return null;
        }
    }

    static boolean isCompleteObject(String input) {
        if (input == null || input.length() == 0 || input.length() > MAX_JSON_CHARS) {
            return false;
        }
        Parser parser = new Parser(input);
        parser.skipWhitespace();
        if (!parser.peek('{') || !parser.readObject(0)) {
            return false;
        }
        parser.skipWhitespace();
        return parser.atEnd();
    }

    private static final class Parser {
        private final String input;
        private int index;

        Parser(String input) {
            this.input = input;
        }

        boolean readValue(int depth) {
            if (depth > MAX_DEPTH) {
                return false;
            }
            skipWhitespace();
            if (atEnd()) {
                return false;
            }
            char value = input.charAt(index);
            if (value == '{') {
                return readObject(depth);
            }
            if (value == '[') {
                return readArray(depth);
            }
            if (value == '"') {
                return readStringValue() != null;
            }
            if (value == 't') {
                return readLiteral("true");
            }
            if (value == 'f') {
                return readLiteral("false");
            }
            if (value == 'n') {
                return readLiteral("null");
            }
            return value == '-' || isDigit(value) ? readNumber() : false;
        }

        boolean readObject(int depth) {
            if (depth > MAX_DEPTH || !take('{')) {
                return false;
            }
            skipWhitespace();
            if (take('}')) {
                return true;
            }
            Set<String> names = new HashSet<String>();
            while (true) {
                skipWhitespace();
                String name = readStringValue();
                if (name == null || !names.add(name)) {
                    return false;
                }
                skipWhitespace();
                if (!take(':') || !readValue(depth + 1)) {
                    return false;
                }
                skipWhitespace();
                if (take('}')) {
                    return true;
                }
                if (!take(',')) {
                    return false;
                }
            }
        }

        boolean readArray(int depth) {
            if (depth > MAX_DEPTH || !take('[')) {
                return false;
            }
            skipWhitespace();
            if (take(']')) {
                return true;
            }
            while (true) {
                if (!readValue(depth + 1)) {
                    return false;
                }
                skipWhitespace();
                if (take(']')) {
                    return true;
                }
                if (!take(',')) {
                    return false;
                }
            }
        }

        String readStringValue() {
            if (!take('"')) {
                return null;
            }
            StringBuilder decoded = new StringBuilder();
            while (!atEnd()) {
                char value = input.charAt(index++);
                if (value == '"') {
                    return decoded.toString();
                }
                if (value < 0x20) {
                    return null;
                }
                if (value != '\\') {
                    if (Character.isHighSurrogate(value)) {
                        if (atEnd() || !Character.isLowSurrogate(input.charAt(index))) {
                            return null;
                        }
                        decoded.append(value).append(input.charAt(index++));
                    } else if (Character.isLowSurrogate(value)) {
                        return null;
                    } else {
                        decoded.append(value);
                    }
                    continue;
                }
                if (atEnd()) {
                    return null;
                }
                char escape = input.charAt(index++);
                if (escape == '"' || escape == '\\' || escape == '/') {
                    decoded.append(escape);
                    continue;
                }
                if (escape == 'b') {
                    decoded.append('\b');
                    continue;
                }
                if (escape == 'f') {
                    decoded.append('\f');
                    continue;
                }
                if (escape == 'n') {
                    decoded.append('\n');
                    continue;
                }
                if (escape == 'r') {
                    decoded.append('\r');
                    continue;
                }
                if (escape == 't') {
                    decoded.append('\t');
                    continue;
                }
                if (escape != 'u' || index + 4 > input.length()) {
                    return null;
                }
                int codeUnit = 0;
                for (int count = 0; count < 4; count++) {
                    char hex = input.charAt(index++);
                    if (!isHex(hex)) {
                        return null;
                    }
                    codeUnit = (codeUnit << 4) | hexValue(hex);
                }
                char decodedUnit = (char) codeUnit;
                if (Character.isHighSurrogate(decodedUnit)) {
                    if (index + 6 > input.length()
                            || input.charAt(index) != '\\'
                            || input.charAt(index + 1) != 'u') {
                        return null;
                    }
                    index += 2;
                    int lowCodeUnit = 0;
                    for (int count = 0; count < 4; count++) {
                        char hex = input.charAt(index++);
                        if (!isHex(hex)) {
                            return null;
                        }
                        lowCodeUnit = (lowCodeUnit << 4) | hexValue(hex);
                    }
                    char low = (char) lowCodeUnit;
                    if (!Character.isLowSurrogate(low)) {
                        return null;
                    }
                    decoded.append(decodedUnit).append(low);
                } else if (Character.isLowSurrogate(decodedUnit)) {
                    return null;
                } else {
                    decoded.append(decodedUnit);
                }
            }
            return null;
        }

        boolean readNumber() {
            take('-');
            if (take('0')) {
                if (!atEnd() && isDigit(input.charAt(index))) {
                    return false;
                }
            } else {
                if (atEnd() || !isOneToNine(input.charAt(index))) {
                    return false;
                }
                index++;
                while (!atEnd() && isDigit(input.charAt(index))) {
                    index++;
                }
            }
            if (take('.')) {
                if (atEnd() || !isDigit(input.charAt(index))) {
                    return false;
                }
                while (!atEnd() && isDigit(input.charAt(index))) {
                    index++;
                }
            }
            if (!atEnd() && (input.charAt(index) == 'e' || input.charAt(index) == 'E')) {
                index++;
                if (!atEnd() && (input.charAt(index) == '+' || input.charAt(index) == '-')) {
                    index++;
                }
                if (atEnd() || !isDigit(input.charAt(index))) {
                    return false;
                }
                while (!atEnd() && isDigit(input.charAt(index))) {
                    index++;
                }
            }
            return true;
        }

        boolean readLiteral(String expected) {
            if (!input.regionMatches(index, expected, 0, expected.length())) {
                return false;
            }
            index += expected.length();
            return true;
        }

        void skipWhitespace() {
            while (!atEnd()) {
                char value = input.charAt(index);
                if (value != ' ' && value != '\t' && value != '\r' && value != '\n') {
                    return;
                }
                index++;
            }
        }

        boolean peek(char expected) {
            return !atEnd() && input.charAt(index) == expected;
        }

        boolean take(char expected) {
            if (!peek(expected)) {
                return false;
            }
            index++;
            return true;
        }

        boolean atEnd() {
            return index == input.length();
        }
    }

    private static boolean isDigit(char value) {
        return value >= '0' && value <= '9';
    }

    private static boolean isOneToNine(char value) {
        return value >= '1' && value <= '9';
    }

    private static boolean isHex(char value) {
        return isDigit(value)
                || (value >= 'a' && value <= 'f')
                || (value >= 'A' && value <= 'F');
    }

    private static int hexValue(char value) {
        if (value >= '0' && value <= '9') {
            return value - '0';
        }
        if (value >= 'a' && value <= 'f') {
            return value - 'a' + 10;
        }
        return value - 'A' + 10;
    }
}
