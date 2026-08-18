// Regression cover for clearing device recordings when the firmware delete fails.

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/wals/storage_sync.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';

/// Deletes every file except the ones named in [rejectFileNums], which report
/// failure the way firmware does when a file cannot be removed.
class _PartialDeleteConnection implements DeviceConnection {
  _PartialDeleteConnection({this.rejectFileNums = const {}});

  final Set<int> rejectFileNums;
  final List<int> deleteAttempts = [];

  @override
  Future<bool> deleteStorageFile(int fileIndex) async {
    deleteAttempts.add(fileIndex);
    return !rejectFileNums.contains(fileIndex);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpyListener implements IWalSyncListener {
  @override
  void onWalUpdated() {}

  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) {}
}

Wal _deviceWal({required int timerStart, required int fileNum, required WalStatus status}) => Wal(
      timerStart: timerStart,
      codec: BleAudioCodec.opus,
      seconds: 60,
      status: status,
      storage: WalStorage.sdcard,
      device: 'omi-1',
      filePath: 'device_$timerStart.bin',
      fileNum: fileNum,
    );

void main() {
  late _SpyListener listener;

  StorageSyncImpl buildSync(DeviceConnection? connection) =>
      StorageSyncImpl(listener, connectionResolver: (_) async => connection)
        ..setDevice(BtDevice(id: 'omi-1', name: 'Omi', type: DeviceType.omi, rssi: -50));

  setUp(() => listener = _SpyListener());

  test('keeps a recording the firmware refused to delete', () async {
    final connection = _PartialDeleteConnection(rejectFileNums: {2});
    final sync = buildSync(connection)
      ..testWals = [
        _deviceWal(timerStart: 1000, fileNum: 1, status: WalStatus.miss),
        _deviceWal(timerStart: 2000, fileNum: 2, status: WalStatus.miss),
        _deviceWal(timerStart: 3000, fileNum: 3, status: WalStatus.miss),
      ];

    await sync.deleteAllPendingWals();

    // File 2 is still on the device, so it must still be listed — before the
    // fix it was dropped and the recording became invisible and unretryable.
    expect(sync.testWals.map((w) => w.timerStart), [2000]);
    expect(connection.deleteAttempts, [3, 2, 1]);
  });

  test('keeps everything when the device cannot be reached', () async {
    final sync = buildSync(null)
      ..testWals = [
        _deviceWal(timerStart: 1000, fileNum: 1, status: WalStatus.synced),
        _deviceWal(timerStart: 2000, fileNum: 2, status: WalStatus.synced),
      ];

    await sync.deleteAllSyncedWals();

    expect(sync.testWals.length, 2);
  });

  test('drops every recording the firmware confirmed deleted', () async {
    final connection = _PartialDeleteConnection();
    final sync = buildSync(connection)
      ..testWals = [
        _deviceWal(timerStart: 1000, fileNum: 1, status: WalStatus.miss),
        _deviceWal(timerStart: 2000, fileNum: 2, status: WalStatus.miss),
      ];

    await sync.deleteAllPendingWals();

    expect(sync.testWals, isEmpty);
  });

  test('re-indexes a survivor above the file that was deleted', () async {
    // Firmware shifts higher indices down by one after each delete, so the
    // recording that outlived the delete has to follow the device's numbering.
    final connection = _PartialDeleteConnection(rejectFileNums: {1});
    final sync = buildSync(connection)
      ..testWals = [
        _deviceWal(timerStart: 1000, fileNum: 1, status: WalStatus.miss),
        _deviceWal(timerStart: 2000, fileNum: 2, status: WalStatus.miss),
      ];

    await sync.deleteAllPendingWals();

    expect(sync.testWals.single.timerStart, 1000);
    expect(sync.testWals.single.fileNum, 1);
  });
}
