"""Discover and execute the production Kotlin boundary's host contract tests.

Run from the repository root:
    python3 -m unittest discover -s android/app/src/test -v

Requires JDK 17/21 (JAVA_HOME is honored), and either kotlinc on PATH/KOTLINC
or the repository's Kotlin 2.2.20 compiler artifacts in GRADLE_USER_HOME.
Missing tooling fails the test; nothing is downloaded or silently skipped.
This host entry point is deliberately independent of Android Gradle/CI wiring.
It does not emulate Binder, load Android stubs, or prove device behavior.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MihomoWorkerBoundaryHostTest(unittest.TestCase):
    def test_lifecycle_authentication_configuration_and_descriptor_ownership(self):
        source = Path(__file__).resolve().parents[1]
        package = Path("kotlin/kr/kimrasng/proxima/client/android/proxima")
        files = [
            source / "main" / package / name
            for name in (
                "MihomoLeaseGate.kt",
                "MihomoConfiguration.kt",
                "MihomoWorkerHandshake.kt",
            )
        ]
        files.append(source / "test" / package / "MihomoBoundaryHostTest.kt")
        self.run_host(files, "MihomoBoundaryHostTest", r"PASS [1-9][0-9]* deterministic Mihomo boundary host tests")

    def test_settings_engine_persistence_and_defaults(self):
        source = Path(__file__).resolve().parents[1]
        package = Path("kotlin/kr/kimrasng/proxima/client/android/proxima")
        files = [
            source / "main" / package / "VpnSettingsRepository.kt",
            source / "test" / package / "VpnSettingsHostTest.kt",
            source / "test/fixtures/settings/Context.kt",
            source / "test/fixtures/settings/JSONObject.kt",
        ]
        self.run_host(files, "VpnSettingsHostTest", r"PASS VpnSettings engine persistence and defaults")

    def run_host(self, files, test_class, expected):
        java_home = os.environ.get("JAVA_HOME")
        java = str(Path(java_home) / "bin/java") if java_home else shutil.which("java")
        self.assertTrue(java, "JDK 17/21 is required; set JAVA_HOME")
        compiler = os.environ.get("KOTLINC") or shutil.which("kotlinc")
        main_class = f"kr.kimrasng.proxima.client.android.proxima.{test_class}"

        def run(command):
            result = subprocess.run(command, capture_output=True, text=True, timeout=180)
            self.assertEqual(
                result.returncode, 0,
                f"Command failed: {' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}",
            )
            return result.stdout

        with tempfile.TemporaryDirectory(prefix="proxima-mihomo-host-") as output:
            target = str(Path(output) / "boundary.jar")
            if compiler:
                run([
                    compiler, "-Werror", "-jvm-target", "17", "-include-runtime",
                    *map(str, files), "-d", target,
                ])
                runtime = target
            else:
                cache = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
                cache = cache / "caches/modules-2/files-2.1"
                artifacts = (
                    ("org.jetbrains.kotlin", "kotlin-compiler-embeddable", "2.2.20"),
                    ("org.jetbrains.kotlin", "kotlin-stdlib", "2.2.20"),
                    ("org.jetbrains.kotlin", "kotlin-script-runtime", "2.2.20"),
                    ("org.jetbrains.kotlin", "kotlin-reflect", "1.6.10"),
                    ("org.jetbrains.kotlin", "kotlin-daemon-embeddable", "2.2.20"),
                    ("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.0"),
                    ("org.jetbrains", "annotations", "13.0"),
                )
                jars = []
                for group, artifact, version in artifacts:
                    matches = list((cache / group / artifact / version).glob(f"*/{artifact}-{version}.jar"))
                    self.assertEqual(
                        len(matches), 1,
                        f"Missing or ambiguous cached {artifact}:{version}; install kotlinc 2.2.20",
                    )
                    jars.append(str(matches[0]))
                run([
                    java, "-cp", os.pathsep.join(jars),
                    "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                    "-Werror", "-no-stdlib", "-no-reflect", "-jvm-target", "17",
                    "-classpath", jars[1], *map(str, files), "-d", target,
                ])
                runtime = os.pathsep.join((target, jars[1]))
            stdout = run([java, "-cp", runtime, main_class])
            self.assertRegex(stdout, expected)
            print(stdout, end="")


if __name__ == "__main__":
    unittest.main()
