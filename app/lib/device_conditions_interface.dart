import 'package:pigeon/pigeon.dart';

// Contract for reading the phone's own power and thermal state.
// Regenerate with: dart run pigeon --input lib/device_conditions_interface.dart
//
// Why this exists rather than a package: the app already reads *watch* and *BLE device*
// battery through pigeon_interfaces.dart, but nothing reports the phone's own. The
// obvious candidate, battery_plus, would only cover half of it — it has no thermal API
// at all — so a platform channel is needed for thermal regardless. Given that, one
// contract covering both beats a dependency plus a channel, and adds nothing to the
// app's dependency list for an upstream reviewer to weigh.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/gen/device_conditions_pigeon.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/DeviceConditions/DeviceConditionsPigeon.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'DeviceConditionsPigeonError'),
    kotlinOut: 'android/app/src/main/kotlin/com/friend/ios/deviceconditions/DeviceConditionsPigeon.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.friend.ios.deviceconditions',
      errorClassName: 'DeviceConditionsPigeonError',
    ),
    dartPackageName: 'omi_device_conditions',
  ),
)

/// How hot the device is, as the operating system sees it.
///
/// Both platforms report a graded state rather than a temperature, which is what we
/// want: the grades already account for the hardware, and a raw figure would need a
/// per-device threshold table that would be wrong on the next phone.
enum ThermalState {
  /// Nothing to worry about.
  nominal,

  /// Warm. Sustained heavy work is starting to cost.
  fair,

  /// Hot. The system is throttling, and a long import will make it worse.
  serious,

  /// Very hot. The system is taking measures of its own.
  critical,

  /// The platform did not say.
  unknown,
}

/// The phone's power and thermal state at one moment.
class DeviceConditions {
  /// Battery charge from 0 to 1, or -1 when the platform declined to say.
  double batteryLevel;

  /// Whether the phone is plugged in.
  ///
  /// The single most important field here: a queue that would be rude to run on
  /// battery is entirely reasonable to run while charging, which is exactly when
  /// someone would leave a backlog importing overnight.
  bool isCharging;

  /// Whether the user has asked the system to conserve power.
  ///
  /// Distinct from a low battery: it is an explicit instruction, and running a long
  /// background job through it is ignoring what the user asked for.
  bool isPowerSaveMode;

  /// How hot the device is.
  ThermalState thermalState;

  DeviceConditions(this.batteryLevel, this.isCharging, this.isPowerSaveMode, this.thermalState);
}

/// Dart -> native.
@HostApi()
abstract class DeviceConditionsHostApi {
  /// Reads the phone's current power and thermal state.
  ///
  /// Polled rather than subscribed: the queue only needs this between recordings, and
  /// a subscription would keep a receiver alive for the entire life of the app to
  /// serve something consulted once every few minutes.
  DeviceConditions read();
}
