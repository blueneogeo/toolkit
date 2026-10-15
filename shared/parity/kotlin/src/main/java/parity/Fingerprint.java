package parity;

import java.nio.charset.StandardCharsets;

final class Fingerprint {
    private Fingerprint() {}

    static String of(String text) {
        long hash = 0xcbf29ce484222325L;
        for (byte b : text.getBytes(StandardCharsets.UTF_8)) {
            hash ^= b & 0xff;
            hash *= 0x100000001b3L;
        }
        return Long.toUnsignedString(hash, 16);
    }
}
