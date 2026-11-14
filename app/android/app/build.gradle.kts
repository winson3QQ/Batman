import com.android.build.api.artifact.SingleArtifact
import org.gradle.api.artifacts.component.ComponentArtifactIdentifier
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.component.ProjectComponentIdentifier
import org.gradle.api.artifacts.result.ResolvedComponentResult
import org.gradle.api.artifacts.result.ResolvedDependencyResult

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// design §2: an emulator build asks for the x86_64 ABI itself: -Pemulator-abi=true (flutter build apk -P emulator-abi=true).
// Only the exact value "true" turns it on; any other value but "false" stops the build (a typo must not quietly make
// an APK without the emulator's ABI); a field build with it fails (check<Variant>EmulatorAbi below).
val emulatorAbi = (findProperty("emulator-abi") as String?).let {
    if (it != null && it != "true" && it != "false") throw GradleException("emulator-abi=\"$it\": only true or false")
    it == "true"
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
        // design §2: arm64-v8a only. clear(): the Flutter plugin has already put its three default ABIs here, so `+=` alone
        // changed nothing. An emulator build asks for x86_64 itself: -Pemulator-abi=true (see emulatorAbi above).
        ndk { abiFilters.clear(); abiFilters += listOf("arm64-v8a") + if (emulatorAbi) listOf("x86_64") else listOf() }
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
    // No camera-view: PreviewView pulled appcompat, camera-video, media3 and guava; the preview is qr/Viewfinder.kt.
    implementation("androidx.activity:activity:1.8.1")
    implementation("androidx.camera:camera-core:1.6.2")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
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

// 254-app-qr §4 (B-M2 / B r2-m1, code review r1 B-M1 / B-m1): the modules an APK may carry, exact `group:module`
// names (no prefixes, no versions). Before each variant's pre<Variant>Build:
// - its runtime dependency graph: a module outside this list, an unresolved dependency or an empty graph fails;
// - its classes artifacts (what is dexed): one that is neither a listed module nor a project (a `files(...)` jar in
//   :app or in a plugin project) fails.
// The list = exactly what the 9 variants resolve today (2026-11-13; before the QR scanner + CameraX core / camera2 /
// lifecycle 1.6.2 and ZXing core 3.5.4). Never here: com.google.android.gms, com.google.mlkit, com.google.firebase,
// com.google.android.datatransport. Not covered: a compromised version of a listed module (Gradle dependency locking,
// #254 checklist); Dart pub packages and the Rust .so (not Gradle dependencies).
val allowedModules = setOf<String>(
    "androidx.activity:activity", "androidx.annotation:annotation", "androidx.annotation:annotation-experimental",
    "androidx.annotation:annotation-jvm", "androidx.arch.core:core-common", "androidx.arch.core:core-runtime",
    "androidx.camera.featurecombinationquery:featurecombinationquery", "androidx.camera:camera-camera2",
    "androidx.camera:camera-camera2-pipe", "androidx.camera:camera-core", "androidx.camera:camera-lifecycle",
    "androidx.collection:collection", "androidx.concurrent:concurrent-futures",
    "androidx.concurrent:concurrent-futures-ktx", "androidx.core:core", "androidx.core:core-backported-fixes",
    "androidx.core:core-ktx", "androidx.customview:customview", "androidx.exifinterface:exifinterface",
    "androidx.fragment:fragment", "androidx.interpolator:interpolator", "androidx.lifecycle:lifecycle-common",
    "androidx.lifecycle:lifecycle-common-java8", "androidx.lifecycle:lifecycle-livedata",
    "androidx.lifecycle:lifecycle-livedata-core", "androidx.lifecycle:lifecycle-livedata-core-ktx",
    "androidx.lifecycle:lifecycle-process", "androidx.lifecycle:lifecycle-runtime",
    "androidx.lifecycle:lifecycle-viewmodel", "androidx.lifecycle:lifecycle-viewmodel-savedstate",
    "androidx.loader:loader", "androidx.profileinstaller:profileinstaller", "androidx.savedstate:savedstate",
    "androidx.startup:startup-runtime", "androidx.tracing:tracing", "androidx.tracing:tracing-android",
    "androidx.tracing:tracing-ktx", "androidx.versionedparcelable:versionedparcelable", "androidx.viewpager:viewpager",
    "androidx.window.extensions.core:core", "androidx.window:window", "androidx.window:window-java",
    "com.getkeepsafe.relinker:relinker", "com.google.auto.value:auto-value-annotations", "com.google.dagger:dagger",
    "com.google.guava:listenablefuture", "com.google.protobuf:protobuf-javalite", "com.google.zxing:core",
    "com.jakewharton.rxrelay2:rxrelay", "com.polidea.rxandroidble2:dagger-library-shadow",
    "com.polidea.rxandroidble2:rxandroidble", "io.flutter:arm64_v8a_debug", "io.flutter:arm64_v8a_profile",
    "io.flutter:arm64_v8a_release", "io.flutter:armeabi_v7a_debug", "io.flutter:armeabi_v7a_profile",
    "io.flutter:armeabi_v7a_release", "io.flutter:flutter_embedding_debug", "io.flutter:flutter_embedding_profile",
    "io.flutter:flutter_embedding_release", "io.flutter:x86_64_debug", "io.flutter:x86_64_profile",
    "io.flutter:x86_64_release", "io.reactivex.rxjava2:rxandroid", "io.reactivex.rxjava2:rxjava",
    "io.reactivex.rxjava2:rxkotlin", "jakarta.inject:jakarta.inject-api", "javax.inject:javax.inject",
    "org.jetbrains.kotlin:kotlin-stdlib", "org.jetbrains.kotlin:kotlin-stdlib-jdk7", "org.jetbrains.kotlinx:atomicfu",
    "org.jetbrains.kotlinx:atomicfu-jvm", "org.jetbrains.kotlinx:kotlinx-coroutines-android",
    "org.jetbrains.kotlinx:kotlinx-coroutines-bom", "org.jetbrains.kotlinx:kotlinx-coroutines-core",
    "org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm", "org.jetbrains:annotations", "org.jspecify:jspecify",
    "org.reactivestreams:reactive-streams",)

// configuration-cache safe: the resolution results are lazy task inputs, the action touches no Project
abstract class DependencyGate : DefaultTask() {
    @get:Input abstract val allowed: SetProperty<String>
    @get:Input abstract val root: Property<ResolvedComponentResult>
    @get:Input abstract val artifacts: ListProperty<ComponentArtifactIdentifier>

    @TaskAction
    fun check() {
        val modules = sortedSetOf<String>()
        val bad = sortedSetOf<String>()
        val seen = HashSet<Any>()
        val todo = ArrayDeque(listOf(root.get()))
        while (todo.isNotEmpty()) {
            val c = todo.removeFirst()
            if (!seen.add(c.id)) continue
            (c.id as? ModuleComponentIdentifier)?.let { modules.add("${it.group}:${it.module}") }
            for (d in c.dependencies) {
                if (d is ResolvedDependencyResult) todo.add(d.selected) else bad.add("unresolved ${d.requested.displayName}")
            }
        }
        if (modules.isEmpty()) bad.add("empty runtime classpath")
        modules.filterNot { it in allowed.get() }.forEach { bad.add("module not allowed: $it") }
        for (a in artifacts.get()) {
            when (val c = a.componentIdentifier) {
                is ProjectComponentIdentifier -> {}
                is ModuleComponentIdentifier -> if ("${c.group}:${c.module}" !in allowed.get()) bad.add("module not allowed: ${c.group}:${c.module}")
                else -> bad.add("not a module or project: ${a.displayName}")
            }
        }
        if (bad.isNotEmpty()) throw GradleException("$name: ${bad.joinToString("; ")}")
        logger.lifecycle("$name: ${modules.size} modules, ${artifacts.get().size} class artifacts, all allowed")
    }
}

// 254-app-qr §4 / §5 S2 (code review r2 B r2-M1, r3 B MAJOR / m1): the merged manifest of every variant.
// - Permissions: every element whose tag starts with `uses-permission` (uses-permission, -sdk-23, -sdk-m, any later
//   one), as tag:name, must equal this set exactly (the field release merged manifest, 2026-11-13; ${applicationId} =
//   the variant's).
// - Exported components: an activity / activity-alias / service / receiver / provider whose android:exported is set
//   to anything but the literal "false" (a resource reference counts, r4),
//   or with an intent-filter and no android:exported (fail closed; targetSdk 36 refuses that at merge / install, so
//   it should never be seen), must be one of [exportedComponents].
// - No activity-alias may target QrScanActivity; QrScanActivity is declared once, exported="false", no intent-filter.
// - Backup (254-app-s1 §4): <application> has android:allowBackup="false" and
//   android:dataExtractionRules="@xml/data_extraction_rules"; every src/*/res/xml*/data_extraction_rules.xml (main's
//   must exist; a flavor's, a build type's or a qualified one — xml-v31, … — would replace it) has exactly <cloud-backup> and <device-transfer>, each
//   with nothing but one <exclude domain=… path="."> per domain of [backupDomains] — an <include>, a missing domain or
//   a narrower path fails. No values file under src/*/res/values*/ may define a resource named data_extraction_rules
//   (an <item type="xml" name="data_extraction_rules">@xml/other</item> in a flavor's values replaces the rules file
//   that aapt compiles, while the file checked here stays untouched; review round 2 B-MINOR-3). <application> has no
//   android:backupAgent, and android:fullBackupContent only absent or "false" (B-MINOR-4).
// - Every build type but `debug` and `profile` (Flutter's own development types; profile is initWith(debug) in
//   FlutterPlugin.kt) whose merged manifest has android:debuggable at all, unless the literal "false", fails
//   (254-app-s1 §4), e.g. a staging type, or a reference such as "@bool/dbg" (review round 3 A-MINOR-2).
// - What aapt really linked (review round 3 A-MINOR-3; covers resValue(...) and res dirs outside src/): in every
//   .ap_ that process<Variant>Resources wrote, `aapt2 dump resources` must show xml/data_extraction_rules as exactly
//   one value, the file res/xml/data_extraction_rules.xml (an alias to another resource, or a qualified copy, fails),
//   and `aapt2 dump xmltree` of that file must pass the same rule check as the source files; the AndroidManifest.xml
//   in the .ap_ must pass the whole manifest rule set above too (aapt2 link options such as --debug-mode or --manifest
//   change it after the merge; review round 4). The .ap_ files are the process<Variant>Resources task's declared
//   outputs, not a fixed path. No aapt2, no .ap_ = FAIL.
// - Rules documents (source and linked): every <exclude> has only domain + path and no child element (a nested
//   <include> would be backed up); no attribute on the root or a section (review round 4).
// Anything else fails the build.
val expectedPermissions = setOf(
    "uses-permission:android.permission.BLUETOOTH_SCAN", "uses-permission:android.permission.BLUETOOTH_CONNECT",
    "uses-permission:android.permission.INTERNET", "uses-permission:android.permission.CHANGE_NETWORK_STATE",
    "uses-permission:android.permission.ACCESS_NETWORK_STATE", "uses-permission:android.permission.CAMERA",
    "uses-permission:android.permission.BLUETOOTH", "uses-permission:android.permission.BLUETOOTH_ADMIN",
    "uses-permission:\${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION",
    "uses-permission-sdk-23:android.permission.ACCESS_COARSE_LOCATION",
    "uses-permission-sdk-23:android.permission.ACCESS_FINE_LOCATION",
)
val exportedComponents = setOf(
    "activity:dev.batman.batman_app.MainActivity",
    "receiver:androidx.profileinstaller.ProfileInstallReceiver",
)
val backupDomains = setOf(
    "root", "file", "database", "sharedpref", "external", "device_root", "device_file", "device_database",
    "device_sharedpref",
)

abstract class ManifestGate : DefaultTask() {
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE) abstract val manifest: RegularFileProperty
    @get:Input abstract val applicationId: Property<String>
    @get:Input abstract val expected: SetProperty<String>
    @get:Input abstract val exportable: SetProperty<String>
    @get:InputFiles @get:PathSensitive(PathSensitivity.RELATIVE) abstract val backupRules: ConfigurableFileCollection
    @get:InputFiles @get:PathSensitive(PathSensitivity.RELATIVE) abstract val valueFiles: ConfigurableFileCollection
    @get:Input abstract val domains: SetProperty<String>
    @get:Input abstract val buildType: Property<String>
    @get:InputFiles @get:PathSensitive(PathSensitivity.RELATIVE) abstract val linked: ConfigurableFileCollection
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE) abstract val aapt2: RegularFileProperty

    /**
     * A parsed XML element, from the DOM (source files, the merged manifest) or from `aapt2 dump xmltree` (what was
     * linked). Attributes in the android namespace are keyed "android:<name>", others by their plain name.
     */
    class X(val tag: String, val attrs: Map<String, String>, val kids: List<X>) {
        fun all(): List<X> = listOf(this) + kids.flatMap { it.all() }
        fun a(n: String) = attrs["android:$n"] ?: ""
        fun has(n: String) = "android:$n" in attrs
    }

    private val ns = "http://schemas.android.com/apk/res/android"

    private fun aapt2(vararg args: String): String {
        val p = ProcessBuilder(listOf(aapt2.get().asFile.path) + args).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        if (p.waitFor() != 0) throw GradleException("$name: aapt2 ${args.joinToString(" ")} failed: $out")
        return out
    }

    private fun dom(e: org.w3c.dom.Element): X = X(e.localName ?: e.tagName,
        (0 until e.attributes.length).map { e.attributes.item(it) }.filter { it.nodeName != "xmlns" && !it.nodeName.startsWith("xmlns:") }
            .associate { a -> (if (a.namespaceURI == ns) "android:${a.localName}" else a.nodeName) to a.nodeValue },
        e.childNodes.let { l -> (0 until l.length).map { l.item(it) } }.filterIsInstance<org.w3c.dom.Element>().map(::dom))

    private fun parse(f: java.io.File): X = dom(javax.xml.parsers.DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(f).documentElement)

    /**
     * `aapt2 dump xmltree` lines -> the root element: "E: tag (line=N)", "A: [<ns>:]name[(0x…)]=value [(Raw: …)]"
     * (a quoted value is unquoted), nested by indent; namespace (N:) and text (T:) lines are skipped.
     */
    private fun xmltree(out: String): X? {
        class B(val tag: String, val indent: Int) { val attrs = mutableMapOf<String, String>(); val kids = mutableListOf<B>() }
        fun B.x(): X = X(tag, attrs, kids.map { it.x() })
        val stack = ArrayDeque<B>(); var root: B? = null
        for (line in out.lines()) {
            val t = line.trimStart(); val ind = line.length - t.length
            Regex("""^E: (\S+) \(line=\d+\)$""").find(t)?.let { m ->
                while (stack.isNotEmpty() && stack.last().indent >= ind) stack.removeLast()
                val b = B(m.groupValues[1], ind)
                if (stack.isEmpty()) { if (root != null) return null; root = b } else stack.last().kids.add(b)
                stack.addLast(b)
            }
            Regex("""^A: (?:(\S+?):)?([A-Za-z_][\w.-]*)(?:\(0x[0-9a-f]+\))?=("(?:[^"\\]|\\.)*"|\S*)(?: \(Raw: .*\))?$""").find(t)?.let { m ->
                val key = if (m.groupValues[1] == ns) "android:${m.groupValues[2]}" else if (m.groupValues[1].isEmpty()) m.groupValues[2] else "${m.groupValues[1]}:${m.groupValues[2]}"
                val v = m.groupValues[3].let { if (it.length >= 2 && it.startsWith("\"") && it.endsWith("\"")) it.substring(1, it.length - 1) else it }
                (stack.lastOrNull() ?: return null).attrs[key] = v
            }
        }
        return root?.x()
    }

    /**
     * The rule check of a data-extraction-rules document, the same for a source file and for the linked one: the root
     * has no attributes and exactly the two sections; a section has no attributes and only <exclude domain=… path=".">
     * with no other attribute and no child element (a nested <include> is backed up: SDK FullBackup.java:822-834,
     * BackupAgent.java:701-725 / 929-979), one per domain of [domains].
     */
    private fun rulesProblems(where: String, r: X, domains: Set<String>): List<String> {
        val bad = mutableListOf<String>()
        if (r.tag != "data-extraction-rules") bad.add("$where: root <${r.tag}>")
        if (r.attrs.isNotEmpty()) bad.add("$where: <${r.tag}> has attributes ${r.attrs.keys}")
        if (r.kids.map { it.tag }.sorted() != listOf("cloud-backup", "device-transfer")) bad.add("$where: sections ${r.kids.map { it.tag }}")
        for (s in r.kids) {
            if (s.attrs.isNotEmpty()) bad.add("$where: <${s.tag}> has attributes ${s.attrs.keys}")
            for (e in s.kids) {
                if (e.tag != "exclude" || e.attrs["path"] != ".") bad.add("$where: ${s.tag} has <${e.tag} domain=\"${e.attrs["domain"]}\" path=\"${e.attrs["path"]}\">")
                if (e.attrs.keys != setOf("domain", "path")) bad.add("$where: ${s.tag} <${e.tag}> attributes ${e.attrs.keys}")
                e.kids.forEach { bad.add("$where: ${s.tag} <${e.tag} domain=\"${e.attrs["domain"]}\"> has a child <${it.tag} domain=\"${it.attrs["domain"]}\" path=\"${it.attrs["path"]}\">") }
            }
            val got = s.kids.filter { it.tag == "exclude" && it.attrs["path"] == "." }.map { it.attrs["domain"] ?: "" }
            (domains - got.toSet()).sorted().forEach { bad.add("$where: ${s.tag} does not exclude $it") }
            if (got.size != got.toSet().size || !domains.containsAll(got)) bad.add("$where: ${s.tag} excludes $got")
        }
        return bad
    }

    /** What a manifest problem list counts besides the problems (for the summary line). */
    class Seen(val perms: Int, val exported: Int)

    /**
     * The whole manifest rule set, the same for the merged manifest and for the manifest aapt linked into the .ap_
     * ([rulesRef] = how that manifest may name the rules resource: "@xml/data_extraction_rules" merged; linked, its id "@0x…"
     * (binary format) or the same name (proto format)).
     */
    private fun manifestProblems(where: String, root: X, rulesRef: Set<String>, bad: MutableList<String>): Seen {
        val all = root.all()
        val qrName = "dev.batman.batman_app.qr.QrScanActivity"
        fun add(s: String) = bad.add("$where: $s")
        val perms = all.filter { it.tag.startsWith("uses-permission") }.map { "${it.tag}:${it.a("name")}" }.toSortedSet()
        val want = expected.get().map { it.replace("\${applicationId}", applicationId.get()) }.toSortedSet()
        (perms - want).forEach { add("unexpected $it") }
        (want - perms).forEach { add("missing $it") }
        var exported = 0
        for (c in all.filter { it.tag in setOf("activity", "activity-alias", "service", "receiver", "provider") }) {
            val filters = c.all().count { it.tag == "intent-filter" }
            val e = c.a("exported") // r4: anything but a literal "false" (e.g. @bool/x) counts; absent = filter decides
            if (e != "false" && (e.isNotEmpty() || filters > 0)) {
                exported++
                if ("${c.tag}:${c.a("name")}" !in exportable.get()) add("exported ${c.tag} ${c.a("name")}")
            }
            if (c.tag == "activity-alias" && c.a("targetActivity").substringAfterLast('.') == "QrScanActivity")
                add("activity-alias ${c.a("name")} targets QrScanActivity")
        }
        val qr = all.filter { it.tag == "activity" && it.a("name") == qrName }
        if (qr.size != 1) add("QrScanActivity declared ${qr.size} times")
        for (q in qr) {
            if (q.a("exported") != "false") add("QrScanActivity exported=\"${q.a("exported")}\"")
            if (q.all().any { it.tag == "intent-filter" }) add("QrScanActivity has an intent-filter")
        }
        val app = all.filter { it.tag == "application" }
        if (app.size != 1) add("application declared ${app.size} times")
        for (x in app) {
            if (x.a("allowBackup") != "false") add("allowBackup=\"${x.a("allowBackup")}\"")
            if (x.a("dataExtractionRules") !in rulesRef) add("dataExtractionRules=\"${x.a("dataExtractionRules")}\"")
            if (buildType.get() !in setOf("debug", "profile") && x.has("debuggable") && x.a("debuggable") != "false")
                add("build type ${buildType.get()} is debuggable (\"${x.a("debuggable")}\")")
            if (x.has("backupAgent")) add("backupAgent=\"${x.a("backupAgent")}\"")
            if (x.has("fullBackupContent") && x.a("fullBackupContent") != "false") add("fullBackupContent=\"${x.a("fullBackupContent")}\"")
        }
        return Seen(perms.size, exported)
    }

    @TaskAction
    fun check() {
        val bad = mutableListOf<String>()
        val seen = manifestProblems("merged", parse(manifest.get().asFile), setOf("@xml/data_extraction_rules"), bad)
        val rules = backupRules.files.sortedBy { it.path }
        if (rules.none { it.parentFile.parentFile.parentFile.name == "main" && it.parentFile.name == "xml" }) bad.add("no main data_extraction_rules.xml")
        for (f in rules)
            bad.addAll(rulesProblems("${f.parentFile.parentFile.parentFile.name}/${f.parentFile.name}/data_extraction_rules.xml", parse(f), domains.get()))
        // what aapt linked: the outputs of process<Variant>Resources (an .ap_ elsewhere is not one of them)
        val aps = linked.asFileTree.matching { include("**/*.ap_") }.files.sortedBy { it.path }
        if (aps.isEmpty()) bad.add("no linked resources (.ap_) among the process<Variant>Resources outputs")
        for (ap in aps) {
            val lines = aapt2("dump", "resources", ap.path).lines()
            val i = lines.indexOfFirst { Regex("""^\s*resource 0x[0-9a-f]+ xml/data_extraction_rules$""").matches(it) }
            if (i < 0) { bad.add("${ap.name}: no xml/data_extraction_rules"); continue }
            val id = Regex("""resource (0x[0-9a-f]+) """).find(lines[i])!!.groupValues[1]
            val ind = lines[i].length - lines[i].trimStart().length
            val values = lines.drop(i + 1).takeWhile { it.isNotBlank() && it.length - it.trimStart().length > ind }.map { it.trim() }
            if (values.size != 1 || !values[0].startsWith("() (file) res/xml/data_extraction_rules.xml type="))
                bad.add("${ap.name}: xml/data_extraction_rules is $values")
            else bad.addAll(xmltree(aapt2("dump", "xmltree", "--file", "res/xml/data_extraction_rules.xml", ap.path))
                ?.let { rulesProblems("${ap.name}:res/xml/data_extraction_rules.xml", it, domains.get()) }
                ?: listOf("${ap.name}: res/xml/data_extraction_rules.xml unreadable"))
            // the manifest aapt really linked (aapt2 link options can change it after the merge)
            xmltree(aapt2("dump", "xmltree", "--file", "AndroidManifest.xml", ap.path))
                ?.let { manifestProblems("${ap.name}:AndroidManifest.xml", it, setOf("@$id", "@xml/data_extraction_rules"), bad) }
                ?: bad.add("${ap.name}: AndroidManifest.xml unreadable")
        }
        for (f in valueFiles.files.sortedBy { it.path }) {
            val v = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(f).getElementsByTagName("*")
            for (e in (0 until v.length).map { v.item(it) as org.w3c.dom.Element }.filter { it.getAttribute("name") == "data_extraction_rules" })
                bad.add("${f.parentFile.parentFile.parentFile.name}/${f.parentFile.name}/${f.name}: <${e.tagName} type=\"${e.getAttribute("type")}\" name=\"data_extraction_rules\">")
        }
        if (bad.isNotEmpty()) throw GradleException("$name: ${bad.joinToString("; ")}")
        logger.lifecycle("$name: ${seen.perms} permissions as expected, ${seen.exported} exported components allowed, QrScanActivity not exported, no backup (${rules.size} rule file, ${aps.size} linked, merged + linked manifest)")
    }
}

androidComponents {
    onVariants { v ->
        val cap = v.name.replaceFirstChar { it.uppercase() }
        val gate = tasks.register<DependencyGate>("check${cap}DependencyGroups") {
            allowed.set(allowedModules)
            root.set(v.runtimeConfiguration.incoming.resolutionResult.rootComponent)
            artifacts.set(v.runtimeConfiguration.incoming.artifactView {
                attributes { attribute(Attribute.of("artifactType", String::class.java), "android-classes-jar") }
            }.artifacts.resolvedArtifacts.map { s -> s.map { it.id } })
        }
        tasks.matching { it.name == "pre${cap}Build" }.configureEach { dependsOn(gate) }
        // the merged manifest exists only after process<Variant>MainManifest, so this one runs before package<Variant>
        // (APK) and package<Variant>Bundle (AAB)
        val manifestGate = tasks.register<ManifestGate>("check${cap}ManifestGate") {
            manifest.set(v.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            applicationId.set(v.applicationId)
            expected.set(expectedPermissions)
            exportable.set(exportedComponents)
            backupRules.from(fileTree("src") { include("*/res/xml*/data_extraction_rules.xml") })
            valueFiles.from(fileTree("src") { include("*/res/values*/*.xml") })
            domains.set(backupDomains)
            buildType.set(v.buildType ?: "")
            // what process<Variant>Resources linked: that task's declared outputs (binary format for an APK, proto for a
            // shrunk / bundle build), not a fixed intermediates path that could hold a stale .ap_
            linked.from(project.provider { project.tasks.getByName("process${cap}Resources").outputs.files })
            dependsOn("process${cap}Resources")
            aapt2.set(androidComponents.sdkComponents.sdkDirectory.map {
                it.file("build-tools/${android.buildToolsVersion}/aapt2" + if (System.getProperty("os.name").startsWith("Windows")) ".exe" else "")
            })
        }
        tasks.matching { it.name == "package${cap}" || it.name == "package${cap}Bundle" }.configureEach { dependsOn(manifestGate) }
        // a field build never carries the emulator's ABI (design §2: arm64-v8a only). Checked before packaging, not at
        // pre<Variant>Build: the shared configureCMakeDebug task pulls preFieldDebugBuild into a dev build too.
        val fieldWithEmulatorAbi = emulatorAbi && v.flavorName == "field"
        val abiGate = tasks.register("check${cap}EmulatorAbi") {
            doLast { if (fieldWithEmulatorAbi) throw GradleException("$name: -Pemulator-abi=true is not allowed in a field build") }
        }
        tasks.matching { it.name == "package${cap}" || it.name == "package${cap}Bundle" }.configureEach { dependsOn(abiGate) }
    }
}
