import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import kr.kimrasng.proxima.mihomo.NativeEngine;

public final class NativeEngineTest {
    private static final byte[] CONFIG = ("find-process-mode: off\n" +
        "profile: {store-selected: false}\n" +
        "tun: {enable: true, stack: mips, mtu: 1500, auto-route: false, auto-detect-interface: false, dns-hijack: [], inet6-address: []}\n" +
        "rules: ['MATCH,REJECT']\n").getBytes(StandardCharsets.UTF_8);

    private static void rejected(NativeEngine engine, byte[] config, int fd) {
        try {
            engine.start(config, fd, socket -> true);
            throw new AssertionError("startup unexpectedly succeeded");
        } catch (IllegalStateException expected) { }
        engine.stop();
    }

    private static int descriptors() {
        String[] entries = new File("/dev/fd").list();
        if (entries == null) throw new AssertionError("cannot enumerate fds");
        return entries.length;
    }

    public static void main(String[] args) throws Exception {
        if (!NativeEngine.version().contains("v1.19.33")) throw new AssertionError("wrong version");
        NativeEngine engine = new NativeEngine();
        rejected(engine, CONFIG, -1);
        try (FileInputStream file = new FileInputStream("/dev/null")) {
            Field field = FileDescriptor.class.getDeclaredField("fd");
            field.setAccessible(true);
            int fd = field.getInt(file.getFD());
            rejected(engine, "broken: [".getBytes(StandardCharsets.UTF_8), fd);
            int before = descriptors();
            for (int i = 0; i < 100; i++) rejected(engine, "broken: [".getBytes(StandardCharsets.UTF_8), fd);
            if (descriptors() != before) throw new AssertionError("JNI rollback leaked descriptors");
            // Parse/application uses the real core, then rejects a blocking device.
            rejected(engine, CONFIG, fd);
            rejected(engine, CONFIG, fd); // consumed core process cannot restart
            file.read(); // caller-owned original is still open
        }
        engine.stop();
        System.out.println("NativeEngine version, failed startup, ownership and FD leak tests passed");
    }
}
