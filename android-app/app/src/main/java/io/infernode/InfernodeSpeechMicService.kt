package io.infernode

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Microphone-typed foreground service for the remote-microphone
 * (`speech-export`) mode.
 *
 * Why this exists — the failure it fixes:
 *
 * Android silences an app's microphone the moment the app stops being
 * "in use". A visible Activity counts; a backgrounded one does not.
 * [InfernodeService]'s only foreground-service type is `dataSync`, which
 * does *not* authorize capture. So in `speech-export` mode the phone kept
 * serving 9P perfectly while AAudio handed out digital zeros — reads
 * succeeded at full rate, every sample was 0, and the Mac-side STT simply
 * never saw energy. A standardized acoustic fixture run therefore "timed
 * out" instead of failing: silence is indistinguishable from a quiet room.
 *
 * Measured on a physical Android 13 device: with the SDL activity visible,
 * capture is `not silenced` and the PCM is ~94% non-zero. Press HOME and
 * `dumpsys audio` flips the same recording session to `silenced` about a
 * second later; from that point the buffer is exactly zero.
 *
 * A `microphone`-typed foreground service is the platform's sanctioned way
 * to keep capture authorized once the Activity is no longer visible. It
 * must be started *while the app is still visible* — that is what converts
 * the Activity's while-in-use grant into one the service keeps holding.
 *
 * The service deliberately captures nothing itself. It only holds the
 * authorization (and the mandatory, user-visible ongoing notification) so
 * that emu's AAudio stream inside the Activity keeps receiving real
 * samples. Being a remote microphone is the entire point of this mode; the
 * persistent notification is the correct signal that the phone is live.
 */
class InfernodeSpeechMicService : Service() {

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startInForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Idempotent: re-issuing startForeground on an already-foregrounded
        // service just refreshes the notification. START_NOT_STICKY because
        // the mic grant is meaningless without the Activity that owns the
        // AAudio stream — Android must not resurrect us on its own.
        startInForeground()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Enter the foreground with the `microphone` type where the platform
     * has one. API 29 introduced typed `startForeground`; below that, the
     * background-capture restriction this guards against does not exist and
     * the untyped call is correct.
     */
    private fun startInForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan = NotificationChannel(
                CHAN_ID, "InferNode remote microphone", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps microphone capture authorized while exporting /dev over 9P"
            }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(chan)
        }
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHAN_ID)
            .setContentTitle("InferNode remote microphone")
            .setContentText("Microphone is exported over 9P")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()

    companion object {
        private const val TAG = "InfernodeSpeechMic"
        private const val CHAN_ID = "infernode.speechmic"
        private const val NOTIF_ID = 0x9F01

        /**
         * Start the service, but only when it can actually succeed.
         *
         * On API 34+ `startForeground` with the microphone type throws
         * unless RECORD_AUDIO is already granted, and the whole call is
         * pointless without it. Callers run this from a visible Activity;
         * failing here must degrade to "capture works while visible", never
         * to a crash on the phone.
         */
        fun start(context: Context) {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED
            ) {
                Log.w(TAG, "RECORD_AUDIO not granted; capture will be silenced when backgrounded")
                return
            }
            try {
                context.startForegroundService(Intent(context, InfernodeSpeechMicService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "could not hold the microphone in a foreground service", e)
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, InfernodeSpeechMicService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "could not stop the microphone foreground service", e)
            }
        }
    }
}
