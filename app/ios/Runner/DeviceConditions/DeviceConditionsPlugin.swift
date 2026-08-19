import Foundation
import UIKit

/// Reports the phone's own power and thermal state.
///
/// The app already reads *watch* and *BLE device* battery through the main Pigeon
/// contract, but nothing reported the phone's own — and battery_plus, the obvious
/// package for it, has no thermal API at all. Since thermal needs a platform call
/// regardless, both come from here and the app gains no new dependency.
///
/// Every value is read defensively. A device that declines to report its battery must
/// leave the import queue running rather than stopping it forever, so a missing value
/// becomes "unknown" and the policy treats that as permission to continue.
final class DeviceConditionsPlugin: NSObject, DeviceConditionsHostApi {

    /// What to report when the platform declines to say.
    private static let unknownBatteryLevel: Double = -1

    override init() {
        super.init()
        // Battery reporting is off by default and returns -1 until it is enabled.
        // Enabling it here rather than at each read keeps the first reading truthful;
        // the level is not populated instantly after the switch is flipped.
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func read() throws -> DeviceConditions {
        return DeviceConditions(
            batteryLevel: Self.readBatteryLevel(),
            isCharging: Self.readIsCharging(),
            isPowerSaveMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: Self.readThermalState()
        )
    }

    /// Battery charge from 0 to 1, or the unknown marker.
    private static func readBatteryLevel() -> Double {
        let level = Double(UIDevice.current.batteryLevel)
        return level < 0 ? unknownBatteryLevel : level
    }

    /// Whether the phone is plugged in.
    ///
    /// `.full` counts as charging: a phone sitting at 100% on a charger is the most
    /// favourable moment there is to work through a backlog.
    private static func readIsCharging() -> Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return true
        default:
            return false
        }
    }

    /// How hot the device is, as the system grades it.
    private static func readThermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }
}
