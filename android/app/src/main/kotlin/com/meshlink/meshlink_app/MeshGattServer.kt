package com.meshlink.meshlink_app

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Native BLE peripheral (GATT server) for MeshLink, bridged to Flutter over
 * the `meshlink/ble_peripheral` method channel — the Android counterpart of
 * ios/Runner/BleManager.swift, and the peripheral half flutter_blue_plus
 * (central-only) can't provide. Without it two Android devices can't link,
 * since neither can advertise a service for the other to connect to.
 *
 * The channel contract (must match BleManager.swift and the Dart handler in
 * lib/transport/ble_transport.dart):
 *   Dart → native:  start, stop, notify{centralId,data}, listCentrals
 *   native → Dart:  onWrite{centralId,data}, onSubscribe(id),
 *                   onUnsubscribe(id), onStateChanged(int)
 * centralId is the remote device's BLE address.
 *
 * All GATT server callbacks arrive on a binder thread; MethodChannel must be
 * invoked on the main thread, so every channel call and every access to the
 * shared subscription/queue state is posted to [main].
 */
class MeshGattServer(private val activity: Activity) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("4d455348-4c49-4e4b-0001-000000000001")
        val RX_CHAR_UUID: UUID = UUID.fromString("4d455348-4c49-4e4b-0002-000000000002")
        val TX_CHAR_UUID: UUID = UUID.fromString("4d455348-4c49-4e4b-0003-000000000003")
        // Standard Client Characteristic Configuration Descriptor.
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val CHANNEL = "meshlink/ble_peripheral"
        const val PERM_REQUEST = 0xB1E5
    }

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    private var gattServer: BluetoothGattServer? = null
    private var txChar: BluetoothGattCharacteristic? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var shouldAdvertise = false

    // Centrals that enabled TX notifications, keyed by device address.
    private val subscribed = mutableMapOf<String, BluetoothDevice>()
    // Negotiated ATT MTU per device (23 until onMtuChanged raises it).
    private val mtus = mutableMapOf<String, Int>()

    // Outbound notification queue. Android drops a notification if the
    // previous one hasn't been acknowledged (onNotificationSent), so chunks
    // are sent one at a time, next on the ready callback — same shape as
    // BleManager.swift's pendingNotifies.
    private val notifyQueue = ArrayDeque<Pair<BluetoothDevice, ByteArray>>()
    private var sending = false

    private val bluetoothManager: BluetoothManager
        get() = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

    fun attach(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL)
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> { start(); result.success(null) }
                "stop" -> { stop(); result.success(null) }
                "notify" -> {
                    val centralId = call.argument<String>("centralId")
                    val data = call.argument<ByteArray>("data")
                    if (centralId == null || data == null) {
                        result.error("bad_args", "notify needs centralId + data", null)
                    } else {
                        notify(centralId, data)
                        result.success(null)
                    }
                }
                "listCentrals" -> result.success(subscribed.keys.toList())
                else -> result.notImplemented()
            }
        }
    }

    // -- permissions --------------------------------------------------------

    private fun hasPerm(perm: String): Boolean =
        ActivityCompat.checkSelfPermission(activity, perm) == PackageManager.PERMISSION_GRANTED

    /** Runtime BLE permissions still missing (Android 12+ only). */
    private fun missingPerms(): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return emptyList()
        val need = mutableListOf<String>()
        if (!hasPerm(Manifest.permission.BLUETOOTH_ADVERTISE)) {
            need += Manifest.permission.BLUETOOTH_ADVERTISE
        }
        if (!hasPerm(Manifest.permission.BLUETOOTH_CONNECT)) {
            need += Manifest.permission.BLUETOOTH_CONNECT
        }
        return need
    }

    /** Forwarded from MainActivity.onRequestPermissionsResult. */
    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode == PERM_REQUEST && shouldAdvertise && missingPerms().isEmpty()) {
            openServerAndAdvertise()
        }
    }

    // -- lifecycle ----------------------------------------------------------

    private fun start() {
        shouldAdvertise = true
        // BLUETOOTH_ADVERTISE isn't requested by flutter_blue_plus (central
        // only), so the peripheral has to ask for it (and CONNECT, if the
        // scan hasn't already prompted for it) before touching the adapter.
        val missing = missingPerms()
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(activity, missing.toTypedArray(), PERM_REQUEST)
            return
        }
        openServerAndAdvertise()
    }

    private fun stop() {
        shouldAdvertise = false
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (_: SecurityException) {}
        advertiseCallback = null
        try {
            gattServer?.close()
        } catch (_: SecurityException) {}
        gattServer = null
        txChar = null
        subscribed.clear()
        mtus.clear()
        notifyQueue.clear()
        sending = false
    }

    private fun openServerAndAdvertise() {
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            main.post { channel?.invokeMethod("onStateChanged", 0) } // adapter off
            return
        }

        if (gattServer == null) {
            val server = try {
                bluetoothManager.openGattServer(activity, gattCallback)
            } catch (_: SecurityException) {
                return
            } ?: return
            gattServer = server

            val rx = BluetoothGattCharacteristic(
                RX_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            val tx = BluetoothGattCharacteristic(
                TX_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
            tx.addDescriptor(
                BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or
                        BluetoothGattDescriptor.PERMISSION_WRITE,
                ),
            )
            txChar = tx

            val service = BluetoothGattService(
                SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY,
            )
            service.addCharacteristic(rx)
            service.addCharacteristic(tx)
            try {
                server.addService(service)
            } catch (_: SecurityException) {
                return
            }
        }

        startAdvertising()
    }

    private fun startAdvertising() {
        val adv = bluetoothManager.adapter?.bluetoothLeAdvertiser ?: return
        advertiser = adv
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // The central scans filtered by the service UUID, so it must ride in
        // the advertisement itself (not the scan response). Device name is
        // omitted to leave room for the 128-bit UUID in the 31-byte packet.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val callback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                main.post { channel?.invokeMethod("onStateChanged", errorCode) }
            }
        }
        advertiseCallback = callback
        try {
            adv.startAdvertising(settings, data, callback)
        } catch (_: SecurityException) {}
    }

    // -- outbound notifications --------------------------------------------

    private fun notify(centralId: String, data: ByteArray) {
        val device = subscribed[centralId] ?: return
        // Fragment to the negotiated MTU (ATT header is 3 bytes). The peer
        // reassembles via the 2-byte length prefix, so chunk boundaries don't
        // matter — only that no single notification exceeds the MTU.
        val mtu = mtus[centralId] ?: 23
        val chunk = (mtu - 3).coerceIn(20, 244)
        var off = 0
        while (off < data.size) {
            val end = minOf(off + chunk, data.size)
            notifyQueue.addLast(device to data.copyOfRange(off, end))
            off = end
        }
        pumpNotify()
    }

    /** Sends the next queued chunk; the rest follow on onNotificationSent. */
    private fun pumpNotify() {
        if (sending) return
        val server = gattServer ?: return
        val tx = txChar ?: return
        val (device, slice) = notifyQueue.removeFirstOrNull() ?: return
        sending = true
        val ok = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                server.notifyCharacteristicChanged(device, tx, false, slice) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                tx.value = slice
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(device, tx, false)
            }
        } catch (_: SecurityException) {
            false
        }
        if (!ok) {
            // Couldn't queue (transmit buffer full / transient) — put it back
            // and retry shortly; there's no ready callback for a failed send.
            notifyQueue.addFirst(device to slice)
            sending = false
            main.postDelayed({ pumpNotify() }, 15)
        }
    }

    // -- GATT server callbacks (binder thread) ------------------------------

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val id = device.address
                main.post {
                    mtus.remove(id)
                    if (subscribed.remove(id) != null) {
                        channel?.invokeMethod("onUnsubscribe", id)
                    }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            val id = device.address
            main.post { mtus[id] = mtu }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val matched = characteristic.uuid == RX_CHAR_UUID
            if (matched && value != null) {
                val id = device.address
                main.post {
                    channel?.invokeMethod(
                        "onWrite", mapOf("centralId" to id, "data" to value),
                    )
                }
            }
            if (responseNeeded) {
                val statusCode =
                    if (matched) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE
                try {
                    gattServer?.sendResponse(device, requestId, statusCode, offset, null)
                } catch (_: SecurityException) {}
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (descriptor.uuid == CCCD_UUID && descriptor.characteristic.uuid == TX_CHAR_UUID) {
                // First byte set = notifications (0x01) or indications (0x02)
                // enabled; all-zero = disabled.
                val enabled = value != null && value.isNotEmpty() && value[0].toInt() != 0x00
                val id = device.address
                main.post {
                    if (enabled) {
                        subscribed[id] = device
                        channel?.invokeMethod("onSubscribe", id)
                    } else if (subscribed.remove(id) != null) {
                        channel?.invokeMethod("onUnsubscribe", id)
                    }
                }
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (_: SecurityException) {}
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                sending = false
                pumpNotify()
            }
        }
    }
}
