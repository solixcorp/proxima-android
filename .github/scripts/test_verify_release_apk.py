import unittest
import xml.etree.ElementTree as ET

from verify_release_apk import signer_sha256, validate_native_classes


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


BRIDGE_XML = """<api><package name="kr.kimrasng.proxima.mihomo">
<class name="NativeEngine" interface="false" abstract="false">
  <field name="handle" type="long" static="false" volatile="true"/>
  <method name="version" return="java.lang.String" static="true" native="true"/>
  <method name="startNative" return="void" static="false" native="true">
    <parameter type="byte[]"/><parameter type="int"/>
    <parameter type="kr.kimrasng.proxima.mihomo.NativeEngine$Protector"/>
    <parameter type="java.lang.String"/>
  </method>
  <method name="stopNative" return="void" static="false" native="true"/>
  <method name="trafficStatsNative" return="long[]" static="true" native="true">
    <parameter type="long"/>
  </method>
  <method name="delayTestNative" return="int" static="true" native="true">
    <parameter type="long"/><parameter type="byte[]"/>
    <parameter type="byte[]"/><parameter type="int"/>
  </method>
  <method name="connectionsSnapshotNative" return="byte[]" static="true" native="true">
    <parameter type="long"/>
  </method>
  <method name="selectNative" return="void" static="true" native="true">
    <parameter type="long"/><parameter type="byte[]"/><parameter type="byte[]"/>
  </method>
</class>
<class name="NativeEngine$Protector" interface="true" abstract="true">
  <method name="protect" return="boolean" static="false" visibility="public">
    <parameter type="int"/>
  </method>
</class>
</package><package name="fixture">
<class name="Callback" interface="false" abstract="false" extends="java.lang.Object">
  <implements name="kr.kimrasng.proxima.mihomo.NativeEngine$Protector"/>
  <method name="protect" return="boolean" static="false" visibility="public">
    <parameter type="int"/>
  </method>
</class>
</package></api>"""


class NativeBridgeTest(unittest.TestCase):
    def test_accepts_preserved_contract_across_dex_files(self):
        root = ET.fromstring(BRIDGE_XML)
        callback_package = root.findall("package")[1]
        root.remove(callback_package)
        other = ET.Element("api")
        other.append(callback_package)
        validate_native_classes([ET.tostring(root), ET.tostring(other)])

    def test_rejects_shrunk_renamed_or_changed_handle(self):
        for attribute, value in (("name", "a"), ("type", "int"),
                                 ("static", "true"), ("volatile", "false")):
            with self.subTest(attribute=attribute):
                root = ET.fromstring(BRIDGE_XML)
                root.find("package/class/field").set(attribute, value)
                with self.assertRaisesRegex(ValueError, "NativeEngine.handle"):
                    validate_native_classes([ET.tostring(root)])
        root = ET.fromstring(BRIDGE_XML)
        engine = root.find("package/class")
        engine.remove(engine.find("field"))
        with self.assertRaisesRegex(ValueError, "NativeEngine.handle"):
            validate_native_classes([ET.tostring(root)])

    def test_rejects_native_method_signature_changes(self):
        for attribute, value in (("name", "a"), ("native", "false"),
                                 ("static", "false"), ("return", "void")):
            with self.subTest(attribute=attribute):
                root = ET.fromstring(BRIDGE_XML)
                root.find("package/class/method").set(attribute, value)
                with self.assertRaisesRegex(ValueError, "JNI method"):
                    validate_native_classes([ET.tostring(root)])

    def test_rejects_erased_interface_and_callback_methods(self):
        for class_name in ("NativeEngine$Protector", "Callback"):
            with self.subTest(class_name=class_name):
                root = ET.fromstring(BRIDGE_XML)
                cls = next(c for c in root.iter("class") if c.get("name") == class_name)
                cls.remove(cls.find("method"))
                with self.assertRaisesRegex(ValueError, r"protect\(int\)"):
                    validate_native_classes([ET.tostring(root)])

    def test_rejects_missing_and_duplicate_classes(self):
        for reports in (["<api/>"], [BRIDGE_XML, BRIDGE_XML], ["bad XML"]):
            with self.subTest(reports=reports), self.assertRaises(ValueError):
                validate_native_classes(reports)


if __name__ == "__main__":
    unittest.main()
