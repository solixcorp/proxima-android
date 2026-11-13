package kr.kimrasng.proxima.mihomo;

/**
 * A real DNS packet diagnostic, not a full Mihomo executor or VPN.
 * Run one admitted attempt per disposable OS worker process. After close,
 * terminate/reap that process; native resolver global workers are not joined.
 * This API never accepts, edits, or applies a user's profile or selections.
 */
public final class NativeDiagnostics implements AutoCloseable {
    static { System.loadLibrary("proxima_mihomo_diagnostics"); }

    @FunctionalInterface
    public interface Protector {
        /** Only call VpnService.protect(fd); do not reenter this diagnostic. */
        boolean protect(int fd);
    }

    private final long token;

    private NativeDiagnostics(long token) { this.token = token; }

    /**
     * Borrows a stable, nonblocking raw-IP packet fd for this call.
     * A returned object proves local stack startup only. It is never connected
     * state. Only explicit "mips" and literal DNS IP:port endpoints are accepted.
     * Other traffic ends the diagnostic with a visible failure.
     */
    public static NativeDiagnostics startDns(
            int borrowedFd, Protector protector, String stack, int mtu,
            String destination, String upstream, String upstreamNetwork) {
        return new NativeDiagnostics(startNative(
                borrowedFd, protector, stack, mtu, destination, upstream, upstreamNetwork));
    }

    /**
     * Block off the UI thread until local packet/DNS drain, then throw the real
     * failure if any. Always call close afterwards to release the callback.
     */
    public void awaitLocalDrain() { awaitNative(token); }

    /**
     * Stop and join locally owned work, revoke sockets and release the callback.
     * Idempotent and safe concurrently with awaitLocalDrain. A terminal failure
     * is rethrown even though cleanup completed. The process must still exit.
     */
    @Override public void close() { stopNative(token); }

    private static native long startNative(
            int fd, Protector protector, String stack, int mtu,
            String destination, String upstream, String network);
    private static native void awaitNative(long token);
    private static native void stopNative(long token);
}
