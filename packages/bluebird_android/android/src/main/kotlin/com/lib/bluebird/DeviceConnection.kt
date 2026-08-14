// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Per-device state and the continuation slots that bridge Android's callback APIs into suspend functions.

package com.lib.bluebird

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex

/** Error for starting a second operation of a concurrency class while one is in flight. */
internal fun operationInProgress() = FlutterError(
    BluebirdErrorCode.OPERATION_IN_PROGRESS.wire,
    "an operation of this type is already in progress for this device", null)

/** Canonical attribute id — safe to compare. */
data class AttributeId(val uuid: Uuid, val instance: Int) {
    constructor(s: BluetoothGattService) : this(Uuid(s.uuid), s.instanceId)
    constructor(c: BluetoothGattCharacteristic) : this(Uuid(c.uuid), c.instanceId)
    constructor(id: BmAttributeId) : this(Uuid.parse(id.uuid), id.instance.toInt())
}

/**
 * Identifies which GATT operation is in flight on a device, so callbacks can
 * be matched to the operation they complete by whole-value equality (e.g. an
 * unsolicited onMtuChanged must not resume a pending read). Each case carries
 * the normalized ids of the attribute path it targets — service, then
 * characteristic, then descriptor (descriptors are uuid-unique within a
 * characteristic, so a plain [Uuid] suffices). The device address is
 * implicit: the op lives on the [DeviceConnection] that started it.
 */
sealed class GattOp {
    data class ReadChar(val service: AttributeId, val characteristic: AttributeId) : GattOp() {
        constructor(c: BluetoothGattCharacteristic) : this(AttributeId(c.service), AttributeId(c))
    }

    data class WriteChar(val service: AttributeId, val characteristic: AttributeId) : GattOp() {
        constructor(c: BluetoothGattCharacteristic) : this(AttributeId(c.service), AttributeId(c))
    }

    data class SetNotify(val service: AttributeId, val characteristic: AttributeId) : GattOp() {
        constructor(c: BluetoothGattCharacteristic) : this(AttributeId(c.service), AttributeId(c))
    }

    data class ReadDesc(val service: AttributeId, val characteristic: AttributeId, val descriptor: Uuid) : GattOp() {
        constructor(d: BluetoothGattDescriptor) :
            this(AttributeId(d.characteristic.service), AttributeId(d.characteristic), Uuid(d.uuid))
    }

    data class WriteDesc(val service: AttributeId, val characteristic: AttributeId, val descriptor: Uuid) : GattOp() {
        constructor(d: BluetoothGattDescriptor) :
            this(AttributeId(d.characteristic.service), AttributeId(d.characteristic), Uuid(d.uuid))
    }

    data object DiscoverServices : GattOp()
    data object Mtu : GattOp()
    data object Rssi : GattOp()
    data object Phy : GattOp()
}

/** One in-flight GATT operation awaiting its BluetoothGattCallback. */
class PendingGatt(val kind: GattOp, val cont: CancellableContinuation<Any?>)

/**
 * Per-device connection state, replacing the Java plugin's cluster of
 * ConcurrentHashMap fields (mConnectedDevices, mCurrentlyConnectingDevices,
 * mMtu).
 */
class DeviceConnection(
    val address: String,
    var gatt: BluetoothGatt,
) {
    enum class State { CONNECTING, CONNECTED }

    var state: State = State.CONNECTING

    /**
     * 23 is the minimum MTU, as per the BLE spec.
     * Volatile: written from GATT binder threads, read from the main thread.
     */
    @Volatile
    var mtu: Int = 23

    val isConnected: Boolean get() = state == State.CONNECTED
    val isConnecting: Boolean get() = state == State.CONNECTING

    // One continuation slot per concurrency class. Android allows only one
    // in-flight GATT op per device (starting a second while one is pending
    // returns false) and the Dart layer additionally serializes globally,
    // so a single gatt slot suffices; `kind` is kept so callbacks can be
    // matched (e.g. an unsolicited onMtuChanged must not resume a pending
    // read).
    //
    // All slots are mutated under the ConnectionRegistry's lock: callbacks
    // arrive on binder threads.
    var pendingConnect: CancellableContinuation<Unit>? = null
    var pendingDisconnect: CancellableContinuation<Unit>? = null
    var pendingGatt: PendingGatt? = null
    var pendingBond: CancellableContinuation<Boolean>? = null

    /**
     * Accepts a burst of write commands from Dart and feeds them into Android's
     * single per-connection GATT slot without another Flutter round trip.
     */
    val writeWithoutResponseMutex = Mutex()

    /**
     * Fails the gatt & bond slots, e.g. when the device disconnects.
     * pendingConnect/pendingDisconnect are completed separately by
     * onConnectionStateChange. Caller must hold the registry's lock.
     */
    fun failAllPending(error: FlutterError) {
        pendingGatt?.let { pendingGatt = null; it.cont.resumeWithException(error) }
        pendingBond?.let { pendingBond = null; it.resumeWithException(error) }
    }
}

/**
 * Owns the connection map plus the lock that guards every
 * pending-operation slot, so the "no suspension points under the lock"
 * discipline lives in one place.
 */
class ConnectionRegistry {

    // Prevents GATT callback threads & the platform thread from mutating
    // connection state concurrently (was mMethodCallMutex in the Java plugin).
    @PublishedApi
    internal val stateLock = Any()

    private val connections = ConcurrentHashMap<String, DeviceConnection>()

    /** Runs [block] under the registry lock. Do not suspend inside [block]. */
    inline fun <T> withLock(block: () -> T): T = synchronized(stateLock) { block() }

    operator fun get(address: String): DeviceConnection? = connections[address]

    fun put(conn: DeviceConnection) {
        connections[conn.address] = conn
    }

    fun remove(address: String): DeviceConnection? = connections.remove(address)

    fun clear() = connections.clear()

    val size: Int get() = connections.size

    val connectedCount: Int get() = connections.values.count { it.isConnected }

    /** Snapshot of every tracked connection (connecting & connected). */
    fun snapshot(): List<DeviceConnection> = connections.values.toList()

    private fun notConnected() =
        FlutterError(BluebirdErrorCode.NOT_CONNECTED.wire, "device is not connected", null)

    fun requireConnected(address: String): DeviceConnection =
        connections[address]?.takeIf { it.isConnected } ?: throw notConnected()

    /////////////////////////////////////////////////////////////////////////////
    // pending-operation slots
    //
    // Bridges Android's callback-style APIs into suspend functions: one
    // continuation slot per concurrency class, resumed by the GATT
    // callbacks, broadcast receivers, or activity results. Slots are
    // mutated under stateLock (callbacks arrive on binder threads);
    // resuming from them is safe because continuations resume on the
    // plugin's Main dispatcher.

    /**
     * Registers the continuation in the slot exposed by [get]/[set] (under
     * [stateLock]), runs [start], then suspends until a callback resumes it.
     * Fails immediately with operation_in_progress if the slot is occupied.
     * If [start] throws, the slot is rolled back and the error propagates.
     */
    suspend fun <T> awaitSlot(
        get: () -> CancellableContinuation<T>?,
        set: (CancellableContinuation<T>?) -> Unit,
        start: () -> Unit,
    ): T = suspendCancellableCoroutine { cont ->
        val conflict = synchronized(stateLock) {
            if (get() != null) {
                true
            } else {
                set(cont)
                false
            }
        }
        if (conflict) {
            cont.resumeWithException(operationInProgress())
            return@suspendCancellableCoroutine
        }
        cont.invokeOnCancellation {
            synchronized(stateLock) {
                if (get() === cont) set(null)
            }
        }
        try {
            start()
        } catch (e: Throwable) {
            // roll back the slot, only if it is still ours
            val ours = synchronized(stateLock) {
                if (get() === cont) {
                    set(null)
                    true
                } else {
                    false
                }
            }
            if (ours) cont.resumeWithException(e)
        }
    }

    /** Suspends until the device's single in-flight GATT op slot is resumed by its callback. */
    @Suppress("UNCHECKED_CAST")
    suspend fun <T> awaitGatt(conn: DeviceConnection, kind: GattOp, start: () -> Unit): T =
        awaitSlot<Any?>(
            get = { conn.pendingGatt?.cont },
            set = { conn.pendingGatt = it?.let { cont -> PendingGatt(kind, cont) } },
            start = start,
        ) as T

    suspend fun awaitDisconnect(conn: DeviceConnection, start: () -> Unit): Unit =
        awaitSlot({ conn.pendingDisconnect }, { conn.pendingDisconnect = it }, start)

    suspend fun awaitBond(conn: DeviceConnection, start: () -> Unit): Boolean =
        awaitSlot({ conn.pendingBond }, { conn.pendingBond = it }, start)

    /** Atomically takes the device's pending GATT op, if [expected] matches its kind. */
    fun takeGatt(address: String, expected: (GattOp) -> Boolean): PendingGatt? =
        synchronized(stateLock) {
            val conn = connections[address] ?: return@synchronized null
            conn.pendingGatt?.takeIf { expected(it.kind) }?.also { conn.pendingGatt = null }
        }

    /** Atomically takes the device's pending createBond continuation, if any. */
    fun takeBond(address: String): CancellableContinuation<Boolean>? =
        synchronized(stateLock) {
            connections[address]?.let { c -> c.pendingBond?.also { c.pendingBond = null } }
        }

    /** Removes and returns every per-connection in-flight continuation, emptying all slots. */
    fun takeAllPending(): List<CancellableContinuation<*>> = synchronized(stateLock) {
        buildList {
            for (conn in connections.values) {
                conn.pendingConnect?.let { add(it) }
                conn.pendingConnect = null
                conn.pendingDisconnect?.let { add(it) }
                conn.pendingDisconnect = null
                conn.pendingGatt?.let { add(it.cont) }
                conn.pendingGatt = null
                conn.pendingBond?.let { add(it) }
                conn.pendingBond = null
            }
        }
    }
}
