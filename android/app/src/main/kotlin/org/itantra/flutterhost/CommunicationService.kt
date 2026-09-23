package org.itantra.flutterhost

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.app.Service
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the voice link alive when the app is not in the foreground.
 *
 * Without a foreground service Android freezes the process seconds after the
 * screen turns off, and a walkie-talkie that stops working in a pocket is
 * worthless. The service is typed `microphone`, which is mandatory from
 * Android 14 for anything that records while backgrounded, and it carries a
 * notification that explains plainly why the microphone indicator is lit -
 * users are entitled to know, and an unexplained indicator is what makes
 * people uninstall.
 */
class CommunicationService : Service() {

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Not sticky: if the system kills us under memory pressure, silently
        // resurrecting a microphone service without the user reopening the
        // app would be the wrong default.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager =
            getSystemService(NotificationManager::class.java) ?: return

        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel_name),
            // Low importance: this notification is a disclosure, not an
            // interruption. Alerts get loud through the audio path instead.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.service_channel_description)
            setShowBadge(false)
        }

        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // A disclosure the user cannot act on is only half a disclosure. The
        // Stop action finishes the activity, which tears the session down
        // through the same path the in-app disconnect uses.
        val stop = PendingIntent.getBroadcast(
            this,
            1,
            Intent(this, SessionStopReceiver::class.java).apply {
                action = SessionStopReceiver.ACTION_STOP_SESSION
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(getString(R.string.service_title))
            .setContentText(getString(R.string.service_text))
            // Our own monochrome glyph rather than a framework drawable: the
            // status bar is where a user checks whether an app is listening to
            // them, so it should show this app's mark and not a generic one
            // that three other apps also use.
            .setSmallIcon(R.drawable.ic_stat_itantra)
            .setContentIntent(open)
            .setOngoing(true)
            // Deliberately the only action. The notification's job is to say
            // "the microphone is live" and to offer a way out of that, not to
            // become a control panel.
            .addAction(
                0,
                getString(R.string.service_stop_action),
                stop,
            )
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "itantra_voice_link"
        private const val NOTIFICATION_ID = 4711
    }
}
