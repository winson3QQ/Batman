import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.result.ResolvedComponentResult
import org.gradle.api.artifacts.result.ResolvedDependencyResult

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.batman.batman_app"
    compileSdk = 37  // reactive_ble_mobile 5.6.0 compiles against 37 (its AAR metadata); targetSdk is the literal 36 below (D6)
    ndkVersion = "30.0.16248370"  // the installed NDK, fixed (design §2: NDK version pinned)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    defaultConfig {
        applicationId = "dev.batman.app"
        minSdk = 31  // Android 12+ (design §1): PURPOSE_AGREE_KEY, KeyInfo.securityLevel
        // 254-app-update D6: a literal, not flutter.targetSdkVersion — at 37 (Android 17) local network protection needs
        // ACCESS_LOCAL_NETWORK for the update's raw-socket PUT to the node (F24); raising this line is a decision of its
        // own (design §12-6), caught in code review, never a side effect of `flutter upgrade`.
        targetSdk = 36
        // T9 / T12 (instrumented, on the phone; written, run by hand): src/androidTest
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { abiFilters += listOf("arm64-v8a") }  // design §2: arm64-v8a only
    }

    // design v8.5.1 §4.1: dev / field are build constants. Each flavor has its own applicationId (own Keystore aliases,
    // records, launcher name; one cannot be installed over the other) and its own DEV_TRUST, which must equal the Rust
    // library's (startup cross-check; the Rust side is the Cargo feature `dev-trust`).
    flavorDimensions += "trust"
    productFlavors {
        create("dev") {
            dimension = "trust"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Batman dev")
            buildConfigField("boolean", "DEV_TRUST", "true")
        }
        // 254-app-member-join §9: a second dev install on the same phone (the remote member's app in bench tests):
        // its own applicationId -> its own Keystore aliases and records
        create("dev2") {
            dimension = "trust"
            applicationIdSuffix = ".dev2"
            resValue("string", "app_name", "Batman dev2")
            buildConfigField("boolean", "DEV_TRUST", "true")
        }
        create("field") {
            dimension = "trust"
            resValue("string", "app_name", "Batman")
            buildConfigField("boolean", "DEV_TRUST", "false")
        }
    }

    buildTypes {
        release {
            // TODO: release signing (not before the field build exists, #255)
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // v0.4.3 BleRx: RxJavaPlugins + BleException — the versions reactive_ble_mobile 5.6.0 already brings (its
    // build.gradle: rxandroidble 1.16.0 -> rxjava 2.2.17); declared here because the plugin's are `implementation`
    implementation("com.polidea.rxandroidble2:rxandroidble:1.16.0")
    implementation("io.reactivex.rxjava2:rxjava:2.2.17")
    // 254-app-qr §1: the claim-QR scanner — CameraX + ZXing core (no ML Kit / Play services). androidx.activity is the
    // version the Flutter embedding already resolves (fragment 1.7.1 -> activity 1.8.1), declared for QrScanActivity.
    implementation("androidx.activity:activity:1.8.1")
    implementation("androidx.camera:camera-core:1.6.2")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("com.google.zxing:core:3.5.4")
    testImplementation("junit:junit:4.13.2")
    // 254-app-update T9 / T12 only (androidTest; not part of any APK)
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

flutter {
    source = "../.."
}

// 254-app-qr §4 (B-M2 / B r2-m1): the dependency groups an APK may carry, exact names (no prefixes). Before each
// variant's pre<Variant>Build its runtime classpath is resolved; a group outside this list, an unresolved dependency or
// an empty classpath fails the build. The list = the groups resolved before the QR scanner (2026-11-13, PR dependency
// diff) + androidx.camera / com.google.zxing. Never here: com.google.android.gms, com.google.mlkit,
// com.google.firebase, com.google.android.datatransport. A compromised version inside a listed group is not caught
// (Gradle dependency locking, #254 checklist).
val allowedGroups = setOf(
    "androidx.activity", "androidx.annotation", "androidx.arch.core", "androidx.collection", "androidx.concurrent",
    "androidx.core", "androidx.customview", "androidx.exifinterface", "androidx.fragment", "androidx.interpolator",
    "androidx.lifecycle", "androidx.loader", "androidx.profileinstaller", "androidx.savedstate", "androidx.startup",
    "androidx.tracing", "androidx.versionedparcelable", "androidx.viewpager", "androidx.window",
    "androidx.window.extensions.core", "com.getkeepsafe.relinker", "com.google.guava", "com.google.protobuf",
    "com.jakewharton.rxrelay2", "com.polidea.rxandroidble2", "io.flutter", "io.reactivex.rxjava2", "org.jetbrains",
    "org.jetbrains.kotlin", "org.jetbrains.kotlinx", "org.jspecify", "org.reactivestreams",
    // new with the QR scanner: ZXing core, CameraX 1.6.2 and what it brings (camera-view -> appcompat 1.1.0,
    // camera-video -> media3 muxer, camera2-pipe -> dagger, guava's annotation jars)
    "com.google.zxing", "androidx.camera", "androidx.camera.featurecombinationquery", "androidx.camera.viewfinder",
    "androidx.appcompat", "androidx.cursoradapter", "androidx.drawerlayout", "androidx.media3", "androidx.vectordrawable",
    "com.google.auto.value", "com.google.code.findbugs", "com.google.dagger", "com.google.errorprone", "com.google.j2objc",
    "jakarta.inject", "javax.inject", "org.checkerframework",
)

// configuration-cache safe: the resolution result is a lazy task input, the action touches no Project
abstract class DependencyGroupGate : DefaultTask() {
    @get:Input abstract val allowed: SetProperty<String>
    @get:Input abstract val root: Property<ResolvedComponentResult>

    @TaskAction
    fun check() {
        val groups = sortedSetOf<String>()
        val bad = sortedSetOf<String>()
        val seen = HashSet<Any>()
        val todo = ArrayDeque(listOf(root.get()))
        while (todo.isNotEmpty()) {
            val c = todo.removeFirst()
            if (!seen.add(c.id)) continue
            (c.id as? ModuleComponentIdentifier)?.let { groups.add(it.group) }
            for (d in c.dependencies) {
                if (d is ResolvedDependencyResult) todo.add(d.selected) else bad.add("unresolved ${d.requested.displayName}")
            }
        }
        if (groups.isEmpty()) bad.add("empty runtime classpath")
        groups.filterNot { it in allowed.get() }.forEach { bad.add("group not allowed: $it") }
        if (bad.isNotEmpty()) throw GradleException("$name: ${bad.joinToString("; ")}")
        logger.lifecycle("$name: ${groups.size} groups, all allowed")
    }
}

androidComponents {
    onVariants { v ->
        val cap = v.name.replaceFirstChar { it.uppercase() }
        val gate = tasks.register<DependencyGroupGate>("check${cap}DependencyGroups") {
            allowed.set(allowedGroups)
            root.set(v.runtimeConfiguration.incoming.resolutionResult.rootComponent)
        }
        tasks.matching { it.name == "pre${cap}Build" }.configureEach { dependsOn(gate) }
    }
}
