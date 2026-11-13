package kr.kimrasng.proxima.client.android.proxima

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Host suite discovered by test_mihomo_worker_boundary.py:
 *   python3 -m unittest discover -s android/app/src/test -v
 * Requires JDK 17/21 and kotlinc 2.2.20 or the cached Gradle compiler artifacts.
 * There are no JUnit/Gradle dependency changes or Android runtime stubs.
 *
 * To run manually, compile MihomoLeaseGate.kt, MihomoConfiguration.kt,
 * MihomoWorkerHandshake.kt and this file with
 * kotlinc -jvm-target 17 -d <classes>, then run:
 * kotlin -classpath <classes> \
 *   kr.kimrasng.proxima.client.android.proxima.MihomoBoundaryHostTest
 *
 * Android Binder marshalling, actual PFD duplication, process death, and
 * VpnService.protect still require Android integration tests. This suite
 * exercises the production admission/ownership code with counted resources.
 */
object MihomoBoundaryHostTest {
    private class Descriptor(
        private val failClose: Boolean = false,
        private val onClose: () -> Unit = {},
    ) : Closeable {
        val closes = AtomicInteger()
        override fun close() {
            check(closes.incrementAndGet() == 1) { "Descriptor closed twice" }
            onClose()
            if (failClose) error("Injected descriptor close failure")
        }
    }

    private fun expectFailure(operation: () -> Unit): Exception {
        try {
            operation()
        } catch (expected: Exception) {
            return expected
        }
        error("Expected failure")
    }

    private fun await(latch: CountDownLatch) {
        check(latch.await(5, TimeUnit.SECONDS)) { "Host test deadlocked" }
    }

    private fun join(worker: Thread) {
        worker.join(5_000)
        check(!worker.isAlive) { "Host test thread did not finish" }
    }

    /** Observe monitor contention, not elapsed time, before testing ordering. */
    private fun awaitBlocked(worker: Thread) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (worker.state != Thread.State.BLOCKED) {
            check(worker.isAlive && System.nanoTime() < deadline) { "Revocation did not wait for admission" }
            Thread.yield()
        }
    }

    @JvmStatic
    fun main(args: Array<String>) {
        var passed = 0
        fun test(name: String, operation: () -> Unit) {
            operation()
            passed++
            println("PASS $name")
        }

        test("reserved lease denies protection and closes receiver duplicate") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            val socket = Descriptor()
            check(!gate.protect(lease, lease.generation, "worker", socket, { true }) {
                error("Protection admitted before activation")
            })
            check(socket.closes.get() == 1)
        }

        test("actual protection boolean propagates and each duplicate closes") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            for (result in listOf(false, true)) {
                val socket = Descriptor()
                check(gate.protect(lease, lease.generation, "worker", socket, { true }) { result } == result)
                check(socket.closes.get() == 1)
            }
        }

        test("wrong generation and worker identity cannot call protector") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            for ((generation, identity) in listOf(
                lease.generation + 1 to "worker",
                lease.generation to "other",
                lease.generation to null,
            )) {
                val socket = Descriptor()
                check(!gate.protect(lease, generation, identity, socket, { true }) {
                    error("Stale identity reached protection")
                })
                check(socket.closes.get() == 1)
            }
        }

        test("dead peer denies protection without releasing occupied slot") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            val socket = Descriptor()
            check(!gate.protect(lease, lease.generation, "worker", socket, { false }) {
                error("Dead peer reached protection")
            })
            check(socket.closes.get() == 1)
            expectFailure { gate.reserve("replacement") }
        }

        test("protection exception closes duplicate and revokes lease") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            val socket = Descriptor()
            check(!gate.protect(lease, lease.generation, "worker", socket, { true }) {
                error("Injected protect error")
            })
            check(socket.closes.get() == 1 && !gate.isActive(lease))
            check(!gate.activate(lease))
            expectFailure { gate.reserve("replacement") }
        }

        test("peer check exception and duplicate close error both fail closed") {
            for (failPeer in listOf(true, false)) {
                val gate = MihomoLeaseGate<String>()
                val lease = gate.reserve("worker")
                check(gate.activate(lease))
                val socket = Descriptor(failClose = !failPeer)
                check(!gate.protect(lease, lease.generation, "worker", socket, {
                    if (failPeer) error("Injected peer check failure") else true
                }) { true })
                check(socket.closes.get() == 1 && !gate.isActive(lease))
                expectFailure { gate.reserve("replacement") }
            }
        }

        test("revocation is permanent and never authorizes replacement") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            gate.revoke(lease)
            gate.revoke(lease)
            check(!gate.activate(lease))
            val socket = Descriptor()
            check(!gate.protect(lease, lease.generation, "worker", socket, { true }) {
                error("Revoked lease reached protection")
            })
            check(socket.closes.get() == 1)
            expectFailure { gate.reserve("replacement") }
        }

        test("death during attachment cannot be followed by activation") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.died(lease))
            check(!gate.activate(lease))
            check(gate.reserve("replacement").generation > lease.generation)
        }

        test("death observation is registered before any lease is granted") {
            val gate = MihomoLeaseGate<String>()
            val deaths = mutableListOf<Long>()
            val watch = MihomoDeathWatch(gate, "worker", deaths::add)
            var observedDeath: (() -> Unit)? = null
            val lease = watch.reserveAfterRegistration {
                check(gate.isVacant())
                observedDeath = it
            }
            check(gate.activate(lease))
            checkNotNull(observedDeath).invoke()
            check(gate.isVacant() && deaths == listOf(lease.generation))
        }

        test("non-death registration error grants no lease and permits retry") {
            val gate = MihomoLeaseGate<String>()
            var lateUnregisteredDeath: (() -> Unit)? = null
            var grants = 0
            val watch = MihomoDeathWatch(gate, "unobserved") { error("No generation was granted") }
            expectFailure {
                watch.reserveAfterRegistration {
                    lateUnregisteredDeath = it
                    throw IOException("Injected linkToDeath failure while endpoint remains alive")
                }
                grants++
            }
            check(grants == 0 && gate.isVacant())
            val replacement = gate.reserve("observed")
            check(gate.activate(replacement))
            checkNotNull(lateUnregisteredDeath).invoke()
            check(gate.isActive(replacement))
        }

        test("death during registration cannot reserve or publish a generation") {
            val gate = MihomoLeaseGate<String>()
            val watch = MihomoDeathWatch(gate, "worker") { error("Unissued generation") }
            expectFailure { watch.reserveAfterRegistration { it() } }
            check(gate.isVacant())
        }

        test("error after registration retains slot until exact observed death") {
            val gate = MihomoLeaseGate<String>()
            val deaths = mutableListOf<Long>()
            val watch = MihomoDeathWatch(gate, "worker", deaths::add)
            var observedDeath: (() -> Unit)? = null
            val lease = watch.reserveAfterRegistration { observedDeath = it }
            gate.revoke(lease) // e.g. handshake RPC or retirement failed.
            check(!gate.isActive(lease))
            expectFailure { gate.reserve("replacement") }
            checkNotNull(observedDeath).invoke()
            val next = gate.reserve("replacement")
            check(gate.activate(next))
            checkNotNull(observedDeath).invoke()
            check(deaths == listOf(lease.generation) && gate.isActive(next))
        }

        test("handshake captures callback process identity exactly once") {
            val handshake = MihomoWorkerHandshake(7, "bound-service", 10001, 100)
            check(handshake.acknowledge(7, "bound-service", 10001, 200))
            check(!handshake.acknowledge(7, "bound-service", 10001, 300))
            check(handshake.finish() == 200)
            check(!handshake.acknowledge(7, "bound-service", 10001, 200))
            expectFailure { handshake.finish() }
        }

        test("handshake rejects stale generation wrong Binder UID and invalid process") {
            val attempts = listOf(
                Triple(8L, "bound-service", 10001 to 200),
                Triple(7L, "forwarded-binder", 10001 to 200),
                Triple(7L, "bound-service", 10002 to 200),
                Triple(7L, "bound-service", 10001 to 100),
                Triple(7L, "bound-service", 10001 to 0),
                Triple(7L, "bound-service", 10001 to -1),
            )
            for ((generation, identity, caller) in attempts) {
                val handshake = MihomoWorkerHandshake(7, "bound-service", 10001, 100)
                check(!handshake.acknowledge(generation, identity, caller.first, caller.second))
                expectFailure { handshake.finish() }
            }
        }

        test("missing or aborted handshake cannot admit a delayed callback") {
            val missing = MihomoWorkerHandshake(7, "worker", 10001, 100)
            expectFailure { missing.finish() }
            check(!missing.acknowledge(7, "worker", 10001, 200))
            val aborted = MihomoWorkerHandshake(7, "worker", 10001, 100)
            aborted.abort()
            check(!aborted.acknowledge(7, "worker", 10001, 200))
            expectFailure { aborted.finish() }
        }

        test("only exact death frees slot and late old events cannot affect replacement") {
            val gate = MihomoLeaseGate<String>()
            val old = gate.reserve("old")
            check(gate.activate(old))
            gate.revoke(old)
            expectFailure { gate.reserve("new") }
            check(gate.died(old))
            val current = gate.reserve("new")
            check(current.generation == old.generation + 1 && gate.activate(current))
            check(!gate.died(old))
            gate.revoke(old)
            check(gate.isActive(current))
            val socket = Descriptor()
            check(!gate.protect(old, current.generation, "new", socket, { true }) {
                error("Old callback borrowed the replacement lease")
            })
            check(socket.closes.get() == 1)
        }

        test("revocation waits for admitted callback before returning") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val revokeEntered = CountDownLatch(1)
            val revoked = CountDownLatch(1)
            val result = AtomicReference<Boolean>()
            val failure = AtomicReference<Throwable>()
            val socket = Descriptor()
            val callback = thread(isDaemon = true) {
                try {
                    result.set(gate.protect(lease, lease.generation, "worker", socket, { true }) {
                        entered.countDown()
                        await(release)
                        true
                    })
                } catch (error: Throwable) {
                    failure.set(error)
                }
            }
            await(entered)
            val revoker = thread(isDaemon = true) {
                revokeEntered.countDown()
                gate.revoke(lease)
                revoked.countDown()
            }
            try {
                await(revokeEntered)
                awaitBlocked(revoker)
                check(revoked.count == 1L)
                check(socket.closes.get() == 0)
            } finally {
                release.countDown()
                join(callback)
                join(revoker)
            }
            failure.get()?.let { throw it }
            check(result.get() == true && socket.closes.get() == 1)
            check(revoked.count == 0L && !gate.isActive(lease))
        }

        test("simultaneous attachments reserve exactly one worker") {
            val gate = MihomoLeaseGate<String>()
            val ready = CountDownLatch(2)
            val begin = CountDownLatch(1)
            val winners = AtomicInteger()
            val failures = AtomicInteger()
            val workers = (1..2).map { number ->
                thread(isDaemon = true) {
                    ready.countDown()
                    await(begin)
                    try {
                        gate.reserve("worker-$number")
                        winners.incrementAndGet()
                    } catch (_: IllegalStateException) {
                        failures.incrementAndGet()
                    }
                }
            }
            await(ready)
            begin.countDown()
            workers.forEach(::join)
            check(winners.get() == 1 && failures.get() == 1)
        }

        test("death waits for receiver duplicate closure before freeing slot") {
            val gate = MihomoLeaseGate<String>()
            val lease = gate.reserve("worker")
            check(gate.activate(lease))
            val closing = CountDownLatch(1)
            val release = CountDownLatch(1)
            val deathEntered = CountDownLatch(1)
            val died = CountDownLatch(1)
            val socket = Descriptor(onClose = {
                closing.countDown()
                await(release)
            })
            val callback = thread(isDaemon = true) {
                gate.protect(lease, lease.generation, "worker", socket, { true }) { true }
            }
            await(closing)
            val observer = thread(isDaemon = true) {
                deathEntered.countDown()
                gate.died(lease)
                died.countDown()
            }
            try {
                await(deathEntered)
                awaitBlocked(observer)
                check(died.count == 1L)
            } finally {
                release.countDown()
                join(callback)
                join(observer)
            }
            check(died.count == 0L && socket.closes.get() == 1)
            check(gate.reserve("replacement").generation > lease.generation)
        }

        test("descriptor pair closes both once and preserves both close errors") {
            val tun = Descriptor(failClose = true)
            val config = Descriptor(failClose = true)
            val owned = MihomoOwnedDescriptors(tun, config)
            val error = expectFailure { owned.close() }
            check(error.suppressed.size == 1)
            owned.close()
            check(tun.closes.get() == 1 && config.closes.get() == 1)
        }

        test("worker rejects replacement while retaining original owned resources") {
            val slot = MihomoWorkerSlot<Descriptor>()
            val first = Descriptor()
            val rejected = Descriptor()
            slot.install(first)
            expectFailure { slot.install(rejected) }
            check(first.closes.get() == 0 && rejected.closes.get() == 1)
            slot.close()
            slot.close()
            check(first.closes.get() == 1)
            val late = Descriptor()
            expectFailure { slot.install(late) }
            check(late.closes.get() == 1)
        }

        test("owner death before staging permanently closes worker admission") {
            val slot = MihomoWorkerSlot<Descriptor>()
            slot.close()
            val late = Descriptor()
            expectFailure { slot.install(late) }
            check(late.closes.get() == 1)
        }

        test("resource close failure cannot reopen worker slot or repeat close") {
            val slot = MihomoWorkerSlot<Descriptor>()
            val first = Descriptor(failClose = true)
            slot.install(first)
            expectFailure { slot.close() }
            slot.close()
            val late = Descriptor()
            expectFailure { slot.install(late) }
            check(first.closes.get() == 1 && late.closes.get() == 1)
        }

        test("configuration snapshot owns a copy and immutable digest") {
            val source = "abc".toByteArray()
            val original = source.copyOf()
            val snapshot = MihomoConfiguration.copyOf(source)
            source.fill(0)
            val written = ByteArrayOutputStream().also(snapshot::writeTo).toByteArray()
            check(written.contentEquals(original))
            // Published SHA-256 "abc" vector, independent of our digest code.
            check(snapshot.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            check(snapshot.size == original.size)
        }

        test("configuration digest matches fixed multi-block SHA-256 vectors") {
            val message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            check(MihomoConfiguration.copyOf(message.toByteArray()).sha256 ==
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
            check(MihomoConfiguration.copyOf(ByteArray(1_000_000) { 'a'.code.toByte() }).sha256 ==
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        }

        test("configuration accepts eight MiB and rejects empty or oversized inputs") {
            check(MihomoConfiguration.copyOf(ByteArray(MihomoConfiguration.MAX_BYTES)).size == 8 * 1024 * 1024)
            expectFailure { MihomoConfiguration.copyOf(byteArrayOf()) }
            expectFailure { MihomoConfiguration.copyOf(ByteArray(MihomoConfiguration.MAX_BYTES + 1)) }
        }

        println("PASS $passed deterministic Mihomo boundary host tests")
    }
}
