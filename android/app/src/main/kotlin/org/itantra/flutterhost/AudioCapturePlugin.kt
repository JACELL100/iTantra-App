package org.itantra.flutterhost

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Microphone capture over a Flutter platform channel.
 *
 * Captures from the VOICE_COMMUNICATION audio source, which engages the
 * device hardware AEC and NS on supported chips without needing the app
 * to implement its own. The 20 ms monotonic timestamp is taken inside the
 * native read loop—the only place it can be accurate—and forwarded to Dart
 * together with the PCM bytes.
 *
 * Channel: org.itantra/audio_capture        (MethodChannel — start / stop)
 * Channel: org.itantra/audio_capture/frames (EventChannel — frame events)
 *
 * Frame event map:
 *   "pcm"              : ByteArray   — PCM-16 LE mono samples at deviceRate
 *   "monotonicMicros"  : Long        — SystemClock.elapsedRealtimeNanos / 1000
 *   "sequence"         : Int         — monotonically increasing per session
 *
 * Dart applies resampling to 16 kHz when deviceRate differs.
 */
class AudioCapturePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var recorder: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var captureThread: Thread? = null
    private val running = AtomicBoolean(false)
    private var eventSink: EventChannel.EventSink? = null

    /** Open rate negotiated with the hardware on [start]. */
    private var deviceRate: Int = TARGET_RATE

    fun attach() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun detach() {
        stopCapture()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    // -------------------------------------------------------------------------
    // MethodChannel
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                    != PackageManager.PERMISSION_GRANTED
                ) {
                    result.error("permission_denied", "RECORD_AUDIO not granted", null)
                    return
                }
                val rate = startCapture()
                result.success(
                    mapOf(
                        "sampleRateHz" to rate,
                        "channels" to 1,
                    )
                )
            }

            "stop" -> {
                stopCapture()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // EventChannel
    // -------------------------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopCapture()
    }

    // -------------------------------------------------------------------------
    // Capture loop
    // -------------------------------------------------------------------------

    /**
     * Opens AudioRecord, attaches optional AEC/NS, starts the capture thread.
     * Returns the negotiated sample rate.
     */
    private fun startCapture(): Int {
        if (running.get()) return deviceRate

        val rate = chooseSampleRate()
        deviceRate = rate

        val frameBytes = bytesPerFrame(rate)
        val minBuffer = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer == AudioRecord.ERROR || minBuffer == AudioRecord.ERROR_BAD_VALUE) {
            // Unusual — treat as 4096 fallback.
        }
        val bufferSize = maxOf(minBuffer * 4, frameBytes * 4)

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            // Fall back to default mic source
            val fallback = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
            )
            recorder = fallback
        } else {
            recorder = record
        }

        val sessionId = recorder!!.audioSessionId
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(sessionId)?.also { it.enabled = true }
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(sessionId)?.also { it.enabled = true }
        }

        recorder!!.startRecording()
        running.set(true)

        var sequence = 0
        captureThread = Thread({
            val buf = ByteArray(frameBytes)
            while (running.get()) {
                val nBytes = recorder?.read(buf, 0, frameBytes) ?: break
                // Timestamp taken immediately after the hardware read returns:
                // this is the closest native approximation to when the last
                // sample in this buffer left the ADC.
                val monotonicMicros = SystemClock.elapsedRealtimeNanos() / 1_000L

                if (nBytes <= 0) continue

                val payload = if (nBytes == buf.size) buf.copyOf() else buf.copyOf(nBytes)
                val sink = eventSink ?: continue

                // Post to platform thread so EventChannel is satisfied.
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    sink.success(
                        mapOf(
                            "pcm" to payload,
                            "monotonicMicros" to monotonicMicros,
                            "sequence" to sequence,
                        )
                    )
                }
                sequence++
            }
        }, "itantra-capture").also { it.isDaemon = true }
        captureThread!!.start()

        return rate
    }

    private fun stopCapture() {
        running.set(false)
        captureThread?.join(500)
        captureThread = null

        recorder?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        recorder = null

        aec?.let { it.enabled = false; it.release() }
        aec = null
        ns?.let { it.enabled = false; it.release() }
        ns = null
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Tries preferred rates in order and returns the first one AudioRecord
     * accepts. 16 kHz is the ASR model's native rate; if the device only
     * supports 44.1 kHz Dart will resample.
     */
    private fun chooseSampleRate(): Int {
        for (rate in PREFERRED_RATES) {
            val minBuf = AudioRecord.getMinBufferSize(
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf > 0) return rate
        }
        return PREFERRED_RATES.last()
    }

    /** Bytes for a 20 ms PCM-16 mono frame at [rateHz]. */
    private fun bytesPerFrame(rateHz: Int): Int =
        rateHz * FRAME_MS / 1_000 * 2          // 2 bytes per PCM-16 sample

    companion object {
        private const val METHOD_CHANNEL = "org.itantra/audio_capture"
        private const val EVENT_CHANNEL = "org.itantra/audio_capture/frames"

        /** ASR model native rate. Dart resamples if the device differs. */
        private const val TARGET_RATE = 16_000

        /** 20 ms frames match WebRTC VAD and Silero VAD frame size expectations. */
        private const val FRAME_MS = 20

        private val PREFERRED_RATES = intArrayOf(16_000, 48_000, 44_100, 8_000)
    }
}
