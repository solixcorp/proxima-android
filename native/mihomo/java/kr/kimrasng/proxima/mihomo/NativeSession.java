package kr.kimrasng.proxima.mihomo;

/**
 * An owned native descriptor and socket-protection lease, not a running VPN.
 *
 * <p>The future engine adapter must report TUN startup errors separately and
 * stop/join all engine workers and close their descriptors before preparing the
 * next session. No connected/running state is exposed by this class.
 */
public final class NativeSession implements AutoCloseable {
    static {
        System.loadLibrary("proxima_mihomo_session");
    }

    @FunctionalInterface
    public interface Protector {
        /**
         * Return the actual VpnService.protect(fd) result.
         * May run on native threads. Must not call session lifecycle methods.
         */
        boolean protect(int fd);
    }

    private final long token;

    private NativeSession(long token) {
        this.token = token;
    }

    /**
     * Borrows an open descriptor (including fd 0); native code duplicates it.
     * The caller keeps ownership and must prevent concurrent close/reuse during
     * this call. Only one lease may be prepared in a process.
     */
    public static NativeSession prepare(int borrowedTunFd, Protector protector) {
        return new NativeSession(prepareNative(borrowedTunFd, protector));
    }

    /**
     * Transfers a fresh duplicate to the caller. The caller must adopt/close it,
     * including on engine startup failure. Closing this lease does not close
     * duplicates already transferred to an engine.
     */
    public int duplicateTun() {
        return duplicateTunNative(token);
    }

    /** False for a refused callback, callback exception, or expired lease. */
    public boolean protectSocket(int fd) {
        return protectNative(token, fd);
    }

    /**
     * Denies new protection, drains callbacks, closes the bridge's duplicate,
     * and releases the callback on this attached Java thread. If release fails,
     * the lease stays inactive and reserves the session until close is retried
     * successfully. Idempotent after success; does not stop a Mihomo runtime.
     */
    @Override
    public void close() {
        closeNative(token);
    }

    private static native long prepareNative(int borrowedTunFd, Protector protector);
    private static native void closeNative(long token);
    private static native int duplicateTunNative(long token);
    private static native boolean protectNative(long token, int fd);
}
