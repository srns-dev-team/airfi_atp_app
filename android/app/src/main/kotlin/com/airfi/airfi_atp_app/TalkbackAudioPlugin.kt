package com.airfi.airfi_atp_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.concurrent.thread

/// Android side of the `com.airfi.talkback/audio` MethodChannel — full-duplex
/// intercom. Mirrors the iOS TalkbackAudioPlugin contract.
///
/// Dart wire format is Int16 PCM, 8 kHz mono (G.711A conversion happens in
/// Dart). Capture uses VOICE_COMMUNICATION source so the platform applies HW
/// AEC/AGC/NS; AcousticEchoCanceler + NoiseSuppressor are also attached when
/// available. The capture thread runs continuously once started; the
/// `isRecording` flag only gates whether frames are forwarded to Dart, so
/// toggling talk never restarts the device (no route churn).
class TalkbackAudioPlugin(messenger: io.flutter.plugin.common.BinaryMessenger, private val context: Context) :
    MethodCallHandler {

    private val channel = MethodChannel(messenger, "com.airfi.talkback/audio")
    private val main = Handler(Looper.getMainLooper())

    private var sampleRate = 8000
    private var channelCount = 1

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null

    @Volatile private var isRecording = false        // gates forwarding to Dart
    @Volatile private var captureRunning = false     // capture thread alive
    private var captureThread: Thread? = null
    private var tapFireCount = 0
    private var playbackVolume = 1.0f

    init {
        channel.setMethodCallHandler(this)
    }

    fun release() {
        releaseAudio()
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                val sr = (call.argument<Int>("sampleRate")) ?: 8000
                val ch = (call.argument<Int>("channels")) ?: 1
                val reason = initializeAudio(sr, ch)
                if (reason != null) result.error("INIT_FAILED", reason, null) else result.success(true)
            }
            "startRecording" -> result.success(startRecording())
            "stopRecording" -> result.success(stopRecording())
            "playAudio" -> {
                val data = call.argument<ByteArray>("audioData")
                result.success(playAudio(data))
            }
            "stopPlayback" -> result.success(true)
            "setVolume" -> {
                val v = call.argument<Int>("volume") ?: 100
                result.success(setVolume(v))
            }
            "enableSpeaker" -> {
                val e = call.argument<Boolean>("enable") ?: true
                result.success(enableSpeaker(e))
            }
            "release" -> { releaseAudio(); result.success(true) }
            else -> result.notImplemented()
        }
    }

    // MARK: - Lifecycle

    /// Returns null on success, else a human-readable reason (surfaced to Dart
    /// as a FlutterError so the in-app error shows the real cause).
    private fun initializeAudio(sr: Int, ch: Int): String? {
        releaseAudio()
        sampleRate = if (sr > 0) sr else 8000
        channelCount = if (ch >= 2) 2 else 1

        // Route audio through the voice-comm path (earpiece/speaker + AEC).
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.mode = AudioManager.MODE_IN_COMMUNICATION

        val inChannel = if (channelCount == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val minIn = AudioRecord.getMinBufferSize(sampleRate, inChannel, AudioFormat.ENCODING_PCM_16BIT)
        if (minIn <= 0) return "AudioRecord.getMinBufferSize failed ($minIn)"
        val recBuf = maxOf(minIn, sampleRate * channelCount * 2 / 5) // ~200ms

        val r = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                sampleRate, inChannel, AudioFormat.ENCODING_PCM_16BIT, recBuf
            )
        } catch (e: Exception) {
            return "AudioRecord ctor: ${e.message}"
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return "AudioRecord uninitialized (mic permission?)"
        }
        record = r

        // Best-effort HW effects keyed on the record session id.
        try {
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(r.audioSessionId)?.apply { enabled = true }
            }
            if (NoiseSuppressor.isAvailable()) {
                ns = NoiseSuppressor.create(r.audioSessionId)?.apply { enabled = true }
            }
        } catch (e: Exception) {
            diag("audiofx attach failed (continuing): ${e.message}")
        }

        // Playback track (voice-comm usage → same route as capture, AEC-friendly).
        val outChannel = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minOut = AudioTrack.getMinBufferSize(sampleRate, outChannel, AudioFormat.ENCODING_PCM_16BIT)
        if (minOut <= 0) return "AudioTrack.getMinBufferSize failed ($minOut)"
        val outBuf = maxOf(minOut, sampleRate * channelCount * 2 / 5)
        val t = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(outChannel)
                        .build()
                )
                .setBufferSizeInBytes(outBuf)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Exception) {
            return "AudioTrack ctor: ${e.message}"
        }
        track = t
        t.setVolume(playbackVolume)
        t.play()

        // Speaker on by default (matches iOS defaultToSpeaker).
        enableSpeaker(true)

        // Start continuous capture immediately; forwarding gated by isRecording.
        startCaptureThread()
        diag("initialized sr=$sampleRate ch=$channelCount aec=${aec != null} ns=${ns != null}")
        return null
    }

    private fun startCaptureThread() {
        val r = record ?: return
        if (captureRunning) return
        captureRunning = true
        tapFireCount = 0
        r.startRecording()
        captureThread = thread(name = "tb-capture", isDaemon = true) {
            val buf = ByteArray(sampleRate * channelCount * 2 / 25) // ~40ms
            while (captureRunning) {
                val n = try { r.read(buf, 0, buf.size) } catch (e: Exception) { -1 }
                if (n <= 0) continue
                if (tapFireCount < 3) {
                    tapFireCount++
                    val c = tapFireCount
                    main.post { channel.invokeMethod("tbDiag", "TAP FIRED #$c frames=${n / 2}") }
                }
                if (!isRecording) continue // captured but not transmitting
                val chunk = buf.copyOf(n)
                main.post { channel.invokeMethod("onAudioChunk", chunk) }
            }
        }
    }

    private fun releaseAudio() {
        captureRunning = false
        isRecording = false
        captureThread?.let { try { it.join(300) } catch (_: InterruptedException) {} }
        captureThread = null
        record?.let {
            try { if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) it.stop() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        record = null
        aec?.let { try { it.release() } catch (_: Exception) {} }; aec = null
        ns?.let { try { it.release() } catch (_: Exception) {} }; ns = null
        track?.let {
            try { it.pause(); it.flush(); it.stop() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        track = null
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {}
    }

    // MARK: - Recording (capture thread always runs; flag gates forwarding)

    private fun startRecording(): Boolean {
        // Self-heal: capture may have been torn down between initialize() and the
        // first talk press. Re-arm rather than fail with tx=false.
        if (record == null) {
            diag("startRecording: not initialized")
            return false
        }
        if (!captureRunning) startCaptureThread()
        isRecording = true
        diag("startRecording OK captureRunning=$captureRunning")
        return true
    }

    private fun stopRecording(): Boolean {
        isRecording = false
        return true
    }

    // MARK: - Playback

    private fun playAudio(data: ByteArray?): Boolean {
        val t = track ?: return false
        if (data == null || data.isEmpty()) return false
        return try {
            if (t.playState != AudioTrack.PLAYSTATE_PLAYING) t.play()
            val written = t.write(data, 0, data.size)
            written >= 0
        } catch (e: Exception) {
            diag("playAudio: ${e.message}")
            false
        }
    }

    private fun setVolume(v: Int): Boolean {
        playbackVolume = (v.coerceIn(0, 100)).toFloat() / 100.0f
        return try { track?.setVolume(playbackVolume); true } catch (_: Exception) { false }
    }

    private fun enableSpeaker(on: Boolean): Boolean {
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = on
            true
        } catch (_: Exception) { false }
    }

    private fun diag(s: String) {
        android.util.Log.i("Talkback", s)
        main.post { channel.invokeMethod("tbDiag", s) }
    }
}
