package org.itantra.flutterhost

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Host activity.
 *
 * The Dart side owns all of the logic; Kotlin exists only where Flutter has
 * no plugin-free access to the platform: raw PCM capture, a low-latency
 * AudioTrack with audio focus, the device's text-to-speech engine, Bluetooth
 * RFCOMM, and a foreground service. Keeping the native surface this small is
 * what makes the app portable and auditable.
 */
class MainActivity : FlutterActivity() {

    private lateinit var capture: AudioCapturePlugin
    private lateinit var playback: AudioPlaybackPlugin
    private lateinit var systemTts: SystemTtsPlugin
    private lateinit var rfcomm: RfcommChannel
    private lateinit var platformInfo: PlatformInfoPlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        capture = AudioCapturePlugin(this, messenger).also { it.attach() }
        playback = AudioPlaybackPlugin(this, messenger).also { it.attach() }
        systemTts = SystemTtsPlugin(this, messenger).also { it.attach() }
        rfcomm = RfcommChannel(this, messenger).also { it.attach() }
        platformInfo = PlatformInfoPlugin(this, messenger).also { it.attach() }
    }

    /**
     * True when this instance was created purely to service the notification's
     * Stop action.
     *
     * Such an instance must not start a session: the whole point of the action
     * is to end one, and starting the microphone in order to switch it off
     * would be worse than doing nothing.
     */
    private val isStopRequest: Boolean
        get() = intent?.action == SessionStopReceiver.ACTION_STOP_SESSION

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Pressing Stop when the app is not running at all.
        if (isStopRequest) finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Pressing Stop while the app is in the background. `finish` runs the
        // ordinary shutdown path, which disposes the engine and releases the
        // microphone - the same path the in-app disconnect uses, so there is
        // only one way for this app to stop listening and only one to test.
        if (intent.action == SessionStopReceiver.ACTION_STOP_SESSION) finish()
    }

    override fun onStart() {
        super.onStart()
        if (isStopRequest) return
        // Started on every foreground transition rather than once at launch:
        // Android kills the service when the task is swiped away, and a
        // walkie-talkie must keep listening with the screen off.
        startCommunicationService()
    }

    override fun onDestroy() {
        capture.detach()
        playback.detach()
        systemTts.detach()
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
