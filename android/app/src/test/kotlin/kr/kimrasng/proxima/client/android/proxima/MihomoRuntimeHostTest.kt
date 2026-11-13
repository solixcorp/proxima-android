package kr.kimrasng.proxima.client.android.proxima

import java.util.Base64
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Production pure projection/dispatch/fence tests, not an Android Binder emulator. */
object MihomoRuntimeHostTest {
    private const val UUID = "12345678-1234-1234-1234-123456789abc"
    private fun stored(query: String, name: String = "node"): String =
        "# proxima-vless-reality-link: " + Base64.getUrlEncoder().withoutPadding()
            .encodeToString("vless://$UUID@example.com:443?$query#$name".toByteArray())

    private fun build(query: String, mode: String = "rule", ipv6: Boolean = true) =
        MihomoProfileAssembler.build("node", stored(query), 1400, ipv6, mode)

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
        test("tcp REALITY maps only admitted native options") {
            val result = build("type=tcp&security=reality&pbk=${"A".repeat(43)}&sid=abcd&sni=cover.example&fp=chrome&flow=xtls-rprx-vision&alpn=h2,http%2F1.1&encryption=none")
            check(result.proxy["network"] == "tcp" && result.proxy["tls"] == true)
            check(result.proxy["flow"] == "xtls-rprx-vision")
            check(result.proxy["servername"] == "cover.example")
            check(result.proxy["alpn"] == listOf("h2", "http/1.1"))
            check((result.proxy["reality-opts"] as Map<*, *>)["short-id"] == "abcd")
            fixture("tcp-reality", result)
        }
        test("grpc TLS maps service name and honors explicit SNI") {
            val result = build("type=grpc&security=tls&serviceName=my%2Fservice&sni=grpc.example")
            check(result.proxy["grpc-opts"] == mapOf("grpc-service-name" to "my/service"))
            check(result.proxy["servername"] == "grpc.example")
            fixture("grpc", result)
        }
        test("ws preserves path Host and YAML injection characters") {
            val result = build("type=ws&security=tls&path=%2Fws%3Fa%3D1&host=cdn.example")
            val opts = result.proxy["ws-opts"] as Map<*, *>
            check(opts["path"] == "/ws?a=1" && opts["headers"] == mapOf("Host" to "cdn.example"))
            val escaped = MihomoProfileAssembler.build("quote\"\n#rule: evil", stored("type=ws"), 1500, false, "global")
            check(escaped.yaml.contains("quote\\\"\\u000a#rule: evil"))
            fixture("ws", result)
        }
        test("HTTPUpgrade uses admitted WS upgrade flag not an invented network") {
            val result = build("type=httpupgrade&security=tls&path=%2Fupgrade&host=cdn.example")
            check(result.proxy["network"] == "ws")
            check((result.proxy["ws-opts"] as Map<*, *>)["v2ray-http-upgrade"] == true)
            fixture("httpupgrade", result)
        }
        test("XHTTP splitHTTP REALITY-WS and unsupported options fail closed") {
            for (type in listOf("xhttp", "splithttp")) fails("XHTTP") { build("type=$type") }
            fails("REALITY over WS") { build("type=ws&security=reality") }
            fails("insecure TLS") { build("type=tcp&security=tls&allowInsecure=1") }
            fails("unsupported/duplicate") { build("type=tcp&downloadSettings=unsafe") }
            fails("unsupported/duplicate") { build("type=tcp&type=grpc") }
            fails("encryption") { build("type=tcp&encryption=custom") }
            fails("public key") { build("type=tcp&security=reality&pbk=bad") }
        }
        test("app modes use explicit MATCH and omit DNS providers and desktop addressing") {
            for (mode in listOf("global", "direct", "rule")) {
                val result = build("type=tcp&security=none", mode, false)
                check(result.yaml.contains(if (mode == "direct") "MATCH,DIRECT" else "MATCH,PROXY"))
                check(result.yaml.contains("\"ipv6\":false") && result.yaml.contains("\"stack\":\"mips\""))
                check(result.yaml.contains("172.19.0.2:53") && result.yaml.contains("\"mtu\":1400"))
                check(!result.yaml.contains("\"dns\":") && !result.yaml.contains("\"inet4-address\""))
                check(!result.yaml.contains("\"rule-providers\""))
            }
        }
        test("one selected subscription node is projected without corrupting stored metadata") {
            val content = stored("type=tcp", "one") + "\n" + stored("type=grpc", "two") +
                "\n# proxima-routing-rules: deliberately-not-translated"
            val result = MihomoProfileAssembler.build("subscription", content, 1280, true, "rule", mapOf("PROXY" to "two"))
            check(result.node == "two" && result.proxy["network"] == "grpc")
            check(!result.yaml.contains("deliberately-not-translated"))
            fails("reserved") { MihomoProfileAssembler.build("DIRECT", stored("type=tcp"), 1400, true, "global") }
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

    private fun fixture(name: String, result: MihomoProfileAssembler.Result) {
        println("CONFIG $name " + Base64.getEncoder().encodeToString(result.yaml.toByteArray()))
    }
}
