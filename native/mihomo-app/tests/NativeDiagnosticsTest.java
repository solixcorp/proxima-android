import kr.kimrasng.proxima.mihomo.NativeDiagnostics;
import java.net.*;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Host JVM + actual c-shared core; all network destinations are loopback. */
public final class NativeDiagnosticsTest {
    static { System.loadLibrary("diagnostic_packet_fixture"); }
    private static native int[] openPair();
    private static native void sendPacket(int fd, byte[] packet);
    private static native byte[] receivePacket(int fd);
    private static native boolean unboundSocket(int fd);
    private static native void closeFD(int fd);

    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static void expectFailure(Runnable operation, String part) {
        try { operation.run(); throw new AssertionError("unexpected success"); }
        catch (IllegalStateException e) { require(e.getMessage().contains(part), e.toString()); }
    }

    public static void main(String[] args) throws Exception {
        String scenario = args[0];
        int[] pair = openPair();
        AtomicInteger protections = new AtomicInteger();
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try (DatagramSocket upstream = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0))) {
            upstream.setSoTimeout(5000);
            String endpoint = "127.0.0.1:" + upstream.getLocalPort();
            NativeDiagnostics.Protector protector = fd -> {
                protections.incrementAndGet();
                if (!unboundSocket(fd)) throw new AssertionError("protection after bind");
                if (scenario.equals("exception")) throw new IllegalStateException("refuse callback");
                return !scenario.equals("refused");
            };
            for (String stack : new String[] {"system", "gvisor", "mixed"}) {
                expectFailure(() -> NativeDiagnostics.startDns(
                        pair[0], protector, stack, 1500, "172.19.0.2:53", endpoint, "udp"), "requires explicit mips");
            }
            if (scenario.equals("start-error")) {
                expectFailure(() -> NativeDiagnostics.startDns(
                        pair[0], protector, "mips", 1, "172.19.0.2:53", endpoint, "udp"), "start mips stack");
                expectFailure(() -> NativeDiagnostics.startDns(
                        pair[0], protector, "mips", 1500, "172.19.0.2:53", endpoint, "udp"), "process already used");
                require(protections.get() == 0, "startup attempted DNS");
                System.out.println("JNI actual startup rollback PASS");
                return;
            }
            NativeDiagnostics diagnostic = NativeDiagnostics.startDns(
                    pair[0], protector, "mips", 1500, "172.19.0.2:53", endpoint, "udp");
            Future<?> drained = workers.submit(diagnostic::awaitLocalDrain);
            Future<?> answered = null;
            if (scenario.equals("udp")) {
                answered = workers.submit(() -> {
                    try {
                        DatagramPacket request = new DatagramPacket(new byte[1500], 1500);
                        upstream.receive(request);
                        byte[] reply = Arrays.copyOf(request.getData(), request.getLength()+16);
                        reply[2] = (byte)0x81; reply[3] = (byte)0x80;
                        reply[6] = 0; reply[7] = 1;
                        byte[] answer = {(byte)0xc0,12,0,1,0,1,0,0,0,60,0,4,(byte)192,0,2,27};
                        System.arraycopy(answer, 0, reply, request.getLength(), answer.length);
                        upstream.send(new DatagramPacket(reply, reply.length, request.getSocketAddress()));
                    } catch (Exception e) { throw new RuntimeException(e); }
                });
            }
            sendPacket(pair[1], packet());
            if (scenario.equals("udp")) {
                byte[] reply = receivePacket(pair[1]);
                require(reply.length > 40 && reply[9] == 17, "not a raw UDP reply");
                require((reply[12]&255)==172 && reply[13]==19 && reply[14]==0 && reply[15]==2, "wrong reply source");
                require(reply[28]==0x34 && reply[29]==0x12, "wrong DNS id");
                require((reply[reply.length-4]&255)==192 && reply[reply.length-1]==27, "wrong native DNS answer");
                answered.get(5, TimeUnit.SECONDS);
                diagnostic.close();
                drained.get(5, TimeUnit.SECONDS);
                diagnostic.close();
            } else {
                try { drained.get(5, TimeUnit.SECONDS); throw new AssertionError("refusal was not reported"); }
                catch (ExecutionException e) { require(e.getCause().getMessage().contains("protection refused"), e.toString()); }
                expectFailure(diagnostic::close, "protection refused");
                expectFailure(diagnostic::close, "protection refused");
                // A refused socket never reaches the local DNS listener.
                upstream.setSoTimeout(50);
                try {
                    upstream.receive(new DatagramPacket(new byte[1500], 1500));
                    throw new AssertionError("refused socket sent DNS");
                } catch (SocketTimeoutException expected) {}
            }
            require(protections.get() > 0, "JNI protector was not called");
            expectFailure(() -> NativeDiagnostics.startDns(
                    pair[0], protector, "mips", 1500, "172.19.0.2:53", endpoint, "udp"), "process already used");
            System.out.println("JNI integrated " + scenario + " PASS");
        } finally {
            workers.shutdownNow();
            require(workers.awaitTermination(5, TimeUnit.SECONDS), "JVM test worker did not stop");
            closeFD(pair[0]); closeFD(pair[1]);
        }
    }

    private static byte[] packet() {
        byte[] query = {
            0x34,0x12,1,0,0,1,0,0,0,0,0,0,
            3,'j','n','i',7,'e','x','a','m','p','l','e',0,0,1,0,1
        };
        ByteBuffer b = ByteBuffer.allocate(28+query.length);
        b.put(0,(byte)0x45); b.putShort(2,(short)b.capacity());
        b.put(8,(byte)64); b.put(9,(byte)17);
        b.putInt(12,0x0a000002); b.putInt(16,0xac130002);
        int sum = 0;
        for (int i=0;i<20;i+=2) sum += Short.toUnsignedInt(b.getShort(i));
        while ((sum>>>16)!=0) sum=(sum&65535)+(sum>>>16);
        b.putShort(10,(short)~sum);
        b.putShort(20,(short)34001); b.putShort(22,(short)53);
        b.putShort(24,(short)(query.length+8));
        b.position(28); b.put(query);
        return b.array();
    }
}
