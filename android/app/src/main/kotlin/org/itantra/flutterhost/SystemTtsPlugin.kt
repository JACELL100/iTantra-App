package org.itantra.flutterhost

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/**
 * The device's own text-to-speech engine, behind `itantra/system_tts`.
 *
 * This exists so a fresh install can speak without downloading anything. The
 * app's own VITS packs are better voices, but "install 60 MB before your first
 * message" is not an answer for someone who needs to say something now, and
 * every Android device already has an engine and (usually) voice data for the
 * languages its owner uses.
 *
 * Offline by construction: [TextToSpeech] runs locally. The only caveat is that
 * the engine may offer to download voice data, which is the platform's business
 * and happens outside this app.
 *
 * Synthesis goes to a WAV file because `synthesizeToFile` is the only supported
 * offline API on Android. The Dart side decodes it and feeds the ordinary PCM
 * playback path, so a message spoken by the device voice takes exactly the same
 * route - and gets exactly the same latency measurement - as one spoken by a
 * model.
 */
class SystemTtsPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "itantra/system_tts")

    private val main = Handler(Looper.getMainLooper())

    private var tts: TextToSpeech? = null

    /** Set once the engine has finished starting. */
    @Volatile
    private var engineReady = false

    /** Synthesis calls waiting on the engine, keyed by utterance id. */
    private val pending = HashMap<String, MethodChannel.Result>()

    /** Fails a synthesis that never reports completion. */
    private val timeouts = HashMap<String, Runnable>()

    fun attach() {
        channel.setMethodCallHandler(this)

        tts = TextToSpeech(context.applicationContext) { status ->
            engineReady = status == TextToSpeech.SUCCESS
            if (engineReady) {
                tts?.setOnUtteranceProgressListener(progressListener)
            }
        }
    }

    fun detach() {
        channel.setMethodCallHandler(null)
        timeouts.values.forEach { main.removeCallbacks(it) }
        timeouts.clear()
        pending.clear()
        tts?.stop()
        tts?.shutdown()
        tts = null
        engineReady = false
    }

    private val progressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) = Unit

        override fun onDone(utteranceId: String?) {
            succeed(utteranceId)
        }

        @Deprecated("Required by the platform interface.")
        override fun onError(utteranceId: String?) {
            fail(utteranceId, "synthesis-failed", "the engine reported an error")
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            fail(
                utteranceId,
                "synthesis-failed",
                "the engine reported error $errorCode",
            )
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> probe(call, result)
            "prepare" -> prepare(call, result)
            "synthesize" -> synthesize(call, result)
            "stop" -> {
                tts?.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Reports whether a voice exists and, of the languages the app offers,
     * which ones this phone actually has data for.
     *
     * The candidate list comes from Dart so the answer is expressed in the same
     * BCP-47 tags the rest of the app uses. Without it the UI would have to
     * guess, and a guessed tag compares unequal to a real one.
     */
    private fun probe(call: MethodCall, result: MethodChannel.Result) {
        val engine = tts
        if (engine == null || !engineReady) {
            result.success(mapOf("available" to false, "languages" to emptyList<String>()))
            return
        }

        val candidates = call.argument<List<String>>("candidates") ?: emptyList()
        val usable = candidates.filter { tag ->
            // Negative results are LANG_MISSING_DATA and LANG_NOT_SUPPORTED;
            // zero and one mean available and available-with-country.
            engine.isLanguageAvailable(Locale.forLanguageTag(tag)) >= TextToSpeech.LANG_AVAILABLE
        }

        result.success(
            mapOf(
                "available" to true,
                "languages" to usable,
            ),
        )
    }

    private fun prepare(call: MethodCall, result: MethodChannel.Result) {
        val engine = tts
        if (engine == null || !engineReady) {
            result.error("unavailable", "no text-to-speech engine is running", null)
            return
        }

        val tag = call.argument<String>("languageTag") ?: "en-IN"
        val locale = Locale.forLanguageTag(tag)
        val availability = engine.isLanguageAvailable(locale)
        if (availability < TextToSpeech.LANG_AVAILABLE) {
            result.error(
                "missing-data",
                "this phone has no voice data for $tag",
                null,
            )
            return
        }

        engine.language = locale
        engine.setSpeechRate(1.0f)
        result.success(null)
    }

    private fun synthesize(call: MethodCall, result: MethodChannel.Result) {
        val engine = tts
        if (engine == null || !engineReady) {
            result.error("unavailable", "no text-to-speech engine is running", null)
            return
        }

        val text = call.argument<String>("text")?.trim().orEmpty()
        if (text.isEmpty()) {
            result.error("empty", "there is no text to speak", null)
            return
        }

        val tag = call.argument<String>("languageTag") ?: "en-IN"
        val rate = call.argument<Double>("rate") ?: 1.0
        val locale = Locale.forLanguageTag(tag)

        val availability = engine.isLanguageAvailable(locale)
        if (availability < TextToSpeech.LANG_AVAILABLE) {
            result.error(
                "missing-data",
                "this phone has no voice data for $tag. Install it in Android " +
                    "settings under Text-to-speech output, or install a voice pack.",
                null,
            )
            return
        }

        engine.language = locale
        engine.setSpeechRate(rate.coerceIn(0.25, 2.0).toFloat())

        // A file per utterance in the cache directory. The Dart side deletes it
        // as soon as it has been read, so this does not accumulate.
        val file = File(
            context.cacheDir,
            "itantra_tts_${System.currentTimeMillis()}.wav",
        )
        val utteranceId = "itantra-${System.nanoTime()}"

        pending[utteranceId] = result
        timeouts[utteranceId] = Runnable {
            pending.remove(utteranceId)?.let {
                it.error("timeout", "the device voice did not finish in time", null)
            }
        }.also { main.postDelayed(it, SYNTHESIS_TIMEOUT_MS) }

        val params = Bundle()
        val outcome = engine.synthesizeToFile(text, params, file, utteranceId)
        if (outcome != TextToSpeech.SUCCESS) {
            clear(utteranceId)
            file.delete()
            result.error("failed", "the device voice could not start speaking", null)
        }
    }

    private fun succeed(utteranceId: String?) {
        val id = utteranceId ?: return
        val callback = clear(id) ?: return
        // The newest file in the cache is the one this utterance just wrote.
        // The platform's own callback does not carry the path on every
        // version, so it is found rather than received. Playback is serialised
        // by the session, so two syntheses never overlap.
        val newest = context.cacheDir
            .listFiles { f -> f.name.startsWith(FILE_PREFIX) }
            ?.maxByOrNull { it.lastModified() }

        main.post {
            if (newest == null || !newest.exists()) {
                callback.error("empty", "the device voice produced no audio", null)
            } else {
                callback.success(mapOf("path" to newest.absolutePath))
            }
        }
    }

    private fun fail(utteranceId: String?, code: String, message: String) {
        val id = utteranceId ?: return
        val callback = clear(id) ?: return
        main.post { callback.error(code, message, null) }
    }

    private fun clear(utteranceId: String): MethodChannel.Result? {
        timeouts.remove(utteranceId)?.let { main.removeCallbacks(it) }
        return pending.remove(utteranceId)
    }

    private companion object {
        const val FILE_PREFIX = "itantra_tts_"
        const val SYNTHESIS_TIMEOUT_MS = 20_000L
    }
}
