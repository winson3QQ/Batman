package dev.batman.batman_app

/**
 * design 254-app-s1 §4 (the root_password page is FLAG_SECURE): channel `dev.batman/secure`, method `set` with one
 * Boolean — true puts FLAG_SECURE on MainActivity's window (no screenshot, no screen recording, a blank Recents
 * thumbnail), false takes it off. Dart's SecureScreen widget (lib/secure_screen.dart) asks for it while a page that
 * shows a secret is up. Anything else is an error and leaves the flag as it is (no Flutter / Android here, so the JVM
 * tests run it).
 */
object SecureScreen {
    const val CHANNEL = "dev.batman/secure"

    /** the flag state a call asks for; null = not a call of this channel */
    fun wanted(method: String, arg: Any?): Boolean? = if (method == "set" && arg is Boolean) arg else null
}
