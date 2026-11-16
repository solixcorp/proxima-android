import unittest

from verify_release_apk import signer_sha256


class ReleaseCertificateTest(unittest.TestCase):
    def test_build_tools_36_report(self):
        digest = "ab" * 32
        self.assertEqual(signer_sha256(
            f"Signer #1 certificate DN: CN=release\n"
            f"Signer #1 certificate SHA-256 digest: {digest}\n"
        ), digest)

    def test_build_tools_37_scheme_reports(self):
        digest = "AB" * 32
        self.assertEqual(signer_sha256(
            f"V2 Signer: certificate SHA-256 digest: {digest}\n"
            f"V3.1 Signer: certificate SHA-256 digest: {digest}\n"
        ), digest.lower())

    def test_rejects_empty_malformed_and_unsupported_reports(self):
        for report in (
            "Verifies",
            "Signer #1 certificate SHA-256 digest: bad",
            "Unknown Signer: certificate SHA-256 digest: " + "ab" * 32,
        ):
            with self.subTest(report=report), self.assertRaises(ValueError):
                signer_sha256(report)

    def test_rejects_multiple_signers_and_inconsistent_schemes(self):
        for report in (
            "Signer #2 certificate SHA-256 digest: " + "ab" * 32,
            "V2 Signer: certificate SHA-256 digest: " + "ab" * 32 + "\n"
            "V3 Signer: certificate SHA-256 digest: " + "cd" * 32,
        ):
            with self.subTest(report=report), self.assertRaises(ValueError):
                signer_sha256(report)


if __name__ == "__main__":
    unittest.main()
