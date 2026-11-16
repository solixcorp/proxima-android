package kr.kimrasng.proxima.client.android.proxima

import java.util.Base64

object ExternalConnectHostTest {
    @JvmStatic fun main(args: Array<String>) {
        val pending = PendingExternalConnect()
        check(!pending.consume())
        pending.request()
        pending.request()
        check(pending.isPending() && pending.consume() && !pending.consume())
        val token = ExternalConnectCapability.issue()
        check(!ExternalConnectCapability.consume("forged"))
        check(ExternalConnectCapability.consume(token))
        check(!ExternalConnectCapability.consume(token))

        val url = "https://subscription.example/path"
        val marker = Base64.getUrlEncoder().withoutPadding().encodeToString(url.toByteArray())
        check(ProfileRepository.legacySubscriptionUrl("# proxima-subscription-url: $marker\n") == url)
        check(ProfileRepository.legacySubscriptionUrl("proxy-providers:\n  foo:\n    url: https://example.org/provider\n") == null)
        check(ProfileRepository.legacySubscriptionUrl("# proxima-subscription-url: !!!\nurl: https://example.org") == null)
        val insecure = Base64.getUrlEncoder().withoutPadding().encodeToString("http://example.org".toByteArray())
        check(ProfileRepository.legacySubscriptionUrl("# proxima-subscription-url: $insecure") == null)
        println("PASS external connect and legacy subscription marker")
    }
}
