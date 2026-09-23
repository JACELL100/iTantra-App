package org.itantra.flutterhost

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.max

/**
 * Raw microphone capture, framed and timestamped on the native side.
 *
 * Exists for three reasons that Dart alone cannot cover:
 *
 *  - **A monotonic timestamp taken where the samples are read.** The capture
 *    time is one end of the measured phone-to-phone latency. Reading the clock
 *    after the buffer has crossed the platform channel would fold Dart's
 *    scheduler jitter - tens of milliseconds on a busy handset - into a number
 *    the brief scores, which would make the measurement meaningless.
 *
 *  - **A source that is not tuned for phone calls.** `VOICE_RECOGNITION`
 *    disables the automatic gain control, the noise suppressor and the echo
 *    canceller. Those help a human listener and actively harm an acoustic
 *    model: AGC pumps the noise floor between words, which is exactly where a
 *    voice-activity detector makes its decision.
 *
 *  - **20 ms frames at a fixed size.** The whole pipeline is sized around this
 *    frame, and a fixed frame means the resampler state, the VAD window and the
 *    endpointer can all be reasoned about in samples rather than in wall clock.
 *
 * Capture runs at the device's native rate and is resampled to 16 kHz in Dart,
 * because the recogniser is trained at 16 kHz and resampling once, in one
 * place, is easier to keep correct than teaching every device to open at 16.
 */
class AudioCapturePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)

    private val main = Handler(Looper.getMainLooper())
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var record: AudioRecord? = null
    private var job: Job? = null
    private var sink: EventChannel.EventSink? = null

    /** What was actually opened, which is not always what was asked for. */
    private var sampleRateHz = DEFAULT_SAMPLE_RATE_HZ
    private var channelCount = 1

    fun attach() {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun detach() {
        teardown()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    // -------------------------------------------------------------------------
    // Method channel
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val opened = start()
                if (opened == null) {
                    result.error(
                        "capture",
                        "The microphone could not be opened on this device.",
                        null,
                    )
                    return
                }
                result.success(
                    mapOf(
                        "sampleRateHz" to sampleRateHz,
                        "channels" to channelCount,
                    ),
                )
            }

            "stop" -> {
                teardown()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Event channel
    // -------------------------------------------------------------------------

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        // The subscription and the method call arrive in either order, so a
        // stream that is already open is adopted rather than restarted: two
        // AudioRecords on one microphone is undefined behaviour on most
        // devices.
        if (record == null) start()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        teardown()
    }

    // -------------------------------------------------------------------------
    // Capture
    // -------------------------------------------------------------------------

    /**
     * Opens the microphone, or returns null having posted a readable reason.
     *
     * Returns the successful recording so the caller can report the real
     * configuration: the recogniser has to know the rate it is being fed, and
     * guessing 16 kHz on a device that refused it would silently degrade every
     * transcript.
     */
    private fun start(): AudioRecord? {
        if (record != null) return record

        if (ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            // Reached when the permission prompt has not been answered yet.
            // Reported rather than thrown, because the caller can ask and then
            // retry on the next press.
            postError("permission", "Microphone permission has not been granted.")
            return null
        }

        val opened = openRecorder()
        if (opened == null) {
            postError("capture", "No supported microphone configuration on this device.")
            return null
        }

        record = opened
        val frameBytes = frameSizeBytes(sampleRateHz, channelCount)

        job = scope.launch {
            val buffer = ByteArray(frameBytes)
            try {
                opened.startRecording()
            } catch (_: IllegalStateException) {
                // Throws rather than returning a status code. Reached when the
                // recorder was initialised but the microphone was taken by
                // something else in the meantime, which the user can usually
                // fix by closing the other app.
                postError("capture", "The microphone is in use by another app.")
                releaseQuietly(opened)
                return@launch
            }

            // A transient read failure is normal when audio focus changes
            // hands. A run of them is not, and re-looping forever on a dead
            // recorder would hold the microphone open while delivering
            // nothing, so the streak is bounded.
            var consecutiveFailures = 0

            while (isActive) {
                val read = try {
                    opened.read(buffer, 0, frameBytes, AudioRecord.READ_BLOCKING)
                } catch (_: IllegalStateException) {
                    AudioRecord.ERROR_INVALID_OPERATION
                }

                if (read <= 0) {
                    if (read == AudioRecord.ERROR_INVALID_OPERATION &&
                        ++consecutiveFailures < MAX_CONSECUTIVE_FAILURES
                    ) {
                        continue
                    }
                    if (read == AudioRecord.ERROR_INVALID_OPERATION) {
                        postError(
                            "capture",
                            "The microphone stopped delivering audio.",
                        )
                    } else {
                        postError("capture", "The microphone is unavailable.")
                    }
                    break
                }
                consecutiveFailures = 0

                // The clock is read here, immediately after the read returns,
                // so the timestamp describes the buffer rather than how long
                // Dart took to reach it. elapsedRealtimeNanos is the monotonic
                // clock Android guarantees to be comparable across threads and
                // unaffected by the user changing the wall clock mid-session.
                val micros = SystemClock.elapsedRealtimeNanos() / 1_000L

                // Always a copy, even when the read filled the buffer exactly.
                // The map is queued to the main thread and encoded some time
                // later, so handing over the reusable buffer would let the next
                // read overwrite audio that had not been serialised yet - a
                // corruption that would appear only under load, and would look
                // like an intermittent recognition failure rather than a bug.
                val pcm = buffer.copyOf(read)

                main.post {
                    sink?.success(
                        mapOf(
                            "pcm" to pcm,
                            "monotonicMicros" to micros,
                        ),
                    )
                }
            }

            releaseQuietly(opened)
        }

        return opened
    }

    /**
     * Tries the best available source and rate, in order of preference.
     *
     * Every step down is a real trade, and the order is not the obvious one:
     *
     *  - `VOICE_RECOGNITION` comes first despite `UNPROCESSED` being purer.
     *    `UNPROCESSED` is documented as unsupported on many devices and has a
     *    well-known failure mode where it initialises successfully and then
     *    delivers silence - which would be indistinguishable, from the app's
     *    side, from a user who is not speaking. A recogniser fed confidence in
     *    the wrong source is worse than one fed slightly processed audio.
     *  - `UNPROCESSED` is still tried before `MIC`, because on a device that
     *    supports it properly it is the best possible input: no gain control
     *    pumping the noise floor between words.
     *  - `MIC` and `DEFAULT` are the compatibility floor. They may apply AGC
     *    and noise suppression, which costs some accuracy, but they always
     *    exist.
     *
     * An `AudioRecord` reports its failure through `getState()` rather than by
     * throwing, so each candidate is built, checked, and released before the
     * next is tried.
     */
    private fun openRecorder(): AudioRecord? {
        val sources = intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.UNPROCESSED,
            MediaRecorder.AudioSource.MIC,
            MediaRecorder.AudioSource.DEFAULT,
        )

        // 16 kHz is what the recogniser wants; 44.1 kHz is the near-universal
        // fallback and is resampled in Dart.
        val rates = intArrayOf(DEFAULT_SAMPLE_RATE_HZ, 44100)

        for (rate in rates) {
            for (source in sources) {
                val attempt = build(rate, source)
                if (attempt != null) {
                    sampleRateHz = rate
                    channelCount = 1
                    return attempt
                }
            }
        }
        return null
    }

    private fun build(rate: Int, source: Int): AudioRecord? {
        val minBuffer = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return null

        // Four frames of headroom: enough to ride out a scheduling gap without
        // the driver dropping samples, small enough that the input path stays
        // short and stop() is immediate. This buffer size is the only
        // low-latency lever public API leaves an app - the
        // PERFORMANCE_MODE_LOW_LATENCY flag on AudioRecord.Builder is system
        // API and unavailable here.
        val wanted = max(minBuffer, frameSizeBytes(rate, 1) * 4)

        val attempt = try {
            AudioRecord.Builder()
                .setAudioSource(source)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(wanted)
                .build()
        } catch (_: Throwable) {
            // Builder throws IllegalArgumentException or UnsupportedOperation
            // for a combination the device does not implement.
            return null
        }

        if (attempt.state == AudioRecord.STATE_INITIALIZED) return attempt

        releaseQuietly(attempt)
        return null
    }

    /** Bytes in one 20 ms frame at [rate] with [channels] channels. */
    private fun frameSizeBytes(rate: Int, channels: Int): Int {
        val samples = rate * FRAME_MILLIS / 1000
        // Always an even number of samples so a frame never splits a sample.
        val evenSamples = if (samples % 2 == 0) samples else samples + 1
        return evenSamples * channels * 2
    }

    private fun teardown() {
        job?.cancel()
        job = null
        record?.let { releaseQuietly(it) }
        record = null
        // A fresh scope each time: a cancelled scope cannot launch again, and
        // the next press has to be able to start a new capture.
        scope.cancel()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    private fun releaseQuietly(target: AudioRecord) {
        try {
            if (target.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                target.stop()
            }
        } catch (_: IllegalStateException) {
            // Already stopped; nothing to unwind.
        }
        try {
            target.release()
        } catch (_: IllegalStateException) {
            // Release is idempotent in practice but is documented to throw if
            // the object was never initialised.
        }
    }

    private fun postError(code: String, message: String) {
        main.post {
            sink?.error(code, message, null)
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "org.itantra/audio_capture"
        private const val EVENT_CHANNEL = "org.itantra/audio_capture/frames"

        /** The rate the recogniser is trained at. */
        private const val DEFAULT_SAMPLE_RATE_HZ = 16000

        /** Frame length the whole pipeline is sized around. */
        const val FRAME_MILLIS = 20

        /**
         * How many consecutive failed reads are tolerated before capture is
         * declared dead. At 20 ms per attempt this is about a quarter second,
         * which is longer than any legitimate focus transition and far shorter
         * than a user would wait before deciding the button does not work.
         */
        private const val MAX_CONSECUTIVE_FAILURES = 12
    }
}
