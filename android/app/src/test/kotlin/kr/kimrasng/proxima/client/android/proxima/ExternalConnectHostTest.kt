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
        val httpUrl = "http://192.0.2.1:8080/subscription.yaml"
        val httpMarker = Base64.getUrlEncoder().withoutPadding().encodeToString(httpUrl.toByteArray())
        check(ProfileRepository.legacySubscriptionUrl("# proxima-subscription-url: $httpMarker") == httpUrl)
        for (invalid in listOf("ftp://example.org/file", "http:///missing-host", "http://user:pass@example.org/sub")) {
            val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(invalid.toByteArray())
            check(ProfileRepository.legacySubscriptionUrl("# proxima-subscription-url: $encoded") == null)
        }
        check(ProfileRepository.legacySubscriptionUrl("proxy-providers:\n  foo:\n    url: $httpUrl\n") == null)
        println("PASS external connect and legacy subscription marker")
    }
}
