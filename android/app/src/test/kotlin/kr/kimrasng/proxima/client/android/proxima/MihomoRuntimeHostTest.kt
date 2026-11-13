package kr.kimrasng.proxima.client.android.proxima

import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Production sidecar/consistency/dispatch/fence tests, not a Binder emulator. */
object MihomoRuntimeHostTest {
    private const val PROFILE = "12345678-1234-1234-1234-123456789abc"
    private const val SETTINGS = "1400:true:rule:mips"

    private fun sidecar(operation: (MihomoConfigSidecar, File) -> Unit) {
        val directory = Files.createTempDirectory("mihomo-sidecar-").toFile()
        try { operation(MihomoConfigSidecar(directory), directory) }
        finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    private fun upload(sidecar: MihomoConfigSidecar, bytes: ByteArray): String {
        val token = sidecar.begin(PROFILE, "source", SETTINGS, bytes.size)
        for (offset in bytes.indices step MihomoConfigSidecar.CHUNK_BYTES) {
            sidecar.append(token, offset, bytes.copyOfRange(offset, minOf(offset + MihomoConfigSidecar.CHUNK_BYTES, bytes.size)))
        }
        sidecar.finish(token)
        return token
    }

    private fun fails(text: String = "", operation: () -> Unit) {
        val failure = runCatching(operation).exceptionOrNull() ?: error("Expected failure")
        check(failure.message.orEmpty().contains(text)) { "Unexpected failure: $failure" }
    }

    @JvmStatic
    fun main(args: Array<String>) {
        var passed = 0
        fun test(name: String, operation: () -> Unit) {
            operation(); passed++; println("PASS $name")
        }
        test("exact dispatch selects one engine and never falls back on native failure") {
            val calls = mutableListOf<String>()
            check(dispatchVpnEngine("xray", { calls.add("xray"); 1 }, { error("wrong engine") }) == 1)
            check(dispatchVpnEngine("mihomo", { error("fallback") }, { calls.add("mihomo"); 2 }) == 2)
            fails("bind failed") { dispatchVpnEngine("mihomo", { error("fallback") }, { error("bind failed") }) }
            fails("Unsupported") { dispatchVpnEngine("unknown", { error("xray") }, { error("mihomo") }) }
            check(calls == listOf("xray", "mihomo"))
        }
        test("Dart MTU mips stack and IPv6 must match Android Builder") {
            for (mtu in listOf(1280, 1400, 1500, 9000)) for (ipv6 in listOf(true, false)) {
                MihomoProfileAssembler.verify(mtu, "mips", ipv6, mtu, ipv6)
            }
            fails("MTU") { MihomoProfileAssembler.verify(1500, "mips", true, 1400, true) }
            fails("MTU") { MihomoProfileAssembler.verify("1400", "mips", true, 1400, true) }
            fails("스택") { MihomoProfileAssembler.verify(1400, "mixed", true, 1400, true) }
            fails("IPv6") { MihomoProfileAssembler.verify(1400, "mips", false, 1400, true) }
        }
        test("missing ungenerated and incomplete sidecars fail closed") {
            sidecar { store, _ ->
                fails("사이드카") { store.consume(null, PROFILE, "source", SETTINGS) }
                val token = store.begin(PROFILE, "source", SETTINGS, 10)
                fails("완료") { store.finish(token) }
                fails("사이드카") { store.consume(token, PROFILE, "source", SETTINGS) }
            }
        }
        test("chunked sidecar exceeds Binder limit and preserves exact bytes for FD snapshot") {
            sidecar { store, directory ->
                val bytes = ByteArray(2 * 1024 * 1024 + 11) { (it % 251).toByte() }
                val token = upload(store, bytes)
                val consumed = store.consume(token, PROFILE, "source", SETTINGS)
                check(consumed.contentEquals(bytes))
                check(directory.listFiles().orEmpty().isEmpty())
                val config = MihomoConfiguration.copyOf(consumed)
                consumed.fill(0)
                val snapshot = File(directory, "snapshot")
                snapshot.outputStream().use(config::writeTo)
                check(snapshot.readBytes().contentEquals(bytes))
                check(config.sha256 == MihomoConfiguration.digest(bytes))
                fails("사이드카") { store.consume(token, PROFILE, "source", SETTINGS) }
            }
        }
        test("8 MiB accepted oversize empty reordered duplicated and oversized chunks rejected") {
            sidecar { store, _ ->
                for (size in listOf(0, MihomoConfiguration.MAX_BYTES + 1)) fails("8MB") { store.begin(PROFILE, "source", SETTINGS, size) }
                val token = store.begin(PROFILE, "source", SETTINGS, 10)
                fails("청크") { store.append(token, 1, byteArrayOf(1)) }
                fails("청크") { store.append(token, 0, ByteArray(11)) }
                fails("청크") { store.append(token, 0, ByteArray(MihomoConfigSidecar.CHUNK_BYTES + 1)) }
                store.append(token, 0, ByteArray(10))
                fails("청크") { store.append(token, 0, byteArrayOf(1)) }
                val large = ByteArray(MihomoConfiguration.MAX_BYTES) { 7 }
                check(store.consume(upload(store, large), PROFILE, "source", SETTINGS).contentEquals(large))
            }
        }
        test("source profile mode MTU and IPv6 changes invalidate and destroy ready snapshot") {
            sidecar { store, _ ->
                for ((profile, source, settings) in listOf(
                    Triple(PROFILE, "changed", SETTINGS), Triple("00000000-0000-0000-0000-000000000000", "source", SETTINGS),
                    Triple(PROFILE, "source", "1500:true:rule:mips"), Triple(PROFILE, "source", "1400:false:rule:mips"),
                    Triple(PROFILE, "source", "1400:true:global:mips"),
                )) {
                    val token = upload(store, byteArrayOf(1, 2, 3))
                    fails("오래") { store.consume(token, profile, source, settings) }
                    fails("사이드카") { store.requireReady(token) }
                }
            }
        }
        test("discard rejects stale capability and path traversal") {
            sidecar { store, _ ->
                val token = upload(store, byteArrayOf(1))
                store.discard(token)
                fails("사이드카") { store.consume(token, PROFILE, "source", SETTINGS) }
                fails("token") { store.discard("../outside") }
            }
        }
        test("normal stop joins Binder death before closing service original TUN") {
            val fence = MihomoRetirementFence()
            val requested = CountDownLatch(1)
            val events = Collections.synchronizedList(mutableListOf<String>())
            val stop = thread {
                closeMihomoTunnel({
                    events.add("stop-request")
                    requested.countDown()
                    fence.awaitRetired()
                    events.add("lease-released")
                }, { events.add("original-close") })
            }
            check(requested.await(5, TimeUnit.SECONDS))
            check(events.toList() == listOf("stop-request"))
            // Represents native stop -> close worker copies -> kernel death.
            events.add("native-stop-joined"); events.add("worker-copies-close")
            fence.observedDeath()
            stop.join(5000); check(!stop.isAlive)
            check(events.toList() == listOf("stop-request", "native-stop-joined", "worker-copies-close", "lease-released", "original-close"))
        }
        test("failed join cannot close original or certify process reuse") {
            var closed = false
            fails("not joined") { closeMihomoTunnel({ error("not joined") }, { closed = true }) }
            check(!closed)
            val gate = MihomoLeaseGate<String>()
            val old = gate.reserve("old"); check(gate.activate(old))
            gate.revoke(old)
            fails { gate.reserve("replacement") }
            check(gate.died(old))
            val next = gate.reserve("new"); check(gate.activate(next))
            check(!gate.died(old) && gate.isActive(next))
        }
        test("unexpected death is joinable without retry and fence observation is idempotent") {
            val fence = MihomoRetirementFence()
            fence.observedDeath(); fence.observedDeath()
            var closed = 0
            closeMihomoTunnel(fence::awaitRetired) { closed++ }
            check(closed == 1)
        }
        println("PASS $passed deterministic Mihomo runtime host tests")
    }

}
