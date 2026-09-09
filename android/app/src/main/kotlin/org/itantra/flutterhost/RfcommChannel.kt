package org.itantra.flutterhost

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Bluetooth Classic RFCOMM transport.
 *
 * RFCOMM rather than BLE GATT for phone-to-phone use: it gives an ordinary
 * reliable byte stream at a few hundred kbit/s, needs no MTU juggling, and
 * pairs with a UUID instead of a custom service definition. BLE is kept for
 * the embedded-bridge case only, where it is the only option.
 *
 * There is no framing here on purpose. Frames are built and parsed in Dart,
 * so the same framing code is exercised by unit tests and by the loopback
 * transport; this class only moves bytes.
 */
class RfcommChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENTS)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var serverSocket: BluetoothServerSocket? = null
    private var socket: BluetoothSocket? = null

    @Volatile
    private var reading = false

    fun attach() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    fun detach() {
        close()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!hasConnectPermission()) {
            result.error("permission", "BLUETOOTH_CONNECT not granted", null)
            return
        }

        when (call.method) {
            "listen" -> {
                startServer(result)
            }

            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("args", "address is required", null)
                    return
                }
                startClient(address, result)
            }

            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val active = socket
                if (bytes == null) {
                    result.error("args", "bytes is required", null)
                } else if (active == null || !active.isConnected) {
                    result.error("state", "not connected", null)
                } else {
                    try {
                        active.outputStream.write(bytes)
                        active.outputStream.flush()
                        result.success(null)
                    } catch (e: IOException) {
                        result.error("io", e.message, null)
                    }
                }
            }

            "close" -> {
                close()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun adapter(): BluetoothAdapter? {
        val manager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    private fun startServer(result: MethodChannel.Result) {
        val adapter = adapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("state", "Bluetooth is off", null)
            return
        }

        try {
            // Insecure: pairing and key agreement are handled by our own
            // short-authentication-string flow in Dart. Requiring a Bluetooth
            // PIN as well would add a second, confusing confirmation without
            // adding security we do not already have.
            val server = adapter.listenUsingInsecureRfcommWithServiceRecord(
                SERVICE_NAME,
                SERVICE_UUID,
            )
            serverSocket = server
            result.success(null)

            thread(name = "itantra-rfcomm-accept", isDaemon = true) {
                try {
                    val accepted = server.accept()
                    server.close()
                    serverSocket = null
                    onConnected(accepted)
                } catch (e: IOException) {
                    emitError(e.message ?: "accept failed")
                }
            }
        } catch (e: Exception) {
            result.error("listen", e.message, null)
        }
    }

    private fun startClient(address: String, result: MethodChannel.Result) {
        val adapter = adapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("state", "Bluetooth is off", null)
            return
        }

        try {
            val device: BluetoothDevice = adapter.getRemoteDevice(address)
            val client = device.createInsecureRfcommSocketToServiceRecord(
                SERVICE_UUID,
            )
            result.success(null)

            thread(name = "itantra-rfcomm-connect", isDaemon = true) {
                try {
                    client.connect()
                    onConnected(client)
                } catch (e: IOException) {
                    try {
                        client.close()
                    } catch (_: IOException) {
                        // Already closed.
                    }
                    emitError(e.message ?: "connect failed")
                }
            }
        } catch (e: Exception) {
            result.error("connect", e.message, null)
        }
    }

    private fun onConnected(connected: BluetoothSocket) {
        socket = connected
        reading = true

        val label = try {
            connected.remoteDevice?.name ?: "Bluetooth peer"
        } catch (_: SecurityException) {
            "Bluetooth peer"
        }

        mainHandler.post {
            sink?.success(mapOf("event" to "connected", "peer" to label))
        }

        thread(name = "itantra-rfcomm-read", isDaemon = true) {
            val buffer = ByteArray(READ_BUFFER)
            try {
                val stream = connected.inputStream
                while (reading) {
                    val read = stream.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    val chunk = buffer.copyOf(read)
                    mainHandler.post {
                        sink?.success(mapOf("event" to "data", "bytes" to chunk))
                    }
                }
                emitDisconnected("stream closed")
            } catch (e: IOException) {
                emitDisconnected(e.message ?: "read failed")
            }
        }
    }

    private fun emitError(message: String) {
        mainHandler.post {
            sink?.success(mapOf("event" to "error", "message" to message))
        }
    }

    private fun emitDisconnected(reason: String) {
        mainHandler.post {
            sink?.success(mapOf("event" to "disconnected", "reason" to reason))
        }
    }

    private fun close() {
        reading = false
        try {
            socket?.close()
        } catch (_: IOException) {
            // Nothing useful to do while tearing down.
        }
        socket = null
        try {
            serverSocket?.close()
        } catch (_: IOException) {
            // As above.
        }
        serverSocket = null
    }

    private fun hasConnectPermission(): Boolean {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.BLUETOOTH_CONNECT,
        ) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        private const val CHANNEL = "org.itantra/rfcomm"
        private const val EVENTS = "org.itantra/rfcomm/events"

        private const val SERVICE_NAME = "iTantra"

        /** Must match the UUID in the Dart transport. */
        private val SERVICE_UUID: UUID =
            UUID.fromString("6f1d9b30-4c8a-4a4e-9a0f-1b7c5d2e8a11")

        private const val READ_BUFFER = 4096
    }
}
