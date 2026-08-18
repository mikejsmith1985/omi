// Regression cover for a ring clear that arrives while a transfer is running.

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/wals/ring_storage_sync.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';

/// Records the firmware calls the clear path makes, so a test can assert the
/// ring was actually told to clear rather than only that the list shrank.
class _RecordingConnection implements DeviceConnection {
  int clearRingCalls = 0;
  int stopStorageSyncCalls = 0;

  @override
  Future<bool> clearRing() async {
    clearRingCalls++;
    return true;
  }

  @override
  Future<bool> stopStorageSync() async {
    stopStorageSyncCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpyListener implements IWalSyncListener {
  int walUpdatedCount = 0;

  @override
  void onWalUpdated() => walUpdatedCount++;

  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) {}
}

Wal _pendingRingWal(int timerStart) => Wal(
      timerStart: timerStart,
      codec: BleAudioCodec.opus,
      seconds: 60,
      status: WalStatus.miss,
      storage: WalStorage.sdcard,
      device: 'omi-ring',
      filePath: 'ring_$timerStart.bin',
    );

void main() {
  late _RecordingConnection connection;
  late _SpyListener listener;
  late RingStorageSyncImpl sync;

  setUp(() {
    connection = _RecordingConnection();
    listener = _SpyListener();
    sync = RingStorageSyncImpl(listener, connectionResolver: (_) async => connection)
      ..setDevice(BtDevice(id: 'omi-ring', name: 'Omi Ring', type: DeviceType.omi, rssi: -50));
  });

  test('clears the ring when no transfer is running', () async {
    sync.testWals = [_pendingRingWal(1000)];

    await sync.deleteAllPendingWals();

    expect(connection.clearRingCalls, 1);
    expect(sync.testWals, isEmpty);
  });

  test('still clears the ring when the request arrives mid-transfer', () async {
    sync.testWals = [_pendingRingWal(1000), _pendingRingWal(2000)];
    sync.testIsSyncing = true;

    final clearing = sync.deleteAllPendingWals();
    // The transfer loop reaches its `finally` once the cancel lands.
    sync.testFinishSync();
    await clearing;

    // Before the fix this returned early: no STOP, no clear, and the pending
    // recordings stayed on the ring while the caller reported them deleted.
    expect(connection.stopStorageSyncCalls, 1);
    expect(connection.clearRingCalls, 1);
    expect(sync.testWals, isEmpty);
    expect(listener.walUpdatedCount, greaterThan(0));
  });

  test('leaves the device alone when nothing is pending', () async {
    sync.testWals = [];

    await sync.deleteAllPendingWals();

    expect(connection.clearRingCalls, 0);
  });
}
