package kr.kimrasng.proxima.mihomo;

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
    private long handle;

    public static native String version();

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
}
