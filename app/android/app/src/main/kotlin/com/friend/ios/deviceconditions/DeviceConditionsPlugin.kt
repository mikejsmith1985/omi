package com.friend.ios.deviceconditions

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager

/**
 * Reports the phone's own power and thermal state.
 *
 * The app already reads *watch* and *BLE device* battery through the main Pigeon
 * contract, but nothing reported the phone's own — and the obvious package for it,
 * battery_plus, has no thermal API at all. Since thermal needs a platform call
 * regardless, both come from here and the app gains no new dependency.
 *
 * Everything is read defensively. A device that declines to report its battery must
 * leave the import queue running rather than stopping it forever, so a missing value
 * becomes "unknown" and the policy treats that as permission to continue.
 */
class DeviceConditionsPlugin(private val context: Context) : DeviceConditionsHostApi {

    override fun read(): DeviceConditions {
        val battery = readBatteryStatus()
        return DeviceConditions(
            batteryLevel = battery.level,
            isCharging = battery.isCharging,
            isPowerSaveMode = readPowerSaveMode(),
            thermalState = readThermalState(),
        )
    }

    /** Battery charge and whether the phone is plugged in. */
    private fun readBatteryStatus(): BatteryStatus {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return BatteryStatus(UNKNOWN_BATTERY_LEVEL, false)

        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)

        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val fraction = if (level < 0 || scale <= 0) UNKNOWN_BATTERY_LEVEL else level.toDouble() / scale
        return BatteryStatus(fraction, isCharging)
    }

    /** Whether the user has asked the system to conserve power. */
    private fun readPowerSaveMode(): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return power.isPowerSaveMode
    }

    /**
     * How hot the device is, as the system grades it.
     *
     * `getCurrentThermalStatus` arrived in Android 10. On anything older the honest
     * answer is that we do not know, and the queue proceeds — guessing from a CPU
     * temperature file would need a per-device table that would be wrong on the next
     * phone.
     */
    private fun readThermalState(): ThermalState {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return ThermalState.UNKNOWN
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return ThermalState.UNKNOWN

        return when (power.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> ThermalState.NOMINAL
            PowerManager.THERMAL_STATUS_LIGHT -> ThermalState.FAIR
            PowerManager.THERMAL_STATUS_MODERATE -> ThermalState.FAIR
            PowerManager.THERMAL_STATUS_SEVERE -> ThermalState.SERIOUS
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN,
            -> ThermalState.CRITICAL
            else -> ThermalState.UNKNOWN
        }
    }

    /** Battery charge and charging state read together, since they arrive together. */
    private data class BatteryStatus(val level: Double, val isCharging: Boolean)

    private companion object {
        /** What to report when the platform declines to say. */
        const val UNKNOWN_BATTERY_LEVEL = -1.0
    }
}
