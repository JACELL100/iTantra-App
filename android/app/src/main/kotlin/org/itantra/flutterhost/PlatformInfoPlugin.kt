package org.itantra.flutterhost

import android.content.Context
import android.media.AudioManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android half of the capability probe. Answers on the same channel as the
 * Swift `PlatformInfoPlugin`, so Dart asks one question and adapts.
 *
 * Android is the stronger platform for this problem: the alarm stream can be
 * raised to a known level, Classic Bluetooth gives a real byte stream, and a
 * local-only hotspot can be created. All three are reported true here and
 * false on iOS, and the Dart layer degrades rather than pretending.
 */
class PlatformInfoPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    fun attach() {
        channel.setMethodCallHandler(this)
    }

    fun detach() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "platform" to "android",
                    "osVersion" to Build.VERSION.RELEASE,
                    "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
                    // STREAM_ALARM plus setStreamVolume: an alert can be made
                    // loud regardless of the media volume.
                    "canForceAlertVolume" to true,
                    // The alarm stream bypasses the ringer being silenced.
                    "alertIgnoresSilentSwitch" to true,
                    "supportsRfcommClassic" to true,
                    "supportsBleBridge" to true,
                    "supportsWifiTcp" to true,
                    // Wi-Fi Direct / local-only hotspot.
                    "canHostSoftAp" to true,
                    "backgroundAudioMode" to true,
                ),
            )

            "outputVolume" -> {
                val stream = AudioManager.STREAM_ALARM
                val max = audioManager.getStreamMaxVolume(stream)
                val current = audioManager.getStreamVolume(stream)
                result.success(
                    if (max <= 0) 0.0 else current.toDouble() / max.toDouble(),
                )
            }

            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "org.itantra/platform_info"
    }
}
