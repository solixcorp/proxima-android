package kr.kimrasng.proxima.client.android.proxima

/**
 * Historical name, now ONLY a Builder/config consistency check. Dart owns all
 * link/subscription/rule assembly. Never reconstruct or repair its document here.
 * Android owns TUN addresses/routes; the engine always uses the mips stack,
 * independently of the Xray-only system/gvisor/mixed preference.
 */
object MihomoProfileAssembler {
    fun verify(tunMtu: Any?, tunStack: Any?, configIpv6: Any?, builderMtu: Int, builderIpv6: Boolean) {
        require(tunMtu is Int && tunMtu == builderMtu && builderMtu in setOf(1280, 1400, 1500, 9000)) {
            "Mihomo 설정 MTU와 Android 빌더 MTU가 다릅니다. 다시 연결해 주세요."
        }
        require(tunStack == "mips") { "Mihomo 설정 스택은 Android 실행 계약(mips)과 일치해야 합니다." }
        require(configIpv6 is Boolean && configIpv6 == builderIpv6) {
            "Mihomo 설정 IPv6와 Android 빌더 설정이 다릅니다. 다시 연결해 주세요."
        }
    }
}

/** Exact engine dispatch: no implicit fallback after a Mihomo failure. */
internal fun <T> dispatchVpnEngine(engine: String, xray: () -> T, mihomo: () -> T): T = when (engine) {
    "xray" -> xray()
    "mihomo" -> mihomo()
    else -> error("Unsupported VPN engine: $engine")
}
