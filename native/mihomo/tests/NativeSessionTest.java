import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.lang.reflect.Field;
import java.util.concurrent.atomic.AtomicInteger;
import kr.kimrasng.proxima.mihomo.NativeSession;

/** Exercises the compiled JNI implementation in a real JVM, without Android. */
public final class NativeSessionTest {
    private static void check(boolean result, String message) {
        if (!result) {
            throw new AssertionError(message);
        }
    }

    private static int descriptor(FileInputStream stream) throws Exception {
        Field fd = FileDescriptor.class.getDeclaredField("fd");
        fd.setAccessible(true);
        return fd.getInt(stream.getFD());
    }

    private static FileInputStream adopt(int descriptor) throws Exception {
        FileDescriptor fd = new FileDescriptor();
        Field field = FileDescriptor.class.getDeclaredField("fd");
        field.setAccessible(true);
        field.setInt(fd, descriptor);
        return new FileInputStream(fd);
    }

    public static void main(String[] args) throws Exception {
        try (FileInputStream original = new FileInputStream("/dev/null")) {
            int borrowed = descriptor(original);
            try {
                NativeSession.prepare(-1, fd -> true);
                throw new AssertionError("invalid descriptor accepted");
            } catch (IllegalStateException expected) {
                // A failed prepare must not reserve the process-wide lease.
            }

            AtomicInteger received = new AtomicInteger(-1);
            NativeSession first = NativeSession.prepare(borrowed, fd -> {
                received.set(fd);
                return fd == borrowed;
            });
            check(first.protectSocket(borrowed), "true callback result lost");
            check(received.get() == borrowed, "callback descriptor changed");
            check(!first.protectSocket(borrowed + 1000), "false callback result ignored");
            try {
                NativeSession.prepare(borrowed, fd -> true);
                throw new AssertionError("second concurrent lease accepted");
            } catch (IllegalStateException expected) {
                // The first callback must remain live after the rejected lease.
            }
            check(first.protectSocket(borrowed), "rejected prepare damaged first lease");
            try (FileInputStream transferred = adopt(first.duplicateTun())) {
                first.close();
                check(transferred.read() == -1, "close consumed transferred descriptor");
                check(original.read() == -1, "close consumed borrowed descriptor");
            }
            check(!first.protectSocket(borrowed), "expired lease protected a socket");
            try {
                first.duplicateTun();
                throw new AssertionError("expired lease duplicated its descriptor");
            } catch (IllegalStateException expected) {
                // No duplicate may outlive its lease unless transferred earlier.
            }

            try (NativeSession second = NativeSession.prepare(borrowed, fd -> true)) {
                first.close();
                check(second.protectSocket(borrowed), "stale close stopped replacement");
                check(!first.protectSocket(borrowed), "stale token used replacement");
            }
            try (NativeSession throwing = NativeSession.prepare(borrowed, fd -> {
                throw new IllegalStateException("callback failure");
            })) {
                check(!throwing.protectSocket(borrowed), "callback exception failed open");
                check(!throwing.protectSocket(borrowed), "pending exception escaped JNI");
            }
        }
        System.out.println("JNI session ownership, refusal, exception, and stale-token tests passed");
    }
}
