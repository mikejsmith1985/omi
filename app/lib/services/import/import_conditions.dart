/// Purpose: decide whether now is a reasonable moment to import another recording.
///
/// FR-022. A backlog of twenty hours of audio is a lot of sustained work for a phone,
/// and the failure this prevents is not a crash — it is someone starting an import
/// before bed and finding a flat, hot phone in the morning. The queue must be a good
/// guest: enthusiastic when plugged in, restrained on battery, and silent when the user
/// has explicitly asked the system to conserve power.
///
/// Two rules shape everything here:
///
///   * **Pausing and resuming use different thresholds.** A single threshold makes the
///     queue flap — pause at 20%, charge to 20.1%, resume, drop, pause again — which
///     is worse than either state. So resuming requires more headroom than pausing
///     required, and the gap between them is the hysteresis.
///   * **A pause is never a failure.** The recordings are still queued and will run
///     when conditions allow. Reporting it as an error would send the user looking for
///     something to fix.
library;

/// Charge below which the queue stops when running on battery.
///
/// A fifth of the battery is enough for a normal day's incidental use. Spending it on
/// a backlog that could equally run tonight while charging is a bad trade the user
/// never asked for.
const double pauseBelowBatteryLevel = 0.20;

/// Charge required to start again after a low-battery pause.
///
/// Deliberately above [pauseBelowBatteryLevel]: the gap is what stops the queue
/// flapping around a single threshold.
const double resumeAboveBatteryLevel = 0.30;

/// What the queue should do about the device's current state.
enum QueueDisposition {
  /// Carry on.
  proceed,

  /// Wait — the battery is too low to spend on a backlog.
  pausedForBattery,

  /// Wait — the device is too hot, and more work would make it worse.
  pausedForHeat,

  /// Wait — the user has asked the system to conserve power.
  pausedForPowerSaving,
}

/// Whether this disposition means the queue is waiting.
extension QueueDispositionState on QueueDisposition {
  /// True when the queue should not start another recording.
  bool get isPaused => this != QueueDisposition.proceed;

  /// A short explanation, for showing beside a paused queue.
  ///
  /// Worded as a state rather than a problem: the queue is waiting on purpose and will
  /// continue on its own, and the user has nothing to fix.
  String get explanation {
    switch (this) {
      case QueueDisposition.proceed:
        return '';
      case QueueDisposition.pausedForBattery:
        return 'Paused until the battery is charged a little more.';
      case QueueDisposition.pausedForHeat:
        return 'Paused while your phone cools down.';
      case QueueDisposition.pausedForPowerSaving:
        return 'Paused while Battery Saver is on.';
    }
  }
}

/// The device state the queue reasons about.
///
/// A plain value rather than the generated Pigeon type so the policy can be tested
/// without a platform channel, and so a contract change does not ripple into the rules.
class DeviceState {
  /// Battery charge from 0 to 1, or null when the platform declined to say.
  final double? batteryLevel;

  /// Whether the phone is plugged in.
  final bool isCharging;

  /// Whether the user has asked the system to conserve power.
  final bool isPowerSaveMode;

  /// Whether the device is hot enough that more work would make things worse.
  final bool isOverheating;

  /// Creates a device state.
  const DeviceState({
    required this.batteryLevel,
    required this.isCharging,
    required this.isPowerSaveMode,
    required this.isOverheating,
  });
}

/// Decides when the queue may run, with hysteresis so it does not flap.
class ImportConditionsPolicy {
  bool _wasPausedForBattery = false;

  /// What the queue should do given [state].
  ///
  /// Heat is checked before power, and power before battery, because that is the order
  /// of how bad it is to ignore each: overheating damages the device, power-save mode
  /// is an explicit instruction from the user, and a low battery is merely rude.
  QueueDisposition evaluate(DeviceState state) {
    if (state.isOverheating) return QueueDisposition.pausedForHeat;
    if (state.isPowerSaveMode && !state.isCharging) return QueueDisposition.pausedForPowerSaving;
    return _evaluateBattery(state);
  }

  /// Applies the battery rule, remembering whether it is currently pausing.
  ///
  /// Charging bypasses it entirely. Someone who has plugged the phone in has said what
  /// they want to happen to the battery, and overnight on a charger is precisely when a
  /// backlog should run.
  QueueDisposition _evaluateBattery(DeviceState state) {
    if (state.isCharging) {
      _wasPausedForBattery = false;
      return QueueDisposition.proceed;
    }

    final level = state.batteryLevel;
    // An unknown battery level must not stop the queue. Some devices decline to report
    // it, and a queue that never runs on those is a worse outcome than one that runs
    // when it should not have.
    if (level == null) return QueueDisposition.proceed;

    final threshold = _wasPausedForBattery ? resumeAboveBatteryLevel : pauseBelowBatteryLevel;
    _wasPausedForBattery = level < threshold;
    return _wasPausedForBattery ? QueueDisposition.pausedForBattery : QueueDisposition.proceed;
  }
}
