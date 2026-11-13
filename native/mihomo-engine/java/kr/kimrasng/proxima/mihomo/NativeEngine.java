package kr.kimrasng.proxima.mihomo;

import java.nio.charset.StandardCharsets;

/**
 * Standalone one-process/one-core adapter. Never load with the separate session
 * or diagnostic shared library: independent Go runtimes cannot share leases.
 * This class does not publish Android connected state or modify the application.
 */
public final class NativeEngine implements AutoCloseable {
    static { System.loadLibrary("proxima_mihomo_engine"); }

    @FunctionalInterface
    /** Actual VpnService.protect only; must not reenter lifecycle methods. */
    public interface Protector { boolean protect(int fd); }

    // Native start stores a cleanup handle even on an exceptional return when
    // callback release needs retry. Keep this object and call stop again.
    private volatile long handle;

    public static native String version();

    /** Session payload bytes: [upload, download]. Throws if not running. */
    public long[] trafficStats() { return trafficStatsNative(handle); }

    /** HTTPS HEAD through the named proxy/group; concurrent calls are allowed.
     * Stop cancels and joins admitted probes. timeoutMs must be 1..60000.
     * Native failures throw IllegalStateException; successful delay is >= 1 ms.
     */
    public int delayTest(String name, String url, int timeoutMs) {
        if (name == null || url == null || name.indexOf('\0') >= 0 || url.indexOf('\0') >= 0) {
            throw new IllegalArgumentException("proxy name and HTTPS URL are required, without NUL");
        }
        if (name.length() > 8192 || url.length() > 8192) {
            throw new IllegalArgumentException("probe name/URL exceeds length limit");
        }
        return delayTestNative(handle, name.getBytes(StandardCharsets.UTF_8), url.getBytes(StandardCharsets.UTF_8), timeoutMs);
    }

    /** Owned UTF-8 JSON array (max 8 MiB/10000 rows); no native buffer lifetime. */
    public byte[] connectionsSnapshot() { return connectionsSnapshotNative(handle); }

    /** Change a selector member in the running session. */
    public void select(String group, String proxy) {
        if (group == null || proxy == null || group.indexOf('\0') >= 0 || proxy.indexOf('\0') >= 0 ||
                group.length() > 8192 || proxy.length() > 8192) {
            throw new IllegalArgumentException("selector names are required, without NUL, at most 8192 bytes");
        }
        selectNative(handle, group.getBytes(StandardCharsets.UTF_8), proxy.getBytes(StandardCharsets.UTF_8));
    }

    /** Borrow fd during the call; it must be nonblocking and carry raw IP. */
    public synchronized void start(byte[] config, int borrowedTunFd, Protector protector) {
        if (handle != 0) throw new IllegalStateException("stop the existing engine first");
        startNative(config, borrowedTunFd, protector, null);
    }

    /** Existing, trusted app-private directory; never take this from a profile. */
    public synchronized void start(byte[] config, int borrowedTunFd, Protector protector, String providerRoot) {
        if (handle != 0) throw new IllegalStateException("stop the existing engine first");
        startNative(config, borrowedTunFd, protector, providerRoot);
    }

    /** Drains local packets then releases protection. The worker must still exit. */
    public synchronized void stop() { stopNative(); }
    @Override public void close() { stop(); }

    private native void startNative(byte[] config, int borrowedTunFd, Protector protector, String providerRoot);
    private native void stopNative();
    private static native long[] trafficStatsNative(long handle);
    private static native int delayTestNative(long handle, byte[] name, byte[] url, int timeoutMs);
    private static native byte[] connectionsSnapshotNative(long handle);
    private static native void selectNative(long handle, byte[] group, byte[] proxy);
}
