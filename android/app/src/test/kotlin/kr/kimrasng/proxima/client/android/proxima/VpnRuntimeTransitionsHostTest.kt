package kr.kimrasng.proxima.client.android.proxima

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

object VpnRuntimeTransitionsHostTest {
    @JvmStatic fun main(args: Array<String>) {
        fun event(state: String, id: String, profile: String = "profile") =
            mapOf<String, Any?>("state" to state, "requestId" to id, "profileId" to profile)

        val connected = event("connected", "new")
        check(!currentVpnEvent(connected, event("disconnecting", "new")))
        check(!currentVpnEvent(connected, event("disconnected", "new", "")))
        check(!currentVpnEvent(connected, event("connected", "other")))
        check(!currentVpnEvent(connected, event("connected", "new", "other")))
        check(currentVpnEvent(connected, connected + ("uploadSpeed" to 42)))

        val gate = VpnGenerationGate()
        val oldStart = gate.incrementAndGet()
        val oldStop = gate.incrementAndGet()
        val newStart = gate.incrementAndGet()
        val published = mutableListOf<String>()
        check(!gate.ifCurrent(oldStart) { published.add("old connected") })
        check(!gate.ifCurrent(oldStop) { published.add("old disconnected") })
        check(gate.ifCurrent(newStart) { published.add("new connecting") })
        check(published == listOf("new connecting"))

        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val advanced = CountDownLatch(1)
        val publisher = thread {
            gate.ifCurrent(newStart) {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
        }
        check(entered.await(5, TimeUnit.SECONDS))
        val stopper = thread { gate.incrementAndGet(); advanced.countDown() }
        check(!advanced.await(100, TimeUnit.MILLISECONDS))
        release.countDown()
        publisher.join()
        stopper.join()
        check(advanced.count == 0L)
        check(!gate.ifCurrent(newStart) { error("retired generation published") })
        println("PASS VPN runtime generation and stale-event guards")
    }
}
