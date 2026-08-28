package ge.geocharge.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Receiving a route shared out of the Google Maps app.
 *
 * Google Maps' "share directions" is a plain ACTION_SEND of text containing a
 * maps.app.goo.gl link, so appearing in that share sheet costs one intent
 * filter (see AndroidManifest.xml) and this handler. Reading the link is done
 * server-side — see functions/google-route.js.
 *
 * Deliberately not the receive_sharing_intent package: this is forty lines,
 * and the package has a history of breaking across Flutter versions.
 *
 * Two paths, because Android has two. A cold start delivers the share in the
 * launching intent, which Flutter is not listening for yet — so it is held and
 * handed over when Dart asks (`initialSharedText`). A warm one arrives at
 * onNewIntent, where Dart is already listening and is pushed to directly.
 */
class MainActivity : FlutterActivity() {
    private val channel = "ge.geocharge.app/share"
    private var pendingText: String? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        pendingText = sharedTextFrom(intent)

        methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        // Read once: a share already dealt with must not come
                        // back on the next resume.
                        "initialSharedText" -> {
                            result.success(pendingText)
                            pendingText = null
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedTextFrom(intent) ?: return
        // If Dart is not up yet the channel is null; hold it for the first read.
        if (methodChannel == null) pendingText = text
        else methodChannel?.invokeMethod("sharedText", text)
    }

    /** The shared text, when this intent is a text share and not a launch. */
    private fun sharedTextFrom(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type != "text/plain") return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
    }
}
