import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import kr.kimrasng.proxima.mihomo.NativeEngine;

/** Separate JVM: a successful core permanently consumes its process. */
public final class NativeManagementTest {
    static { System.loadLibrary("proxima_mihomo_engine_fixture"); }
    private static native int[] openPair();
    private static native void sendPacket(int fd, byte[] packet);
    private static native byte[] receivePacket(int fd);
    private static native boolean unboundSocket(int fd);
    private static native void closeFD(int fd);

    private static void rejected(Runnable operation) {
        try { operation.run(); throw new AssertionError("inactive/invalid call succeeded"); }
        catch (IllegalStateException expected) { }
    }

    private static void inactive(NativeEngine engine) {
        rejected(() -> engine.trafficStats());
        rejected(() -> engine.connectionsSnapshot());
        rejected(() -> engine.delayTest("DIRECT", "https://127.0.0.1", 100));
    }

    private static InetAddress hostAddress() throws Exception {
        for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
            for (InetAddress ip : Collections.list(network.getInetAddresses())) {
                if (ip instanceof Inet4Address && !ip.isLoopbackAddress()) return ip;
            }
        }
        throw new AssertionError("host round trip requires non-loopback IPv4");
    }

    public static void main(String[] args) throws Exception {
        NativeEngine engine = new NativeEngine();
        inactive(engine);
        int[] pair = openPair();
        AtomicBoolean allow = new AtomicBoolean(true);
        AtomicInteger protects = new AtomicInteger();
        byte[] config = ("find-process-mode: off\nlog-level: silent\nprofile: {store-selected: false}\n" +
            "tun: {enable: true, stack: mips, mtu: 1500, auto-route: false, auto-detect-interface: false, dns-hijack: [], inet6-address: []}\n" +
            "rules: ['MATCH,DIRECT']\nproxies: [{name: '노드🚀', type: direct}]\n").getBytes(StandardCharsets.UTF_8);
        try {
            engine.start(config, pair[0], fd -> {
                if (!unboundSocket(fd)) throw new AssertionError("protect ran after bind/connect");
                protects.incrementAndGet();
                return allow.get();
            });
            long[] initial = engine.trafficStats();
            if (initial.length != 2 || initial[0] != 0 || initial[1] != 0) throw new AssertionError("initial totals");
            if (!new String(engine.connectionsSnapshot(), StandardCharsets.UTF_8).equals("[]")) throw new AssertionError("empty snapshot");
            InetAddress ip = hostAddress();
            try (DatagramSocket sink = new DatagramSocket(0, ip)) {
                sink.setSoTimeout(5000);
                byte[] packet = new byte[32];
                ByteBuffer raw = ByteBuffer.wrap(packet);
                packet[0] = 0x45; packet[8] = 64; packet[9] = 17;
                raw.putShort(2, (short)32);
                System.arraycopy(new byte[]{10, 0, 0, 2}, 0, packet, 12, 4);
                System.arraycopy(ip.getAddress(), 0, packet, 16, 4);
                int checksum = 0;
                for (int i = 0; i < 20; i += 2) checksum += Short.toUnsignedInt(raw.getShort(i));
                while ((checksum >>> 16) != 0) checksum = (checksum & 65535) + (checksum >>> 16);
                raw.putShort(10, (short)~checksum);
                raw.putShort(20, (short)34002); raw.putShort(22, (short)sink.getLocalPort()); raw.putShort(24, (short)12);
                System.arraycopy("ping".getBytes(StandardCharsets.UTF_8), 0, packet, 28, 4);
                sendPacket(pair[1], packet);
                DatagramPacket request = new DatagramPacket(new byte[128], 128);
                sink.receive(request);
                sink.send(new DatagramPacket("pong".getBytes(StandardCharsets.UTF_8), 4, request.getSocketAddress()));
                byte[] reply = receivePacket(pair[1]);
                if (!new String(reply, 28, reply.length - 28, StandardCharsets.UTF_8).equals("pong")) throw new AssertionError("actual reply");
                long[] stats = engine.trafficStats();
                if (stats[0] != 4 || stats[1] != 4) throw new AssertionError("payload totals");
                byte[] snapshot = engine.connectionsSnapshot();
                String json = new String(snapshot, StandardCharsets.UTF_8);
                if (!json.contains("\"network\":\"udp\"") || !json.contains("\"upload\":4") || !json.contains("\"download\":4")) throw new AssertionError(json);
                // JNI data is a Java-owned copy that survives later calls/Stop.
                engine.connectionsSnapshot();
                rejected(() -> engine.delayTest("DIRECT", "http://127.0.0.1", 100));
                rejected(() -> engine.delayTest("missing", "https://127.0.0.1", 100));
                allow.set(false);
                int before = protects.get();
                rejected(() -> engine.delayTest("노드🚀", "https://127.0.0.1:443", 1000));
                if (protects.get() <= before) throw new AssertionError("JNI probe did not invoke protector");
                engine.stop();
                inactive(engine);
                if (!json.equals(new String(snapshot, StandardCharsets.UTF_8))) throw new AssertionError("borrowed snapshot memory");
            }
        } finally {
            engine.stop();
            closeFD(pair[0]); closeFD(pair[1]);
        }
        System.out.println("NativeEngine management JNI: actual packet totals, snapshots, probe refusal and retired calls passed");
    }
}
