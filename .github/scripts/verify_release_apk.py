#!/usr/bin/env python3
"""Verify final APK alignment, JNI contracts and the exact release certificate."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile


CERTIFICATE = re.compile(
    r"(?:Signer #(?P<index>[1-9][0-9]*) certificate|"
    r"V[234](?:\.[0-9]+)* Signer: certificate) "
    r"SHA-256 digest: (?P<digest>[0-9a-fA-F]{64})"
)


def signer_sha256(report):
    digests = set()
    for line in report.splitlines():
        if "certificate SHA-256 digest:" not in line:
            continue
        match = CERTIFICATE.fullmatch(line.strip())
        if match is None:
            raise ValueError("Unsupported APK certificate report format")
        if match.group("index") not in (None, "1"):
            raise ValueError("Multiple APK signers are not supported")
        digests.add(match.group("digest").lower())
    if not digests:
        raise ValueError("APK signing certificate SHA-256 could not be read")
    if len(digests) != 1:
        raise ValueError("APK signing schemes report different certificates")
    return digests.pop()


def command_output(command):
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode:
        # Do not echo commands or tool diagnostics that may contain credentials.
        raise ValueError(f"{Path(command[0]).name} verification failed")
    return result.stdout


ENGINE = "kr.kimrasng.proxima.mihomo.NativeEngine"
PROTECTOR = ENGINE + "$Protector"
NATIVE_METHODS = {
    "version": ("java.lang.String", (), "true"),
    "startNative": ("void", ("byte[]", "int", PROTECTOR, "java.lang.String"), "false"),
    "stopNative": ("void", (), "false"),
    "trafficStatsNative": ("long[]", ("long",), "true"),
    "delayTestNative": ("int", ("long", "byte[]", "byte[]", "int"), "true"),
    "connectionsSnapshotNative": ("byte[]", ("long",), "true"),
    "selectNative": ("void", ("long", "byte[]", "byte[]"), "true"),
}


def method_matches(method, name, returns, parameters, static):
    return (method.get("name") == name and method.get("return") == returns
            and method.get("static") == static
            and tuple(p.get("type") for p in method.findall("parameter")) == parameters)


def validate_native_classes(reports):
    """Check names and signatures resolved by bridge.c after R8 has run."""
    classes = {}
    for report in reports:
        try:
            root = ET.fromstring(report)
        except ET.ParseError as error:
            raise ValueError("Invalid APK DEX inspection report") from error
        for package in root.findall("package"):
            for cls in package.findall("class"):
                name = ".".join(filter(None, (package.get("name"), cls.get("name"))))
                if name in classes:
                    raise ValueError("Duplicate APK DEX class")
                classes[name] = cls
    engine = classes.get(ENGINE)
    if engine is None:
        raise ValueError("APK JNI NativeEngine class is missing or renamed")
    if not any(f.get("name") == "handle" and f.get("type") == "long"
               and f.get("static") == "false" and f.get("volatile") == "true"
               for f in engine.findall("field")):
        raise ValueError("APK JNI NativeEngine.handle must remain a volatile instance long")
    for name, (returns, parameters, static) in NATIVE_METHODS.items():
        if not any(m.get("native") == "true"
                   and method_matches(m, name, returns, parameters, static)
                   for m in engine.findall("method")):
            raise ValueError(f"APK JNI method missing or changed: {name}")

    def has_protect(cls):
        return any(m.get("visibility") == "public"
                   and method_matches(m, "protect", "boolean", ("int",), "false")
                   for m in cls.findall("method"))

    protector = classes.get(PROTECTOR)
    if protector is None or protector.get("interface") != "true" or not has_protect(protector):
        raise ValueError("APK JNI Protector.protect(int) is missing or renamed")
    callbacks = [c for c in classes.values()
                 if c.get("interface") == "false" and c.get("abstract") == "false"
                 and any(i.get("name") == PROTECTOR for i in c.findall("implements"))]
    if not callbacks:
        raise ValueError("APK JNI Protector implementation is missing")
    for callback in callbacks:
        seen = set()
        while not has_protect(callback):
            parent = callback.get("extends")
            if parent in seen or parent not in classes:
                raise ValueError("APK JNI callback protect(int) is missing or renamed")
            seen.add(parent)
            callback = classes[parent]


def verify_native_bridge(apk, build_tools):
    reports = []
    with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory() as directory:
        dex_names = [n for n in archive.namelist() if re.fullmatch(r"classes(?:[0-9]+)?\.dex", n)]
        if not dex_names:
            raise ValueError("APK contains no DEX files")
        for name in dex_names:
            dex = Path(directory) / name
            dex.write_bytes(archive.read(name))
            reports.append(command_output([str(build_tools / "dexdump"), "-l", "xml", str(dex)]))
    validate_native_classes(reports)
    print("APK native JNI fields, methods and protector callbacks verified")


def verify(apk, keystore, build_tools):
    alias = os.environ.get("KEY_ALIAS")
    if not alias or not os.environ.get("KEYSTORE_PASSWORD"):
        raise ValueError("KEY_ALIAS and KEYSTORE_PASSWORD are required")
    command_output([str(build_tools / "zipalign"), "-c", "-P", "16", "4", str(apk)])
    verify_native_bridge(apk, build_tools)
    certificate = command_output([
        "keytool", "-exportcert", "-keystore", str(keystore),
        "-storepass:env", "KEYSTORE_PASSWORD", "-alias", alias,
    ])
    if not certificate:
        raise ValueError("Release keystore returned an empty certificate")
    expected = hashlib.sha256(certificate).hexdigest()
    report = command_output([
        str(build_tools / "apksigner"), "verify", "--print-certs", str(apk),
    ]).decode("utf-8")
    actual = signer_sha256(report)
    if actual != expected:
        raise ValueError("APK signer does not match the configured release keystore")
    print("APK alignment, signature and release certificate verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--keystore", type=Path, required=True)
    parser.add_argument("--build-tools", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args.apk, args.keystore, args.build_tools)
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
