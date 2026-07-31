// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Conversions between pigeon (Bm*) messages and Android Bluetooth objects — the codec layer.

package com.lib.bluebird

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanRecord
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.Build
import android.os.ParcelUuid
import java.io.ByteArrayOutputStream

/** Wire form of an error code: snake_case, shared convention with Dart (see pigeons/messages.dart). */
val BluebirdErrorCode.wire: String get() = name.lowercase()

object Proto {

    //////////////////////////////////////////
    // typed ref building

    fun attributeId(service: BluetoothGattService): BmAttributeId =
        BmAttributeId(Uuid(service.uuid).str, service.instanceId.toLong())

    fun attributeId(characteristic: BluetoothGattCharacteristic): BmAttributeId =
        BmAttributeId(Uuid(characteristic.uuid).str, characteristic.instanceId.toLong())

    /**
     * Builds the ref for [service], setting parentService when it is a
     * secondary service included by a primary one.
     */
    fun serviceRef(gatt: BluetoothGatt, service: BluetoothGattService): BmServiceRef {
        val primary = getPrimaryService(gatt, service)
        return BmServiceRef(attributeId(service), primary?.let { attributeId(it) })
    }

    fun characteristicRef(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic): BmCharacteristicRef =
        BmCharacteristicRef(serviceRef(gatt, characteristic.service), attributeId(characteristic))

    /**
     * If [service] is a secondary service, returns the primary service that
     * includes it; otherwise null.
     */
    fun getPrimaryService(gatt: BluetoothGatt, service: BluetoothGattService): BluetoothGattService? {
        // is this *already* a primary service?
        if (service.type == BluetoothGattService.SERVICE_TYPE_PRIMARY) {
            return null
        }
        // Otherwise, iterate included services until we find the primary service
        for (primary in gatt.services) {
            for (secondary in primary.includedServices) {
                if (secondary.uuid == service.uuid) {
                    return primary
                }
            }
        }
        return null
    }

    //////////////////////////////////////////
    // typed ref resolution

    fun resolveService(gatt: BluetoothGatt, id: BmAttributeId): BluetoothGattService? {
        val target = AttributeId(id)
        return gatt.services.firstOrNull { AttributeId(it) == target }
    }

    fun resolveCharacteristic(gatt: BluetoothGatt, ref: BmCharacteristicRef): BluetoothGattCharacteristic? {
        val service = resolveService(gatt, ref.service.service) ?: return null
        val target = AttributeId(ref.characteristic)
        return service.characteristics.firstOrNull { AttributeId(it) == target }
    }

    fun resolveDescriptor(gatt: BluetoothGatt, ref: BmDescriptorRef): BluetoothGattDescriptor? {
        val characteristic = resolveCharacteristic(gatt, ref.characteristic) ?: return null
        // descriptors are uuid-unique within a characteristic (instance is always 0)
        return characteristic.descriptors.firstOrNull { Uuid(it.uuid) == Uuid.parse(ref.id.uuid) }
    }

    //////////////////////////////////////////
    // op keys

    //////////////////////////////////////////
    // message builders

    fun bmBluetoothDevice(device: BluetoothDevice): BmBluetoothDevice =
        BmBluetoothDevice(device.address, device.name)

    fun bmBluetoothService(gatt: BluetoothGatt, service: BluetoothGattService): BmBluetoothService {
        val characteristics = service.characteristics.map { bmBluetoothCharacteristic(it) }
        val includedServices = service.includedServices.map { included ->
            if (included.type == BluetoothGattService.SERVICE_TYPE_SECONDARY) {
                BmServiceRef(attributeId(included), attributeId(service))
            } else {
                BmServiceRef(attributeId(included), null)
            }
        }
        return BmBluetoothService(
            id = attributeId(service),
            isPrimary = service.type == BluetoothGattService.SERVICE_TYPE_PRIMARY,
            characteristics = characteristics,
            includedServices = includedServices,
        )
    }

    fun bmBluetoothCharacteristic(characteristic: BluetoothGattCharacteristic): BmBluetoothCharacteristic =
        BmBluetoothCharacteristic(
            id = attributeId(characteristic),
            descriptors = characteristic.descriptors.map { BmBluetoothDescriptor(BmAttributeId(Uuid(it.uuid).str, 0L)) },
            properties = bmCharacteristicProperties(characteristic.properties),
        )

    fun bmCharacteristicProperties(properties: Int): BmCharacteristicProperties =
        BmCharacteristicProperties(
            broadcast = (properties and 1) != 0,
            read = (properties and 2) != 0,
            writeWithoutResponse = (properties and 4) != 0,
            write = (properties and 8) != 0,
            notify = (properties and 16) != 0,
            indicate = (properties and 32) != 0,
            authenticatedSignedWrites = (properties and 64) != 0,
            extendedProperties = (properties and 128) != 0,
            notifyEncryptionRequired = (properties and 256) != 0,
            indicateEncryptionRequired = (properties and 512) != 0,
        )

    fun bmScanAdvertisement(device: BluetoothDevice, result: ScanResult): BmScanAdvertisement {
        val min = Int.MIN_VALUE
        val adv: ScanRecord? = result.scanRecord

        val connectable: Boolean = if (Build.VERSION.SDK_INT >= 26) { // Android 8.0, August 2017
            result.isConnectable
        } else {
            // Prior to Android 8.0, it is not possible to get if connectable.
            true
        }

        val advName = adv?.deviceName
        val txPower = adv?.txPowerLevel ?: min
        val appearance = adv?.let { getAppearanceFromScanRecord(it) } ?: 0
        // Manufacturer Specific Data, keyed by company id.
        val manufacturerData = adv?.let { getManufacturerData(it) } ?: HashMap()

        // Service Data
        val serviceData = HashMap<String, ByteArray>()
        adv?.serviceData?.forEach { (key, value) ->
            serviceData[Uuid(key.uuid).str] = value
        }

        // Service UUIDs
        val serviceUuids = adv?.serviceUuids?.map { Uuid(it.uuid).str } ?: emptyList()

        val platformName = try {
            device.name
        } catch (e: SecurityException) {
            null
        }

        return BmScanAdvertisement(
            address = device.address,
            platformName = platformName,
            advName = advName,
            connectable = connectable,
            txPowerLevel = if (txPower != min) txPower.toLong() else null,
            appearance = if (appearance != 0) appearance.toLong() else null,
            manufacturerData = manufacturerData,
            serviceData = serviceData,
            serviceUuids = serviceUuids,
            rssi = result.rssi.toLong(),
        )
    }

    fun getAppearanceFromScanRecord(adv: ScanRecord): Int {
        if (Build.VERSION.SDK_INT >= 33) { // Android 13 (August 2022)
            val map = adv.advertisingDataMap
            val bytes = map[ScanRecord.DATA_TYPE_APPEARANCE]
            if (bytes != null && bytes.size == 2) {
                val loByte = bytes[0].toInt() and 0xFF
                val hiByte = bytes[1].toInt() and 0xFF
                return hiByte * 256 + loByte
            }
            return 0
        }

        // For API Level 21+
        val bytes = adv.bytes
        var n = 0
        while (n < bytes.size) {
            val fieldLen = bytes[n].toInt() and 0xFF

            // no more or malformed data
            if (fieldLen <= 0) break

            // Ensuring we don't go past the bytes array
            if (n + fieldLen >= bytes.size) break

            val dataType = bytes[n + 1].toInt() and 0xFF

            // no more data
            if (dataType == 0) break

            // appearance type byte
            if (dataType == 0x19 && fieldLen == 3) {
                val high = (bytes[n + 3].toInt() and 0xFF) shl 8
                val low = bytes[n + 2].toInt() and 0xFF
                return high or low
            }

            n += fieldLen + 1
        }
        return 0
    }

    // Parse manufacturer specific data, keyed by company id.
    //
    // android's own ScanRecord.getManufacturerSpecificData() does not
    // concatenate multiple MSD structures that share a company id, so we walk
    // the raw AD structures ourselves. Each structure must be attributed to its
    // *own* company id — the previous implementation lumped every structure into
    // one blob and treated only the first two bytes as the id, which appended
    // any later structures' company ids into the first structure's data.
    fun getManufacturerData(adv: ScanRecord): HashMap<Long, ByteArray> {
        val bytes = adv.bytes
        val output = HashMap<Long, ByteArrayOutputStream>()
        var n = 0
        while (n < bytes.size) {
            // layout:
            // n[0] = fieldlen
            // n[1] = datatype (MSD)
            // n[2] = companyId (low)
            // n[3] = companyId (high)
            // n[4] = data...
            val fieldLen = bytes[n].toInt() and 0xFF

            // no more or malformed data
            if (fieldLen <= 0) break

            // Ensuring we don't go past the bytes array
            if (n + fieldLen >= bytes.size) break

            val dataType = bytes[n + 1].toInt() and 0xFF

            // Manufacturer Specific Data (0xFF), large enough to hold the 2-byte
            // company id (type + id = 3 bytes).
            if (dataType == 0xFF && fieldLen >= 3) {
                // company id uses little-endian order.
                val companyId = (bytes[n + 2].toInt() and 0xFF) or ((bytes[n + 3].toInt() and 0xFF) shl 8)
                // append only the payload, skipping the 2-byte company id.
                output.getOrPut(companyId.toLong()) { ByteArrayOutputStream() }
                    .write(bytes, n + 4, fieldLen - 3)
            }

            n += fieldLen + 1
        }
        return HashMap(output.mapValues { it.value.toByteArray() })
    }

    //////////////////////////////////////////
    // scan settings

    /** Converts pigeon scan settings into the native filter list. */
    fun scanFilters(settings: BmScanSettings): List<ScanFilter> = buildList {
        // services
        for (service in settings.withServices) {
            val uuid = ParcelUuid(Uuid.parse(service).value)
            add(ScanFilter.Builder().setServiceUuid(uuid).build())
        }

        // remoteIds
        for (address in settings.withRemoteIds) {
            add(ScanFilter.Builder().setDeviceAddress(address).build())
        }

        // names
        for (name in settings.withNames) {
            add(ScanFilter.Builder().setDeviceName(name).build())
        }

        // keywords
        if (Build.VERSION.SDK_INT >= 33 && settings.withKeywords.isNotEmpty()) { // Android 13 (August 2022)
            // device must advertise a name
            add(ScanFilter.Builder()
                .setAdvertisingDataType(ScanRecord.DATA_TYPE_LOCAL_NAME_SHORT).build())
            add(ScanFilter.Builder()
                .setAdvertisingDataType(ScanRecord.DATA_TYPE_LOCAL_NAME_COMPLETE).build())
        }

        // msd
        for (msd in settings.withMsd) {
            val mask = msd.mask
            add(if (mask == null || mask.isEmpty()) {
                ScanFilter.Builder().setManufacturerData(msd.manufacturerId.toInt(), msd.data).build()
            } else {
                ScanFilter.Builder().setManufacturerData(msd.manufacturerId.toInt(), msd.data, mask).build()
            })
        }

        // service data
        for (sd in settings.withServiceData) {
            val uuid = ParcelUuid(Uuid.parse(sd.service).value)
            val mask = sd.mask
            add(if (mask == null || mask.isEmpty()) {
                ScanFilter.Builder().setServiceData(uuid, sd.data).build()
            } else {
                ScanFilter.Builder().setServiceData(uuid, sd.data, mask).build()
            })
        }
    }

    /** Converts pigeon scan settings into native scan settings. */
    fun scanSettings(settings: BmScanSettings): ScanSettings {
        val builder = ScanSettings.Builder()
        builder.setScanMode(settings.androidScanMode.toInt())
        if (Build.VERSION.SDK_INT >= 26) { // Android 8.0 (August 2017)
            builder.setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
            builder.setLegacy(settings.androidLegacy)
        }
        return builder.build()
    }

    //////////////////////////////////////////
    // enum mapping

    fun bmAdapterStateEnum(state: Int): BluetoothAdapterState = when (state) {
        BluetoothAdapter.STATE_OFF -> BluetoothAdapterState.OFF
        BluetoothAdapter.STATE_ON -> BluetoothAdapterState.ON
        BluetoothAdapter.STATE_TURNING_OFF -> BluetoothAdapterState.TURNING_OFF
        BluetoothAdapter.STATE_TURNING_ON -> BluetoothAdapterState.TURNING_ON
        else -> BluetoothAdapterState.UNKNOWN
    }

    fun bmBondStateEnum(state: Int): BluetoothBondState = when (state) {
        BluetoothDevice.BOND_NONE -> BluetoothBondState.NONE
        BluetoothDevice.BOND_BONDING -> BluetoothBondState.BONDING
        BluetoothDevice.BOND_BONDED -> BluetoothBondState.BONDED
        else -> BluetoothBondState.NONE
    }

    fun bmConnectionPriorityParse(priority: ConnectionPriority): Int = when (priority) {
        ConnectionPriority.BALANCED -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
        ConnectionPriority.HIGH -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
        ConnectionPriority.LOW_POWER -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
    }

    fun bytesToHex(bytes: ByteArray?): String {
        if (bytes == null) return ""
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            sb.append(Character.forDigit((b.toInt() shr 4) and 0xF, 16))
            sb.append(Character.forDigit(b.toInt() and 0xF, 16))
        }
        return sb.toString()
    }
}
