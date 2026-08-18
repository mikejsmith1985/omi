/// Purpose: the queue must be a good guest on someone's phone.
///
/// The failure this guards against has no stack trace: a person starts a backlog before
/// bed and finds a flat, hot phone in the morning. So these tests are about restraint —
/// stopping when it should, and, just as importantly, *not* stopping when it should not,
/// because a queue that pauses too eagerly never finishes a backlog at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/import/import_conditions.dart';

DeviceState state({
  double? battery = 0.8,
  bool charging = false,
  bool powerSave = false,
  bool overheating = false,
}) {
  return DeviceState(
    batteryLevel: battery,
    isCharging: charging,
    isPowerSaveMode: powerSave,
    isOverheating: overheating,
  );
}

/// Heat outranks everything: it is the only condition that damages the device.
void _heatStopsEverything() {
  group('heat stops the queue whatever else is true', () {
    test('pauses when overheating, even on a full battery', () {
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(overheating: true)), QueueDisposition.pausedForHeat);
    });

    test('pauses when overheating, even while charging', () {
      final policy = ImportConditionsPolicy();

      expect(
        policy.evaluate(state(charging: true, overheating: true)),
        QueueDisposition.pausedForHeat,
      );
    });

    test('resumes once the device has cooled', () {
      final policy = ImportConditionsPolicy();
      policy.evaluate(state(overheating: true));

      expect(policy.evaluate(state()), QueueDisposition.proceed);
    });
  });
}

/// Battery Saver is an instruction from the user, not a hint.
void _respectsPowerSaving() {
  group('power saving is respected', () {
    test('pauses on battery when Battery Saver is on', () {
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(powerSave: true)), QueueDisposition.pausedForPowerSaving);
    });

    test('carries on while charging, even with Battery Saver on', () {
      // Plugged in, the instruction is about battery drain that is no longer happening.
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(charging: true, powerSave: true)), QueueDisposition.proceed);
    });
  });
}

/// Low battery pauses — but charging is a clear signal to go ahead.
void _managesBattery() {
  group('battery', () {
    test('pauses below the low-battery threshold', () {
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(battery: 0.15)), QueueDisposition.pausedForBattery);
    });

    test('proceeds comfortably above it', () {
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(battery: 0.5)), QueueDisposition.proceed);
    });

    test('ignores the battery entirely while charging', () {
      // Overnight on a charger is exactly when a backlog should run.
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(battery: 0.05, charging: true)), QueueDisposition.proceed);
    });

    test('proceeds when the platform will not report a level', () {
      // A queue that never runs on such a device is worse than one that occasionally
      // runs when it should not have.
      final policy = ImportConditionsPolicy();

      expect(policy.evaluate(state(battery: null)), QueueDisposition.proceed);
    });
  });
}

/// The hysteresis: one threshold would make the queue flap.
void _doesNotFlapAroundTheThreshold() {
  group('pausing and resuming use different thresholds', () {
    test('does not resume the moment it creeps back over the pause threshold', () {
      final policy = ImportConditionsPolicy();
      expect(policy.evaluate(state(battery: 0.18)), QueueDisposition.pausedForBattery);

      // Just above the pause threshold, well below the resume one. Resuming here would
      // start work that immediately drops the level and pauses again.
      expect(policy.evaluate(state(battery: 0.22)), QueueDisposition.pausedForBattery);
    });

    test('resumes once there is real headroom', () {
      final policy = ImportConditionsPolicy();
      policy.evaluate(state(battery: 0.18));

      expect(policy.evaluate(state(battery: 0.35)), QueueDisposition.proceed);
    });

    test('a charger resumes it immediately, whatever the level', () {
      final policy = ImportConditionsPolicy();
      policy.evaluate(state(battery: 0.10));

      expect(policy.evaluate(state(battery: 0.10, charging: true)), QueueDisposition.proceed);
    });

    test('the resume threshold is genuinely higher than the pause threshold', () {
      // The property the hysteresis depends on. Stated as a test so a later tweak to
      // either constant cannot quietly remove it.
      expect(resumeAboveBatteryLevel, greaterThan(pauseBelowBatteryLevel));
    });
  });
}

/// A pause must read as a state, never as a fault.
void _explainsItselfWithoutAlarming() {
  group('a pause explains itself without sounding like a fault', () {
    test('every paused disposition says why', () {
      for (final disposition in QueueDisposition.values) {
        if (disposition == QueueDisposition.proceed) continue;
        expect(disposition.isPaused, isTrue);
        expect(disposition.explanation, isNotEmpty);
      }
    });

    test('proceeding has nothing to explain', () {
      expect(QueueDisposition.proceed.isPaused, isFalse);
      expect(QueueDisposition.proceed.explanation, isEmpty);
    });
  });
}

void main() {
  _heatStopsEverything();
  _respectsPowerSaving();
  _managesBattery();
  _doesNotFlapAroundTheThreshold();
  _explainsItselfWithoutAlarming();
}
