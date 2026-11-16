#!/usr/bin/env python3
"""Verify APK alignment, its signature, and its exact release certificate."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


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


def verify(apk, keystore, build_tools):
    alias = os.environ.get("KEY_ALIAS")
    if not alias or not os.environ.get("KEYSTORE_PASSWORD"):
        raise ValueError("KEY_ALIAS and KEYSTORE_PASSWORD are required")
    command_output([str(build_tools / "zipalign"), "-c", "-P", "16", "4", str(apk)])
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
