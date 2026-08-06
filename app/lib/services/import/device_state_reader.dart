/// Purpose: turn what the platform reports into what the queue's policy reasons about.
///
/// The translation is small but it is where two judgements live, and both are easier to
/// get wrong than they look.
///
/// **A missing battery level means "carry on", not "stop".** Some devices decline to
/// report it. Treating an absent reading as low would leave the queue permanently
/// paused on those phones, which is a worse failure than occasionally importing when
/// the battery was lower than ideal.
///
/// **"Serious" is where heat starts to matter.** Below that the system is warm but
/// coping, and pausing there would stop a backlog on any phone doing normal work.
/// At serious the system is already throttling, so continuing makes things worse
/// rather than merely warm.
///
/// **Requires code generation**: dart run pigeon --input lib/device_conditions_interface.dart
library;

import 'package:omi/gen/device_conditions_pigeon.g.dart';
import 'package:omi/services/import/import_conditions.dart';
import 'package:omi/services/import/import_queue.dart';

/// The battery value the platforms use to mean "we will not say".
const double unknownBatteryLevel = -1;

/// Reads the phone's power and thermal state through the platform bridge.
class PlatformDeviceStateReader implements DeviceStateReader {
  final DeviceConditionsHostApi _api;

  /// Creates a reader over the generated bridge.
  PlatformDeviceStateReader() : _api = DeviceConditionsHostApi();

  /// Creates a reader over a supplied bridge, for tests.
  PlatformDeviceStateReader.withApi(this._api);

  @override
  Future<DeviceState> read() async {
    try {
      return _translate(await _api.read());
    } on Object {
      // A platform that cannot answer must not stop the queue. Reporting nothing and
      // letting the policy proceed is the same choice made for an unknown battery
      // level, and for the same reason.
      return const DeviceState(
        batteryLevel: null,
        isCharging: false,
        isPowerSaveMode: false,
        isOverheating: false,
      );
    }
  }

  /// Converts one platform reading into the policy's terms.
  DeviceState _translate(DeviceConditions conditions) {
    return DeviceState(
      batteryLevel: conditions.batteryLevel < 0 ? null : conditions.batteryLevel,
      isCharging: conditions.isCharging,
      isPowerSaveMode: conditions.isPowerSaveMode,
      isOverheating: isOverheatingState(conditions.thermalState),
    );
  }
}

/// Whether a thermal grade is hot enough that more work would make things worse.
///
/// Exposed so the threshold is testable and stated once, rather than being a comparison
/// buried in a translation function where a later change would go unnoticed.
bool isOverheatingState(ThermalState state) {
  switch (state) {
    case ThermalState.serious:
    case ThermalState.critical:
      return true;
    case ThermalState.nominal:
    case ThermalState.fair:
    case ThermalState.unknown:
      // Unknown proceeds deliberately. Android below 10 cannot report thermal state at
      // all, and a queue that never runs there would be a regression for those users.
      return false;
  }
}
