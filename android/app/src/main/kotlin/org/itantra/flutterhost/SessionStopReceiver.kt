package org.itantra.flutterhost

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The notification's Stop action.
 *
 * This exists because the persistent notification is the one place a user can
 * see that the microphone is live without opening the app, and a disclosure
 * that cannot be acted on is only half a disclosure. A phone in a pocket with a
 * lit microphone indicator and no way to stop it from the shade is exactly the
 * situation that makes people uninstall a recording app.
 *
 * Stopping has to mean *stopping*, so it does two things in order:
 *
 *  1. Sends [Intent.ACTION_STOP_SESSION] to the activity, which finishes it.
 *     Finishing the activity disposes the Flutter engine, which tears down the
 *     session and releases the microphone through the normal shutdown path -
 *     the same path the in-app disconnect uses, so there is no second, less
 *     tested way for the app to go quiet.
 *  2. Stops the foreground service, which removes the notification.
 *
 * Doing it in that order matters: stopping the service first would leave the
 * engine alive for the moment it takes the activity to finish, and the
 * microphone would stay open with no notification to say so.
 */
class SessionStopReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_STOP_SESSION) return

        // Explicit intent: the activity is in this package and must not be
        // reachable from anywhere else.
        val stop = Intent(context, MainActivity::class.java).apply {
            action = ACTION_STOP_SESSION
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(stop)

        context.stopService(Intent(context, CommunicationService::class.java))
    }

    companion object {
        /**
         * Package-scoped so a third-party app cannot stop this one's session.
         * The receiver is also declared `exported="false"`; both are belt and
         * braces, and both are cheap.
         */
        const val ACTION_STOP_SESSION = "org.itantra.flutterhost.STOP_SESSION"
    }
}
