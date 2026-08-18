// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Flutter plumbing, pigeon host API, and the GATT/receiver callbacks — the controller.

package com.lib.bluebird

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

class BluebirdPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener,
    BluebirdHostApi {

    companion object {
        private const val TAG = "[Bluebird-Android]"
        private val CCCD = Uuid.CLIENT_CHARACTERISTIC_CONFIGURATION_DESCRIPTOR
        private const val ENABLE_BLUETOOTH_REQUEST_CODE = 13106

        // random number defined by bluebird.
        private const val USER_CANCELED_ERROR_CODE = 23789258L
    }

    private var logLevel = LogLevel.DEBUG

    private var context: Context? = null
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val permissions = Permissions()

    /** Runs the pigeon host methods; recreated on every engine attach. */
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** Connection map + the lock guarding all pending-operation slots. */
    private val registry = ConnectionRegistry()

    private val scanner = Scanner(::log, ::emitEvent)

    /** Owns the L2CAP data channel + open channels; created on engine attach. */
    private var l2capManager: L2capManager? = null

    // In-flight ops that cannot live on a DeviceConnection slot:
    //  - pendingTurnOn: the single system "enable Bluetooth" dialog;
    //    resumed by onActivityResult. Not tied to any device.
    //  - pendingRemoveBond: removeBond is the one op that legally runs
    //    without a connection (bonds outlive connections), so it is keyed
    //    by address here; resumed by the bond state receiver.
    // Both are mutated under the registry lock, like the DeviceConnection slots.
    private var pendingTurnOn: CancellableContinuation<Boolean>? = null
    private val pendingRemoveBond = HashMap<String, CancellableContinuation<Boolean>>()

    private val bondingDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val bondingPins = ConcurrentHashMap<String, ByteArray>()

    private var sink: PigeonEventSink<BmEvent>? = null

    private val streamHandler = object : NativeEventsStreamHandler() {
        override fun onListen(p0: Any?, sink: PigeonEventSink<BmEvent>) {
            this@BluebirdPlugin.sink = sink
        }

        override fun onCancel(p0: Any?) {
            this@BluebirdPlugin.sink = null
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // helpers

    private fun log(level: LogLevel, message: String) {
        if (level.raw > logLevel.raw) {
            return
        }
        when (level) {
            LogLevel.WARNING -> Log.w(TAG, "[Bluebird] $message")
            LogLevel.ERROR -> Log.e(TAG, "[Bluebird] $message")
            else -> Log.d(TAG, "[Bluebird] $message")
        }
    }

    /** Emits [event] on the main thread. */
    private fun emitEvent(event: BmEvent) {
        mainHandler.post {
            val s = sink
            if (s != null) {
                s.success(event)
            } else {
                log(LogLevel.WARNING, "emitEvent: no event sink attached: $event")
            }
        }
    }

    /**
     * Runs [block] and completes [callback] at the end — errors become
     * Result.failure, cancellation (hot restart/detach) drops the callback
     * without invoking it. Logs [name] on entry and any failure on the way
     * out, so host-method bodies need no logging of their own.
     */
    private fun <T> launch(name: String, callback: (Result<T>) -> Unit, block: suspend () -> T) {
        scope.launch {
            log(LogLevel.DEBUG, name)
            val result = try {
                Result.success(block())
            } catch (e: CancellationException) {
                return@launch
            } catch (e: Throwable) {
                val error = e as? FlutterError
                    ?: FlutterError(BluebirdErrorCode.PLATFORM.wire, e.toString(), null)
                log(LogLevel.ERROR, "$name failed: ${error.code} ${error.message}")
                Result.failure(error)
            }
            callback(result)
        }
    }

    /** Lazily initializes and returns the adapter, mirroring the Java plugin. */
    private fun adapter(): BluetoothAdapter? {
        if (bluetoothAdapter == null) {
            log(LogLevel.DEBUG, "initializing BluetoothAdapter")
            bluetoothManager = context?.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
            bluetoothAdapter = bluetoothManager?.adapter
        }
        return bluetoothAdapter
    }

    private fun bluetoothUnavailable() =
        FlutterError(BluebirdErrorCode.UNSUPPORTED.wire, "the device does not support bluetooth", null)

    private fun requireAdapter(): BluetoothAdapter = adapter() ?: throw bluetoothUnavailable()

    private fun isAdapterOn(): Boolean {
        // get adapterState, if we have permission
        return try {
            adapter()?.state == BluetoothAdapter.STATE_ON
        } catch (e: Exception) {
            false
        }
    }

    private fun requireAdapterOn() {
        if (!isAdapterOn()) {
            throw FlutterError(BluebirdErrorCode.ADAPTER_OFF.wire, "Bluetooth must be turned on", null)
        }
    }

    /** Throws a [FlutterError] with [code] and [message] when [value] is false. */
    private inline fun check(value: Boolean, code: BluebirdErrorCode, message: () -> String) {
        if (!value) {
            throw FlutterError(code.wire, message(), null)
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // pending-operation slots
    //
    // The per-connection slot machinery lives in ConnectionRegistry; only
    // the two ops that cannot live on a DeviceConnection are awaited here.

    private suspend fun awaitTurnOn(start: () -> Unit): Boolean =
        registry.awaitSlot({ pendingTurnOn }, { pendingTurnOn = it }, start)

    private suspend fun awaitRemoveBond(address: String, start: () -> Unit): Boolean =
        registry.awaitSlot(
            get = { pendingRemoveBond[address] },
            set = { if (it != null) pendingRemoveBond[address] = it else pendingRemoveBond.remove(address) },
            start = start,
        )

    /** Removes and returns every in-flight continuation, emptying all slots. */
    private fun takeAllPending(): List<CancellableContinuation<*>> = registry.withLock {
        buildList {
            addAll(registry.takeAllPending())
            addAll(pendingRemoveBond.values)
            pendingRemoveBond.clear()
            pendingTurnOn?.let { add(it) }
            pendingTurnOn = null
        }
    }

    /** Fails every in-flight operation, e.g. when the adapter turns off. */
    private fun failAllPending(error: FlutterError) {
        takeAllPending().forEach { it.resumeWithException(error) }
    }

    /** Cancels everything WITHOUT invoking callbacks (hot restart / detach). */
    private fun cancelAllPending() {
        takeAllPending().forEach { it.cancel() }
    }

    private fun invalidIdentifier(detail: String) =
        FlutterError(BluebirdErrorCode.INVALID_IDENTIFIER.wire, "could not locate attribute: $detail", null)

    private fun resolveCharacteristicOrThrow(
        gatt: BluetoothGatt,
        ref: BmCharacteristicRef,
    ): BluetoothGattCharacteristic =
        Proto.resolveCharacteristic(gatt, ref) ?: throw invalidIdentifier(ref.toString())

    private fun resolveDescriptorOrThrow(gatt: BluetoothGatt, ref: BmDescriptorRef): BluetoothGattDescriptor =
        Proto.resolveDescriptor(gatt, ref) ?: throw invalidIdentifier(ref.toString())

    private fun gattStatusError(status: Int, message: String? = null): FlutterError {
        // gattStatusError() is only reached from GATT *operation* callbacks (read /
        // write / etc.); link and connection failures take the separate
        // onConnectionStateChange -> DEVICE_DISCONNECTED path. So a non-zero
        // status here is the peer's ATT/GATT error-response code — spec-level
        // across the whole octet: ATT 0x01..0x11, application 0x80..0x9F, and
        // GATT common 0xE0..0xFF — which we surface uniformly as att_error. Only
        // values that cannot be a 1-octet ATT code (e.g. GATT_FAILURE 257) are
        // local/platform failures and stay android_error.
        //
        // Caveat: Android multiplexes a few internal sentinels (e.g. GATT_ERROR
        // 133, GATT_CONNECTION_CONGESTED 143) into that same byte space with no
        // flag to tell them apart from a peer app-error, so they ride through as
        // att errors too — match on the code if you need to treat them as link
        // failures rather than spec rejections.
        val code = if (status in 0x01..0xFF) BluebirdErrorCode.ATT_ERROR else BluebirdErrorCode.ANDROID_ERROR
        return FlutterError(code.wire, message ?: ErrorStrings.gattErrorString(status), status)
    }

    /** Suspends until all [perms] are granted or denied: (granted, deniedPerm). */
    private suspend fun awaitPermissions(perms: List<String>): Pair<Boolean, String?> =
        suspendCancellableCoroutine { cont ->
            permissions.ensurePermissions(context, activityBinding?.activity, perms) { granted, perm ->
                cont.resume(granted to perm)
            }
        }

    /** Suspends until all [perms] are granted, else throws PERMISSION_DENIED with [message]. */
    private suspend fun requirePermissions(perms: List<String>, message: (String?) -> String) {
        val (granted, perm) = awaitPermissions(perms)
        if (!granted) {
            throw FlutterError(BluebirdErrorCode.PERMISSION_DENIED.wire, message(perm), null)
        }
    }

    private fun connectPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) { // Android 12 (October 2021)
            listOf(Manifest.permission.BLUETOOTH_CONNECT)
        } else { // Android 11 (September 2020) and below
            listOf(Manifest.permission.BLUETOOTH)
        }

    // for highest reliability, it is recommended to not do
    // anything while the device is busy bonding.
    private suspend fun waitIfBonding() {
        if (bondingDevices.isNotEmpty()) {
            log(LogLevel.DEBUG, "waiting for bonding to complete...")
            delay(50)
            log(LogLevel.DEBUG, "bonding completed")
        }
    }

    private fun getMaxPayload(remoteId: String, writeType: Int, allowLongWrite: Boolean): Int {
        // 512 comes from the BLE spec. Characteristics should not be longer
        // than 512. Android also enforces this as the maximum in internal code.
        val maxAttrLen = 512

        // if no response, or allowLongWrite is not allowed, we can only write up to MTU-3.
        // This is the same limitation as iOS, and ensures transfer reliability.
        return if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE || !allowLongWrite) {
            val mtu = registry[remoteId]?.mtu ?: 23 // 23 is the minimum MTU, as per the BLE spec
            minOf(mtu - 3, maxAttrLen)
        } else {
            // if withResponse and allowLongWrite is allowed,
            // android will auto split up to the maxAttrLen.
            maxAttrLen
        }
    }

    private fun disconnectAllDevices(reason: String, adapterOff: Boolean = false) {
        log(LogLevel.DEBUG, "disconnectAllDevices($reason)")

        // request disconnections
        for (conn in registry.snapshot()) {
            if (!conn.isConnected) {
                continue
            }
            if (adapterOff) {
                // Note:
                //  - calling `disconnect` and `close` after the adapter
                //    is turned off is not necessary. It is implied.
                //    Calling them leads to a `DeadObjectException`.
                //  - But, we must make sure the disconnect callback is called.
                //    It's surprising but android does not invoke this callback itself.
                gattCallback.onConnectionStateChange(conn.gatt, 0, BluetoothProfile.STATE_DISCONNECTED)
            } else {
                // disconnect
                log(LogLevel.DEBUG, "calling disconnect: ${conn.address}")
                conn.gatt.disconnect()

                // it is important to close after disconnection, otherwise we will
                // quickly run out of bluetooth resources, preventing new connections
                log(LogLevel.DEBUG, "calling close: ${conn.address}")
                conn.gatt.close()
            }
        }

        registry.clear()
        bondingDevices.clear()
        bondingPins.clear()
    }

    /////////////////////////////////////////////////////////////////////////////
    // FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        log(LogLevel.DEBUG, "onAttachedToEngine")

        pluginBinding = binding
        context = binding.applicationContext

        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        BluebirdHostApi.setUp(binding.binaryMessenger, this)
        NativeEventsStreamHandler.register(binding.binaryMessenger, streamHandler)
        l2capManager = L2capManager(binding.binaryMessenger, mainHandler, ::log, ::emitEvent).also { it.start() }

        context?.registerReceiver(adapterStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        context?.registerReceiver(pairRequestReceiver, IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST))
        context?.registerReceiver(bondStateReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        log(LogLevel.DEBUG, "onDetachedFromEngine")

        // dart-side state is gone; notify listeners & close the stream
        sink?.success(BmDetachedFromEngineEvent())
        sink?.endOfStream()
        sink = null

        // drop every L2CAP channel silently (dart side is gone)
        l2capManager?.detach()
        l2capManager = null

        // drop in-flight operations WITHOUT invoking their callbacks:
        // cancelAllPending resumes nothing; scope.cancel then kills the
        // launched coroutines so no pigeon callback is ever invoked.
        cancelAllPending()
        scope.cancel()

        // stop scanning
        scanner.stop(bluetoothAdapter?.bluetoothLeScanner, "onDetachedFromEngine")

        registry.withLock {
            disconnectAllDevices("onDetachedFromEngine")
        }

        context?.unregisterReceiver(bondStateReceiver)
        context?.unregisterReceiver(pairRequestReceiver)
        context?.unregisterReceiver(adapterStateReceiver)
        context = null

        BluebirdHostApi.setUp(binding.binaryMessenger, null)
        pluginBinding = null

        bluetoothAdapter = null
        bluetoothManager = null
    }

    /////////////////////////////////////////////////////////////////////////////
    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        log(LogLevel.DEBUG, "onAttachedToActivity")
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        log(LogLevel.DEBUG, "onDetachedFromActivityForConfigChanges")
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        log(LogLevel.DEBUG, "onReattachedToActivityForConfigChanges")
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        log(LogLevel.DEBUG, "onDetachedFromActivity")
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    /////////////////////////////////////////////////////////////////////////////
    // activity results

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ): Boolean {
        return this.permissions.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == ENABLE_BLUETOOTH_REQUEST_CODE) {
            registry.withLock { pendingTurnOn?.also { pendingTurnOn = null } }
                ?.resume(resultCode == Activity.RESULT_OK)
            return true
        }
        return false // did not handle anything
    }

    /////////////////////////////////////////////////////////////////////////////
    // BluebirdHostApi

    override fun flutterRestart(): Long {
        log(LogLevel.DEBUG, "flutterRestart")

        // no adapter?
        val a = adapter() ?: return 0 // no work to do

        // stop scanning
        scanner.stop(a.bluetoothLeScanner, "flutterRestart")

        // drop in-flight operations without invoking their callbacks.
        // Must run before disconnectAllDevices clears the connections map,
        // because the pending continuations live on DeviceConnection slots.
        cancelAllPending()

        // all dart state is reset after flutter restart
        // (i.e. Hot Restart) so also reset native state
        l2capManager?.closeAll()
        registry.withLock {
            disconnectAllDevices("flutterRestart")
        }

        log(LogLevel.DEBUG, "connectedPeripherals: ${registry.size}")
        return registry.size.toLong()
    }

    override fun connectedCount(): Long {
        val count = registry.connectedCount
        log(LogLevel.DEBUG, "connectedPeripherals: $count")
        if (count == 0) {
            log(LogLevel.DEBUG, "Hot Restart: complete")
        }
        return count.toLong()
    }

    override fun setLogLevel(level: LogLevel) {
        logLevel = level
    }

    override fun setOptions(showPowerAlert: Boolean, restoreState: Boolean) {
        // Currently ignored on Android
    }

    override fun isSupported(): Boolean {
        return adapter() != null
    }

    override fun getAdapterName(callback: (Result<String>) -> Unit) = launch("getAdapterName", callback) {
        awaitPermissions(connectPermissions()) // proceed even if denied

        try {
            adapter()?.name
        } catch (e: SecurityException) {
            null
        } ?: ""
    }

    override fun getAdapterState(): BluetoothAdapterState {
        val state = try {
            adapter()?.state ?: -1
        } catch (e: Exception) {
            -1
        }
        return Proto.bmAdapterStateEnum(state)
    }

    override fun turnOn(callback: (Result<Boolean>) -> Unit) = launch("turnOn", callback) {
        val a = requireAdapter()
        requirePermissions(connectPermissions()) { perm -> "Permission $perm required to turn Bluetooth on" }

        if (a.isEnabled) {
            return@launch true // no work to do
        }

        val binding = activityBinding
            ?: throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "no foreground activity available to request Bluetooth enable", null)

        // completes via onActivityResult
        awaitTurnOn {
            val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            binding.activity.startActivityForResult(enableBtIntent, ENABLE_BLUETOOTH_REQUEST_CODE)
        }
    }

    @Suppress("DEPRECATION")
    override fun turnOff(callback: (Result<Boolean>) -> Unit) = launch("turnOff", callback) {
        val a = requireAdapter()

        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "turnOff is not supported on Android 13 (API 33) and above", null)
        }

        if (!a.isEnabled) {
            return@launch false // no work to do
        }

        a.disable()
    }

    override fun startScan(settings: BmScanSettings, callback: (Result<Unit>) -> Unit) = launch("startScan", callback) {
        val a = requireAdapter()

        val perms = buildList {
            if (Build.VERSION.SDK_INT >= 31) { // Android 12 (October 2021)
                add(Manifest.permission.BLUETOOTH_SCAN)
                if (settings.androidUsesFineLocation) {
                    add(Manifest.permission.ACCESS_FINE_LOCATION)
                }
                // it is unclear why this is needed, but some phones throw a
                // SecurityException AdapterService getRemoteName, without it
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else { // Android 11 (September 2020) and below
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }

        requirePermissions(perms) { perm -> "Permission $perm required to scan devices" }

        // check adapter
        requireAdapterOn()

        // get scanner
        val leScanner = a.bluetoothLeScanner
            ?: throw FlutterError(BluebirdErrorCode.ADAPTER_OFF.wire,
                "getBluetoothLeScanner() is null. Is the Adapter on?", null)

        scanner.start(leScanner, settings)
    }

    override fun stopScan() {
        scanner.stop(requireAdapter().bluetoothLeScanner, "stopScan")
    }

    override fun getSystemDevices(
        withServices: List<String>,
        callback: (Result<List<BmBluetoothDevice>>) -> Unit,
    ) = launch("getSystemDevices", callback) {
        requireAdapter()
        val perms = if (Build.VERSION.SDK_INT >= 31) connectPermissions() else emptyList()
        requirePermissions(perms) { perm -> "Permission $perm required to get system devices" }

        // this includes devices connected by other apps
        val devices = bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT) ?: emptyList()
        devices.map { Proto.bmBluetoothDevice(it) }
    }

    override fun getBondedDevices(callback: (Result<List<BmBluetoothDevice>>) -> Unit) = launch("getBondedDevices", callback) {
        val a = requireAdapter()
        val perms = if (Build.VERSION.SDK_INT >= 31) connectPermissions() else emptyList()
        requirePermissions(perms) { perm -> "Permission $perm required to get bonded devices" }

        val bonded = a.bondedDevices ?: emptySet()
        bonded.map { Proto.bmBluetoothDevice(it) }
    }

    override fun connect(address: String, callback: (Result<Unit>) -> Unit) = launch("connect", callback) {
        val a = requireAdapter()
        requirePermissions(connectPermissions()) { perm -> "Permission $perm required for new connection" }

        // check adapter
        requireAdapterOn()

        // already connected?
        if (registry.withLock { registry[address]?.isConnected == true }) {
            log(LogLevel.DEBUG, "already connected")
            return@launch // no work to do
        }

        // completes via onConnectionStateChange. Bespoke (not awaitSlot):
        // the slot lives on a DeviceConnection that may not exist yet, so
        // registration and connectGatt happen in one atomic block.
        suspendCancellableCoroutine<Unit> { cont ->
            val error = registry.withLock {
                val existing = registry[address]
                if (existing?.isConnecting == true) {
                    if (existing.pendingConnect != null) {
                        return@withLock operationInProgress()
                    }
                    // already connecting? this continuation completes on CONNECTED
                    log(LogLevel.DEBUG, "already connecting")
                    existing.pendingConnect = cont
                    return@withLock null
                }

                // connect (no autoConnect - it is not supported)
                val device = a.getRemoteDevice(address)
                val gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
                    ?: return@withLock FlutterError(
                        BluebirdErrorCode.ANDROID_ERROR.wire, "device.connectGatt returned null", null)

                // add to currently connecting peripherals
                val conn = DeviceConnection(address, gatt)
                conn.pendingConnect = cont
                registry.put(conn)
                null
            }
            if (error != null) {
                cont.resumeWithException(error)
                return@suspendCancellableCoroutine
            }
            cont.invokeOnCancellation {
                registry.withLock {
                    val c = registry[address]
                    if (c?.pendingConnect === cont) c.pendingConnect = null
                }
            }
        }
    }

    override fun disconnect(address: String, callback: (Result<Unit>) -> Unit) = launch("disconnect", callback) {
        // fast paths: returns the connection to tear down,
        // or null when there is nothing left to await
        val conn = registry.withLock {
            val c = registry[address]

            // already disconnected?
            if (c == null) {
                log(LogLevel.DEBUG, "already disconnected")
                return@withLock null // no work to do
            }

            // was connecting? cancel it
            if (c.isConnecting) {
                log(LogLevel.DEBUG, "cancelling connection in progress")

                // disconnect & cleanup
                c.gatt.disconnect()
                registry.remove(address)
                c.gatt.close()

                // fail the pending connect
                c.pendingConnect?.also { c.pendingConnect = null }?.resumeWithException(
                    FlutterError(BluebirdErrorCode.USER_CANCELED.wire, "connection canceled", null))

                emitEvent(BmConnectionStateEvent(
                    address = address,
                    connectionState = BluetoothConnectionState.DISCONNECTED,
                    disconnectReasonCode = USER_CANCELED_ERROR_CODE,
                    disconnectReasonString = "connection canceled",
                ))
                return@withLock null
            }

            c
        } ?: return@launch

        // connected; completes via onConnectionStateChange
        registry.awaitDisconnect(conn) {
            registry.withLock {
                conn.gatt.disconnect()
            }
        }
    }

    override fun discoverServices(
        address: String,
        callback: (Result<List<BmBluetoothService>>) -> Unit,
    ) = launch("discoverServices", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt

        // completes via onServicesDiscovered
        registry.awaitGatt(conn, GattOp.DiscoverServices) {
            if (!gatt.discoverServices()) {
                throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "gatt.discoverServices() returned false", null)
            }
        }
    }

    override fun readCharacteristic(
        address: String,
        characteristic: BmCharacteristicRef,
        callback: (Result<ByteArray>) -> Unit,
    ) = launch("readCharacteristic", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt
        val chr = resolveCharacteristicOrThrow(gatt, characteristic)

        // check readable
        check(chr.canRead, BluebirdErrorCode.UNSUPPORTED) {
            "The READ property is not supported by this BLE characteristic"
        }

        // completes via onCharacteristicRead
        registry.awaitGatt(conn, GattOp.ReadChar(chr)) {
            if (!gatt.readCharacteristic(chr)) {
                throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "gatt.readCharacteristic() returned false", null)
            }
        }
    }

    override fun writeCharacteristic(
        address: String,
        characteristic: BmCharacteristicRef,
        writeType: BmWriteType,
        allowLongWrite: Boolean,
        value: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) = launch("writeCharacteristic", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt
        val chr = resolveCharacteristicOrThrow(gatt, characteristic)

        val writeTypeInt = when (writeType) {
            BmWriteType.WITH_RESPONSE -> BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            BmWriteType.WITHOUT_RESPONSE -> BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }

        // check writeable
        if (writeTypeInt == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
            check(chr.canWriteNoResponse, BluebirdErrorCode.UNSUPPORTED) {
                "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic"
            }
        } else {
            check(chr.canWrite, BluebirdErrorCode.UNSUPPORTED) {
                "The WRITE property is not supported by this BLE characteristic"
            }
        }

        // check maximum payload
        val maxLen = getMaxPayload(address, writeTypeInt, allowLongWrite)
        check(value.size <= maxLen, BluebirdErrorCode.INVALID_ARGUMENT) {
            val a = if (writeType == BmWriteType.WITH_RESPONSE) "withResponse" else "withoutResponse"
            val b = if (writeType == BmWriteType.WITH_RESPONSE) {
                if (allowLongWrite) ", allowLongWrite" else ", noLongWrite"
            } else {
                ""
            }
            "data longer than allowed. value.length: ${value.size} > max: $maxLen ($a$b)"
        }

        // Several write-command Pigeon calls may already be resident here.
        // awaitGatt feeds them through the per-device native FIFO, while the
        // callback supplies Android's controller-buffer backpressure.
        registry.awaitGatt<Unit>(conn, GattOp.WriteChar(chr)) {
            gatt.writeCharacteristicCompat(chr, value, writeTypeInt)
        }
    }

    override fun readDescriptor(
        address: String,
        descriptor: BmDescriptorRef,
        callback: (Result<ByteArray>) -> Unit,
    ) = launch("readDescriptor", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt
        val desc = resolveDescriptorOrThrow(gatt, descriptor)

        // completes via onDescriptorRead
        registry.awaitGatt(conn, GattOp.ReadDesc(desc)) {
            if (!gatt.readDescriptor(desc)) {
                throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "gatt.readDescriptor() returned false", null)
            }
        }
    }

    override fun writeDescriptor(
        address: String,
        descriptor: BmDescriptorRef,
        value: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) = launch("writeDescriptor", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt
        val desc = resolveDescriptorOrThrow(gatt, descriptor)

        // check mtu
        val mtu = conn.mtu
        check((mtu - 3) >= value.size, BluebirdErrorCode.INVALID_ARGUMENT) {
            "data longer than mtu allows. dataLength: ${value.size} > max: ${mtu - 3}"
        }

        // completes via onDescriptorWrite
        registry.awaitGatt<Unit>(conn, GattOp.WriteDesc(desc)) {
            gatt.writeDescriptorCompat(desc, value)
        }
    }

    override fun setNotifyValue(
        address: String,
        characteristic: BmCharacteristicRef,
        enable: Boolean,
        callback: (Result<Boolean>) -> Unit,
    ) = launch("setNotifyValue", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt

        // wait if any device is bonding (increases reliability)
        waitIfBonding()

        val chr = resolveCharacteristicOrThrow(gatt, characteristic)

        // determine value to write
        val descriptorValue: ByteArray
        if (enable) {
            check(chr.canIndicate || chr.canNotify, BluebirdErrorCode.UNSUPPORTED) {
                "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic"
            }

            // If a characteristic supports both notifications and indications,
            // we use notifications. This matches how CoreBluetooth works on iOS.
            descriptorValue = when {
                chr.canNotify -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                else -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            }
        } else {
            descriptorValue = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        }

        // Configure Android's local routing before changing the peer's CCCD.
        // If the peer rejects the enable, roll local routing back so a retry
        // starts from a known state instead of leaving a half-bound listener.
        check(gatt.setCharacteristicNotification(chr, enable), BluebirdErrorCode.ANDROID_ERROR) {
            "gatt.setCharacteristicNotification($enable) returned false"
        }

        val cccd = chr.descriptors.firstOrNull { Uuid(it.uuid) == CCCD }
        if (cccd == null) {
            // A few peripherals implement notification routing without exposing
            // a CCCD. Preserve support for them, but make the fallback visible.
            log(LogLevel.WARNING, "CCCD descriptor for characteristic not found: ${Uuid(chr.uuid)}")
            return@launch true
        }

        try {
            // Completes only after the peer confirms the CCCD write.
            registry.awaitGatt(conn, GattOp.SetNotify(chr)) {
                gatt.writeDescriptorCompat(cccd, descriptorValue, label = "cccd")
            }
        } catch (error: Throwable) {
            if (enable && !gatt.setCharacteristicNotification(chr, false)) {
                log(LogLevel.WARNING, "Failed to roll back local notification routing: ${Uuid(chr.uuid)}")
            }
            throw error
        }
    }

    override fun requestMtu(address: String, mtu: Long, callback: (Result<Long>) -> Unit) = launch("requestMtu", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt

        // completes via onMtuChanged
        registry.awaitGatt(conn, GattOp.Mtu) {
            if (!gatt.requestMtu(mtu.toInt())) {
                throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "gatt.requestMtu() returned false", null)
            }
        }
    }

    override fun readRssi(address: String, callback: (Result<Long>) -> Unit) = launch("readRssi", callback) {
        val conn = registry.requireConnected(address)
        val gatt = conn.gatt

        // completes via onReadRemoteRssi
        registry.awaitGatt(conn, GattOp.Rssi) {
            if (!gatt.readRemoteRssi()) {
                throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "gatt.readRemoteRssi() returned false", null)
            }
        }
    }

    override fun requestConnectionPriority(address: String, connectionPriority: ConnectionPriority) {
        val gatt = registry.requireConnected(address).gatt

        if (!gatt.requestConnectionPriority(Proto.bmConnectionPriorityParse(connectionPriority))) {
            throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "gatt.requestConnectionPriority() returned false", null)
        }
    }

    override fun getPhySupport(): BmPhySupport {
        if (Build.VERSION.SDK_INT < 26) { // Android 8.0 (August 2017)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "Only supported on devices >= API 26. This device == ${Build.VERSION.SDK_INT}", null)
        }
        val a = requireAdapter()
        return BmPhySupport(le2M = a.isLe2MPhySupported, leCoded = a.isLeCodedPhySupported)
    }

    override fun setPreferredPhy(
        address: String,
        txPhy: Long,
        rxPhy: Long,
        phyOptions: Long,
        callback: (Result<Unit>) -> Unit,
    ) = launch("setPreferredPhy", callback) {
        if (Build.VERSION.SDK_INT < 26) { // Android 8.0 (August 2017)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "Only supported on devices >= API 26. This device == ${Build.VERSION.SDK_INT}", null)
        }

        val conn = registry.requireConnected(address)
        val gatt = conn.gatt

        // completes via onPhyUpdate
        registry.awaitGatt<Unit>(conn, GattOp.Phy) {
            gatt.setPreferredPhy(txPhy.toInt(), rxPhy.toInt(), phyOptions.toInt())
        }
    }

    override fun getBondState(address: String): BluetoothBondState {
        val device = requireAdapter().getRemoteDevice(address)
        return Proto.bmBondStateEnum(device.bondState)
    }

    override fun createBond(address: String, pin: ByteArray?, callback: (Result<Boolean>) -> Unit) = launch("createBond", callback) {
        val a = requireAdapter()

        if (pin != null) {
            bondingPins[address] = pin
        }

        // check connection
        val conn = registry.requireConnected(address)

        val device = a.getRemoteDevice(address)

        // already bonded?
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            log(LogLevel.WARNING, "already bonded")
            return@launch true // no work to do
        }

        // completes via the bond state receiver
        registry.awaitBond(conn) {
            // bonding already in progress? wait for completion
            if (device.bondState == BluetoothDevice.BOND_BONDING) {
                log(LogLevel.WARNING, "bonding already in progress")
            } else if (!device.createBond()) {
                throw FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "device.createBond() returned false", null)
            }
        }
    }

    override fun removeBond(address: String, callback: (Result<Boolean>) -> Unit) = launch("removeBond", callback) {
        val a = requireAdapter()

        val device = a.getRemoteDevice(address)

        // already removed?
        if (device.bondState == BluetoothDevice.BOND_NONE) {
            log(LogLevel.WARNING, "already not bonded")
            return@launch true // no work to do
        }

        // completes via the bond state receiver
        awaitRemoveBond(address) {
            val rv = try {
                val removeBondMethod = device.javaClass.getMethod("removeBond")
                removeBondMethod.invoke(device) as Boolean
            } catch (e: Exception) {
                throw FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "device.removeBond() failed: $e", null)
            }
            if (!rv) {
                throw FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "device.removeBond() returned false", null)
            }
        }
    }

    override fun clearGattCache(address: String, callback: (Result<Unit>) -> Unit) = launch("clearGattCache", callback) {
        val gatt = registry.requireConnected(address).gatt

        try {
            val refreshMethod = gatt.javaClass.getMethod("refresh")
            refreshMethod.invoke(gatt)
            // mirror the Java plugin: complete immediately after invoking
        } catch (e: Exception) {
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "gatt.refresh() unsupported on this android version: $e", null)
        }
    }

    override fun openL2capChannel(
        address: String,
        psm: Long,
        secure: Boolean,
        callback: (Result<Long>) -> Unit,
    ) = launch("openL2capChannel", callback) {
        val conn = registry.requireConnected(address)

        // createL2capChannel / createInsecureL2capChannel landed in API 29. The
        // early throw guards the calls below for both runtime and lint.
        if (Build.VERSION.SDK_INT < 29) { // Android 10 (September 2019)
            throw FlutterError(BluebirdErrorCode.UNSUPPORTED.wire,
                "L2CAP channels require Android 10 (API 29)", null)
        }
        val manager = l2capManager
            ?: throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "plugin is detached", null)

        val device = conn.gatt.device
        val socket = try {
            if (secure) device.createL2capChannel(psm.toInt()) else device.createInsecureL2capChannel(psm.toInt())
        } catch (e: Throwable) {
            throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "createL2capChannel failed: $e", null)
        }

        // connect() blocks until the channel opens; keep it off the main thread
        try {
            withContext(Dispatchers.IO) { socket.connect() }
        } catch (e: Throwable) {
            try { socket.close() } catch (_: Throwable) {}
            throw FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, "l2cap connect failed: $e", null)
        }

        // still connected after the (awaited) connect? otherwise clean up
        if (registry[address]?.isConnected != true) {
            try { socket.close() } catch (_: Throwable) {}
            throw FlutterError(BluebirdErrorCode.DEVICE_DISCONNECTED.wire, "device is disconnected", null)
        }

        manager.register(address, socket)
    }

    override fun closeL2capChannel(channelId: Long, callback: (Result<Unit>) -> Unit) =
        launch("closeL2capChannel", callback) {
            l2capManager?.closeSolicited(channelId)
        }

    /////////////////////////////////////////////////////////////////////////////
    // adapter state receiver

    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) {
                return
            }

            val adapterState = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)

            log(LogLevel.DEBUG, "OnAdapterStateChanged: ${ErrorStrings.adapterStateString(adapterState)}")

            // stop scanning when adapter is turned back on.
            // Otherwise, scanning automatically resumes when the adapter is
            // turned back on. I don't think most users expect that.
            if (adapterState == BluetoothAdapter.STATE_ON) {
                scanner.stop(bluetoothAdapter?.bluetoothLeScanner, "Bluetooth Restarted")
            }

            emitEvent(BmAdapterStateEvent(Proto.bmAdapterStateEnum(adapterState)))

            // disconnect all devices
            if (adapterState == BluetoothAdapter.STATE_TURNING_OFF ||
                adapterState == BluetoothAdapter.STATE_OFF
            ) {
                failAllPending(FlutterError(BluebirdErrorCode.ADAPTER_OFF.wire, "the bluetooth adapter was turned off", null))
                registry.withLock {
                    disconnectAllDevices("adapterTurnOff", adapterOff = true)
                }
            }
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // pairing request receiver

    private val pairRequestReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_PAIRING_REQUEST) {
                return
            }

            val device: BluetoothDevice = intent.getParcelableExtraCompat(BluetoothDevice.EXTRA_DEVICE) ?: return

            val remoteId = device.address
            val pin = bondingPins[remoteId]
            if (pin != null) {
                log(LogLevel.DEBUG, "Setting PIN code for $remoteId: ${Proto.bytesToHex(pin)}")
                if (!device.setPin(pin)) {
                    log(LogLevel.ERROR, "setPin() failed on $remoteId")
                }
                bondingPins.remove(remoteId)
            }
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // bond state receiver

    private val bondStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                return
            }

            val device: BluetoothDevice = intent.getParcelableExtraCompat(BluetoothDevice.EXTRA_DEVICE) ?: return

            val cur = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            val prev = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)

            log(LogLevel.DEBUG, "OnBondStateChanged: ${ErrorStrings.bondStateString(cur)} prev: ${ErrorStrings.bondStateString(prev)}")

            val remoteId = device.address

            // remember which devices are currently bonding
            if (cur == BluetoothDevice.BOND_BONDING) {
                bondingDevices[remoteId] = device
            } else {
                bondingDevices.remove(remoteId)
            }

            // complete in-flight bond operations on terminal states
            when (cur) {
                BluetoothDevice.BOND_BONDED -> {
                    registry.takeBond(remoteId)?.resume(true)
                }
                BluetoothDevice.BOND_NONE -> {
                    registry.takeBond(remoteId)?.resumeWithException(
                        FlutterError(BluebirdErrorCode.BOND_FAILED.wire, "bond attempt failed (final state: bond-none)", null))
                    registry.withLock { pendingRemoveBond.remove(remoteId) }?.resume(true)
                    bondingPins.remove(remoteId)
                }
            }

            emitEvent(BmBondStateEvent(
                address = remoteId,
                bondState = Proto.bmBondStateEnum(cur),
                prevState = if (prev == -1) null else Proto.bmBondStateEnum(prev),
            ))
        }
    }

    /////////////////////////////////////////////////////////////////////////////
    // gatt callback

    /**
     * Logs the GATT [status] for [label] and completes the device's pending
     * GATT operation, if there is one and [expected] matches its kind:
     * resumes it with [value] on GATT_SUCCESS, else fails it with the
     * corresponding gatt error. Returns whether an operation was completed —
     * unsolicited callbacks (e.g. a peer-initiated MTU change) match no
     * pending op and return false (event-only). With [logUnmatched] false,
     * nothing is logged unless an operation was completed.
     */
    private fun completeGatt(
        label: String,
        gatt: BluetoothGatt,
        status: Int,
        value: Any? = null,
        logUnmatched: Boolean = true,
        expected: (GattOp) -> Boolean,
    ): Boolean {
        val pending = registry.takeGatt(gatt.device.address, expected)

        if (pending != null || logUnmatched) {
            val level = if (status == BluetoothGatt.GATT_SUCCESS) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "$label: status: ${ErrorStrings.gattErrorString(status)} ($status)")
        }
        if (pending == null) {
            return false
        }

        if (status == BluetoothGatt.GATT_SUCCESS) {
            pending.cont.resume(value)
        } else {
            pending.cont.resumeWithException(gattStatusError(status))
        }
        return true
    }

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            registry.withLock {
                log(LogLevel.DEBUG, "onConnectionStateChange: ${ErrorStrings.connectionStateString(newState)}")
                log(LogLevel.DEBUG, "  status: ${ErrorStrings.hciStatusString(status)}")

                // android never uses this callback with enums values of CONNECTING or DISCONNECTING,
                // (they're only used for gatt.getConnectionState()), but just to be
                // future proof, explicitly ignore anything else. iOS & macOS is the same way.
                if (newState != BluetoothProfile.STATE_CONNECTED &&
                    newState != BluetoothProfile.STATE_DISCONNECTED
                ) {
                    return
                }

                val remoteId = gatt.device.address

                // edge case. see function for details
                if (handleUnexpectedConnectionEvents(gatt, newState, remoteId)) {
                    return
                }

                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    val conn = registry[remoteId]
                    if (conn != null) {
                        conn.state = DeviceConnection.State.CONNECTED
                        conn.gatt = gatt
                        conn.mtu = 23 // default minimum mtu

                        conn.pendingConnect?.also { conn.pendingConnect = null }?.resume(Unit)
                    }

                    emitEvent(BmConnectionStateEvent(
                        address = remoteId,
                        connectionState = BluetoothConnectionState.CONNECTED,
                        disconnectReasonCode = null,
                        disconnectReasonString = null,
                    ))
                } else {
                    // remove from connected devices
                    val conn = registry.remove(remoteId)

                    // remove from currently bonding devices & cached PINs
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // it is important to close after disconnection, otherwise we will
                    // quickly run out of bluetooth resources, preventing new connections
                    gatt.close()

                    // close any L2CAP channels this device had open
                    l2capManager?.closeForDevice(remoteId)

                    // complete in-flight ops for this device
                    if (conn != null) {
                        conn.pendingDisconnect?.also { conn.pendingDisconnect = null }?.resume(Unit)
                        conn.pendingConnect?.also { conn.pendingConnect = null }?.resumeWithException(
                            FlutterError(BluebirdErrorCode.ANDROID_ERROR.wire, ErrorStrings.hciStatusString(status), status))
                        conn.failAllPending(
                            FlutterError(BluebirdErrorCode.DEVICE_DISCONNECTED.wire, "device is disconnected", null))
                    }

                    emitEvent(BmConnectionStateEvent(
                        address = remoteId,
                        connectionState = BluetoothConnectionState.DISCONNECTED,
                        disconnectReasonCode = status.toLong(),
                        disconnectReasonString = ErrorStrings.hciStatusString(status),
                    ))
                }
            }
        }

        // Android has an annoying edge case. If disconnect is called right as the connection is being
        // established, Android sometimes ignores the request to disconnect and completes the connection
        // anyway. To handle this case, we make sure the device is still in our currently connecting
        // devices map, otherwise kill the connection since the user was not expecting it to connect.
        private fun handleUnexpectedConnectionEvents(gatt: BluetoothGatt, newState: Int, remoteId: String): Boolean {
            val conn = registry[remoteId]

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (conn == null || !conn.isConnecting) {
                    log(LogLevel.DEBUG, "[unexpected connection] disconnecting now")

                    // remove all record of the device
                    registry.remove(remoteId)
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // disconnect and close the connection straight away
                    gatt.disconnect()
                    gatt.close()

                    return true
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (conn == null) {
                    log(LogLevel.DEBUG, "[unexpected connection] disconnect complete")

                    // remove from currently bonding devices & cached PINs
                    bondingDevices.remove(remoteId)
                    bondingPins.remove(remoteId)

                    // close the connection
                    gatt.close()

                    return true
                }
            }
            return false
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onServicesDiscovered:")
            log(level, "  count: ${gatt.services.size}")
            log(level, "  status: $status ${ErrorStrings.gattErrorString(status)}")

            val pending = registry.takeGatt(gatt.device.address) { it is GattOp.DiscoverServices } ?: return

            if (status != BluetoothGatt.GATT_SUCCESS) {
                pending.cont.resumeWithException(gattStatusError(status))
                return
            }

            pending.cont.resume(gatt.services.map { Proto.bmBluetoothService(gatt, it) })
        }

        // API 31+: the framework consumes the 0x2A05 "services changed"
        // indication itself (like CoreBluetooth) and delivers it here instead
        // of onCharacteristicChanged
        override fun onServiceChanged(gatt: BluetoothGatt) {
            log(LogLevel.DEBUG, "onServiceChanged")
            emitEvent(BmServicesResetEvent(gatt.device.address))
        }

        // pre-API-31: detects the 0x2A05 "services changed" indication from
        // the Generic Attribute service (requires our own subscription)
        private fun checkServicesReset(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Uuid(characteristic.service.uuid) == Uuid.GENERIC_ATTRIBUTE_SERVICE &&
                Uuid(characteristic.uuid) == Uuid.SERVICE_CHANGED_CHARACTERISTIC
            ) {
                emitEvent(BmServicesResetEvent(gatt.device.address))
            }
        }

        // this callback is only for notifications & indications
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            log(LogLevel.DEBUG, "onCharacteristicChanged:")
            log(LogLevel.DEBUG, "  chr: ${Uuid(characteristic.uuid)}")

            checkServicesReset(gatt, characteristic)

            emitEvent(BmCharacteristicNotificationEvent(
                address = gatt.device.address,
                characteristic = Proto.characteristicRef(gatt, characteristic),
                value = value,
            ))
        }

        // this callback is only for explicit characteristic reads
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            checkServicesReset(gatt, characteristic)

            completeGatt("onCharacteristicRead: chr: ${Uuid(characteristic.uuid)}", gatt, status, value) {
                it == GattOp.ReadChar(characteristic)
            }
        }

        // Pre-API-33 the framework only calls this deprecated overload; forward
        // to the ByteArray override. getValue() is safe here: it is populated
        // for changed/read callbacks (just not for writes). The SDK guard
        // avoids double delivery on API 33+, which calls both overloads.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < 33) {
                onCharacteristicChanged(gatt, characteristic, characteristic.value ?: ByteArray(0))
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (Build.VERSION.SDK_INT < 33) {
                onCharacteristicRead(gatt, characteristic, characteristic.value ?: ByteArray(0), status)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            // For "writeWithResponse", onCharacteristicWrite is called after the remote sends back a write response.
            // For "writeWithoutResponse", onCharacteristicWrite is called as long as there is still space left
            // in android's internal buffer. When the buffer is full, it delays calling onCharacteristicWrite
            // until there is at least ~50% free space again.

            completeGatt("onCharacteristicWrite: chr: ${Uuid(characteristic.uuid)}", gatt, status, Unit) {
                it == GattOp.WriteChar(characteristic)
            }
        }

        override fun onDescriptorRead(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
            value: ByteArray,
        ) {
            val label = "onDescriptorRead: chr: ${Uuid(descriptor.characteristic.uuid)}" +
                " desc: ${Uuid(descriptor.uuid)}"
            completeGatt(label, gatt, status, value) {
                it == GattOp.ReadDesc(descriptor)
            }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION") // needed for android 12 & lower compatibility
        override fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (Build.VERSION.SDK_INT < 33) {
                onDescriptorRead(gatt, descriptor, status, descriptor.value ?: ByteArray(0))
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val label = "onDescriptorWrite: chr: ${Uuid(descriptor.characteristic.uuid)}" +
                " desc: ${Uuid(descriptor.uuid)}"

            // a CCCD write confirms a setNotifyValue request
            if (Uuid(descriptor.uuid) == CCCD &&
                completeGatt(label, gatt, status, value = true, logUnmatched = false) {
                    it == GattOp.SetNotify(descriptor.characteristic)
                }
            ) {
                return
            }

            completeGatt(label, gatt, status, Unit) {
                it == GattOp.WriteDesc(descriptor)
            }
        }

        override fun onReliableWriteCompleted(gatt: BluetoothGatt, status: Int) {
            val level = if (status == 0) LogLevel.DEBUG else LogLevel.ERROR
            log(level, "onReliableWriteCompleted:")
            log(level, "  status: ${ErrorStrings.gattErrorString(status)} ($status)")
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            completeGatt("onReadRemoteRssi: rssi: $rssi", gatt, status, rssi.toLong()) { it is GattOp.Rssi }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val remoteId = gatt.device.address

            // remember mtu (volatile field; safe to write from binder threads)
            registry[remoteId]?.mtu = mtu

            // unsolicited (peer-initiated) changes match no pending op: event-only
            completeGatt("onMtuChanged: mtu: $mtu", gatt, status, mtu.toLong()) { it is GattOp.Mtu }

            if (status == BluetoothGatt.GATT_SUCCESS) {
                // emitted for both solicited and unsolicited (peer-initiated) changes
                emitEvent(BmMtuChangedEvent(remoteId, mtu.toLong()))
            }
        }

        override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            completeGatt("onPhyUpdate: txPhy: $txPhy rxPhy: $rxPhy", gatt, status, Unit) { it is GattOp.Phy }
        }
    }
}
