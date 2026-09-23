package org.itantra.flutterhost

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Streaming PCM playback with audio focus.
 *
 * Alerts are the reason this is native code. To be heard they must:
 *  - take exclusive audio focus, pausing whatever else is playing;
 *  - render on the ALARM stream, which ignores the ringer being silenced;
 *  - report the exact moment the first sample became audible, which is one
 *    end of the measured phone-to-phone delta.
 *
 * Ordinary messages use the same path with assistance usage and transient
 * focus, so a voice note does not stop someone's navigation prompt.
 */
class AudioPlaybackPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** Off the platform thread: draining polls, and polling on the UI thread
     *  would freeze the app for the length of the sentence tail. */
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var track: AudioTrack? = null
    private var focusRequest: AudioFocusRequest? = null
    private var sessionId: String? = null
    private var priority: String = "normal"
    private var reportedAudible = false
    private var previousVolume: Int? = null

    fun attach() {
        channel.setMethodCallHandler(this)
    }

    fun detach() {
        releaseTrack()
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val session = call.argument<String>("session")
                val requested = call.argument<String>("priority") ?: "normal"
                if (session == null) {
                    result.error("args", "session is required", null)
                    return
                }
                result.success(mapOf("granted" to start(session, requested)))
            }

            "write" -> {
                val session = call.argument<String>("session")
                val pcm = call.argument<ByteArray>("pcm")
                val rate = call.argument<Int>("sampleRateHz") ?: 22050
                val last = call.argument<Boolean>("last") ?: false
                if (session == null || pcm == null) {
                    result.error("args", "session and pcm are required", null)
                    return
                }
                if (session != sessionId) {
                    // A late write from a session that was pre-empted. Dropped
                    // rather than played, or an interrupted message would
                    // resume behind the alert that replaced it.
                    result.success(mapOf("audible" to 0L))
                    return
                }
                result.success(mapOf("audible" to write(pcm, rate, last)))
            }

            "drain" -> {
                // Blocks until the buffer is empty, which is exactly what the
                // microphone-reopen logic needs and exactly what must not
                // happen on the main thread.
                io.execute {
                    try {
                        drain()
                    } finally {
                        // The Flutter result may be invoked from any thread;
                        // posting it back keeps the reply ordered after the
                        // work rather than racing it.
                        main.post { result.success(null) }
                    }
                }
            }

            "stop" -> {
                releaseTrack()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun start(session: String, requested: String): Boolean {
        val isAlert = requested == "distress" || requested == "warning"

        // A distress alert pre-empts anything, including another alert. A
        // warning does not pre-empt a distress call in progress.
        if (track != null) {
            val outrankedByCurrent =
                priority == "distress" && requested != "distress"
            if (outrankedByCurrent) return false
            releaseTrack()
        }

        val usage = when (requested) {
            "distress" -> AudioAttributes.USAGE_ALARM
            "warning" -> AudioAttributes.USAGE_NOTIFICATION
            else -> AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY
        }

        val attributes = AudioAttributes.Builder()
            .setUsage(usage)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        val gain = if (isAlert) {
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
        } else {
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(gain)
                .setAudioAttributes(attributes)
                // Alerts must not be duckable: a distress message at 20%
                // volume under a music app is the same as no message.
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = request
            val granted = audioManager.requestAudioFocus(request)
            if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED && !isAlert) {
                // Ordinary messages defer politely; alerts play regardless,
                // because focus is advisory and safety is not.
                return false
            }
        }

        if (isAlert) raiseAlarmVolume(requested)

        sessionId = session
        priority = requested
        reportedAudible = false
        return true
    }

    /**
     * Raises the alarm stream for the duration of an alert, restoring the
     * previous level afterwards. Distress goes to maximum; a warning to 80%,
     * which is loud without being punitive for a non-emergency.
     */
    private fun raiseAlarmVolume(requested: String) {
        val stream = AudioManager.STREAM_ALARM
        val max = audioManager.getStreamMaxVolume(stream)
        previousVolume = audioManager.getStreamVolume(stream)
        val target = if (requested == "distress") max else (max * 0.8f).toInt()
        try {
            audioManager.setStreamVolume(stream, target, 0)
        } catch (_: SecurityException) {
            // Some OEM builds restrict this under Do Not Disturb. The alert
            // still plays at the current level.
        }
    }

    private fun ensureTrack(sampleRateHz: Int): AudioTrack {
        track?.let { if (it.sampleRate == sampleRateHz) return it }
        releaseTrackKeepingFocus()

        val usage = when (priority) {
            "distress" -> AudioAttributes.USAGE_ALARM
            "warning" -> AudioAttributes.USAGE_NOTIFICATION
            else -> AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY
        }

        val format = AudioFormat.Builder()
            .setSampleRate(sampleRateHz)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()

        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRateHz,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )

        val created = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(usage)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(format)
            // Two minimum buffers: enough to survive a scheduling gap,
            // small enough that the first chunk becomes audible quickly.
            .setBufferSizeInBytes(maxOf(minBuffer * 2, 8192))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        created.play()
        track = created
        return created
    }

    /**
     * Writes one chunk and reports when sound actually started.
     *
     * Returns the monotonic microphone-timestamp equivalent - the moment the
     * first samples were accepted by a track that is already playing - as
     * **microseconds**, or `0` for every write after the first. It must be an
     * integer: this value is the far end of the measured phone-to-phone
     * latency, and Dart reads it as one. Returning a boolean here, as an
     * earlier version did, made the Dart cast throw on the very first chunk of
     * every message.
     */
    private fun write(pcm: ByteArray, sampleRateHz: Int, last: Boolean): Long {
        val output = ensureTrack(sampleRateHz)
        var offset = 0
        while (offset < pcm.size) {
            val written = output.write(pcm, offset, pcm.size - offset)
            if (written <= 0) break
            offset += written
        }

        var audibleMicros = 0L
        if (!reportedAudible) {
            reportedAudible = true
            audibleMicros = SystemClock.elapsedRealtimeNanos() / 1_000L
        }
        // The Dart controller issues its own drain after the chunk stream ends.
        // Scheduling one here as well means the tail is still awaited if that
        // call is ever missed, and because it runs on the io executor rather
        // than the platform thread it cannot stall the UI. Two concurrent
        // drains are harmless: both are only waiting for the same playback
        // head position to catch up.
        if (last) io.execute { drain() }
        return audibleMicros
    }

    /** Blocks until the buffered audio has actually been rendered. */
    private fun drain() {
        val output = track ?: return
        // Poll rather than sleep on a computed duration: the head position is
        // ground truth, and a fixed sleep either truncates the tail of a word
        // or adds dead air.
        var stableFor = 0
        var previous = -1
        try {
            previous = output.playbackHeadPosition
            while (stableFor < 3) {
                SystemClock.sleep(20)
                val now = output.playbackHeadPosition
                if (now == previous) stableFor++ else stableFor = 0
                previous = now
            }
        } catch (_: IllegalStateException) {
            // The track was released under us - a stop arrived while draining.
            // Nothing to wait for.
        }
    }

    private fun releaseTrackKeepingFocus() {
        track?.let {
            try {
                it.pause()
                it.flush()
                it.stop()
            } catch (_: IllegalStateException) {
                // Track was never started; nothing to stop.
            }
            it.release()
        }
        track = null
    }

    private fun releaseTrack() {
        releaseTrackKeepingFocus()

        previousVolume?.let {
            try {
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, it, 0)
            } catch (_: SecurityException) {
                // Best effort; the user can always adjust it.
            }
        }
        previousVolume = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        }
        focusRequest = null
        sessionId = null
        priority = "normal"
        reportedAudible = false
    }

    companion object {
        private const val CHANNEL = "org.itantra/audio_playback"
    }
}
