plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

abstract class MihomoBuildLock : BuildService<BuildServiceParameters.None>, AutoCloseable {
    override fun close() = Unit
}

val mihomoNativeDir = rootProject.layout.projectDirectory.dir("../native")
val mihomoEngineDir = mihomoNativeDir.dir("mihomo-engine")
val allMihomoAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
val mihomoBuildLock = gradle.sharedServices.registerIfAbsent("mihomoBuildLock", MihomoBuildLock::class) {
    maxParallelUsages.set(1)
}

android {
    namespace = "kr.kimrasng.proxima.client.android.proxima"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "kr.kimrasng.proxima.client.android.proxima"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appAuthRedirectScheme"] = "kr.kimrasng.proxima"
    }

    val releaseCredentials = listOf("KEYSTORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD")
        .associateWith { System.getenv(it).orEmpty() }
    val hasReleaseCredentials = releaseCredentials.values.all { it.isNotEmpty() }
    require(hasReleaseCredentials || releaseCredentials.values.all { it.isEmpty() }) {
        "Set KEYSTORE_PASSWORD, KEY_ALIAS and KEY_PASSWORD together for release signing"
    }
    val releaseSigning = if (hasReleaseCredentials) signingConfigs.create("release") {
        storeFile = file(System.getenv("KEYSTORE_PATH") ?: "upload-keystore.jks")
        storePassword = releaseCredentials.getValue("KEYSTORE_PASSWORD")
        keyAlias = releaseCredentials.getValue("KEY_ALIAS")
        keyPassword = releaseCredentials.getValue("KEY_PASSWORD")
    } else null

    buildTypes {
        release {
            // Without credentials, local release builds are unsigned, never debug-signed.
            signingConfig = releaseSigning
        }
    }

    sourceSets.getByName("main").java.srcDir(mihomoEngineDir.dir("java"))
}

// Separate variant outputs prevent debug ABI selection from affecting release.
androidComponents {
    onVariants(selector().all()) { variant ->
        val title = variant.name.replaceFirstChar { it.uppercase() }
        val requestedAbis = providers.environmentVariable("MIHOMO_DEBUG_ABIS")
        val abis = if (variant.buildType == "debug" && requestedAbis.isPresent) {
            requestedAbis.get().split(',').map { it.trim() }.also {
                require(it.isNotEmpty() && it.all { abi -> abi in allMihomoAbis } && it.distinct().size == it.size) {
                    "MIHOMO_DEBUG_ABIS must be a comma-separated, nonempty list of: $allMihomoAbis"
                }
            }
        } else allMihomoAbis
        val outputDir = layout.buildDirectory.dir("generated/mihomoJniLibs/${variant.name}")
        val buildMihomo = tasks.register("build${title}Mihomo") {
            usesService(mihomoBuildLock)
            // Gradle snapshots file contents, including the checksum-locked upstream
            // module versions and all local overlay sources, but not generated files.
            inputs.files(fileTree(mihomoNativeDir) { exclude("**/build/**") })
                .withPropertyName("nativeSources").withPathSensitivity(PathSensitivity.RELATIVE)
            inputs.property("abis", abis)
            listOf("PATH", "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_NDK_HOME", "GOENV", "GOEXPERIMENT", "GOOS", "GOARCH", "GOARM", "CGO_ENABLED", "CC", "CGO_CFLAGS", "CGO_LDFLAGS").forEach {
                inputs.property("env.$it", providers.environmentVariable(it).orElse(""))
            }
            outputs.dir(outputDir)
            doLast {
                exec {
                    workingDir(mihomoEngineDir)
                    commandLine("bash", "build.sh", "android")
                }
                sync {
                    from(mihomoEngineDir.dir("build/android")) {
                        abis.forEach { include("$it/libproxima_mihomo_engine.so") }
                    }
                    into(outputDir)
                }
                abis.forEach { abi ->
                    check(outputDir.get().file("$abi/libproxima_mihomo_engine.so").asFile.isFile) {
                        "Missing mihomo engine library for $abi"
                    }
                }
            }
        }
        // The generated directory is owned by this task and merged as JNI libs.
        variant.sources.jniLibs?.addStaticSourceDirectory(outputDir.get().asFile.absolutePath)
        tasks.matching { it.name == "merge${title}JniLibFolders" }.configureEach { dependsOn(buildMihomo) }
        val verifyMihomo = tasks.register("verify${title}Mihomo") {
            dependsOn(buildMihomo, "compile${title}JavaWithJavac")
            doLast {
                val compileJava = tasks.named<JavaCompile>("compile${title}JavaWithJavac").get()
                check(compileJava.destinationDirectory.get().file("kr/kimrasng/proxima/mihomo/NativeEngine.class").asFile.isFile) {
                    "NativeEngine.java was not compiled"
                }
                abis.forEach { abi ->
                    check(outputDir.get().file("$abi/libproxima_mihomo_engine.so").asFile.isFile) {
                        "Missing mihomo engine library for $abi"
                    }
                }
            }
        }
        tasks.matching { it.name == "assemble$title" }.configureEach { dependsOn(verifyMihomo) }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
