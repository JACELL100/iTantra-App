package org.itantra.flutterhost

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Host activity.
 *
 * The Dart side owns all of the logic; Kotlin exists only where Flutter has
 * no plugin-free access to the platform: raw PCM capture, a low-latency
 * AudioTrack with audio focus, Bluetooth RFCOMM, and a foreground service.
 * Keeping the native surface this small is what makes the app portable and
 * auditable.
 */
class MainActivity : FlutterActivity() {

    private lateinit var capture: AudioCapturePlugin
    private lateinit var playback: AudioPlaybackPlugin
    private lateinit var rfcomm: RfcommChannel
    private lateinit var platformInfo: PlatformInfoPlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        capture = AudioCapturePlugin(this, messenger).also { it.attach() }
        playback = AudioPlaybackPlugin(this, messenger).also { it.attach() }
        rfcomm = RfcommChannel(this, messenger).also { it.attach() }
        platformInfo = PlatformInfoPlugin(this, messenger).also { it.attach() }
    }

    override fun onStart() {
        super.onStart()
        // Started on every foreground transition rather than once at launch:
        // Android kills the service when the task is swiped away, and a
        // walkie-talkie must keep listening with the screen off.
        startCommunicationService()
    }

    override fun onDestroy() {
        capture.detach()
        playback.detach()
        rfcomm.detach()
        platformInfo.detach()
        stopService(Intent(this, CommunicationService::class.java))
        super.onDestroy()
    }

    private fun startCommunicationService() {
        val intent = Intent(this, CommunicationService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
