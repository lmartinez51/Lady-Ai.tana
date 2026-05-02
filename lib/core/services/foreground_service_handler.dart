import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:aitana/objectbox.g.dart';
import 'package:aitana/core/domain/entities/geofence_record.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

/// @brief Entry point for the foreground service isolate.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ForegroundServiceHandler());
}

/// @brief Handler for the persistent foreground service.
/// @note This class runs in a separate isolate.
class ForegroundServiceHandler extends TaskHandler {
  final NetworkInfo _networkInfo = NetworkInfo();

  Store? _store;
  Box<GeofenceRecord>? _box;
  static const MethodChannel _geofenceChannel = MethodChannel(
    NativeChannels.geofence,
  );

  static const NotificationIconData _icon = NotificationIconData(
    resType: ResourceType.mipmap,
    resPrefix: ResourcePrefix.ic,
    name: 'launcher',
  );

  @override
  void onStart(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('🚀 [ForegroundService] isolate started at $timestamp');
    await _initDatabase();
    _updateStatus();
  }

  Future<void> _initDatabase() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(docsDir.path, "aitana_core_v1");

      // Ensure directory exists (mirrors ObjectBoxService logic)
      final dir = Directory(dbPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // Re-open or attach to the store in this isolate
      try {
        _store = await openStore(directory: dbPath);
      } catch (e) {
        // If error code is 10001 (already open), we must attach to the existing store
        if (e.toString().contains('10001')) {
          debugPrint(
            '⚠️ [ForegroundService] Database locked. Attaching to existing store reference...',
          );
          _store = Store.attach(getObjectBoxModel(), dbPath);
        } else {
          rethrow;
        }
      }

      _box = _store!.box<GeofenceRecord>();
      debugPrint(
        '📦 [ForegroundService] ObjectBox Store initialized/attached in isolate.',
      );
    } catch (e) {
      debugPrint(
        '🔴 [ForegroundService] Error initializing ObjectBox in isolate: $e',
      );
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    _updateStatus();
    await _performReconciliation();
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('🛑 [ForegroundService] isolate destroyed at $timestamp');
    _store?.close();
  }

  /// @brief Detective Logic: Checks if we are connected to a target SSID and triggers pending geofences.
  Future<void> _performReconciliation() async {
    if (_box == null) return;

    // ── Auto-Shutdown Logic ──────────────────────────────────────────────────
    // Check for remaining PENDING geofences across all locations.
    // If count is 0, we terminate to preserve battery.
    final pendingCount = _box!
        .query(GeofenceRecord_.status.equals('PENDING'))
        .build()
        .count();

    if (pendingCount == 0) {
      debugPrint(
        '🟢 [Auto-Shutdown] No pending geofences left. Surveillance terminated to save battery.',
      );
      // We call stopService to ensure the notification disappears and the isolate closes.
      await ForegroundServiceControl.stopService();
      return;
    }

    try {
      // 1. Get current SSID
      String? ssid = await _networkInfo.getWifiName();
      if (ssid == null || ssid.isEmpty) return;

      // Normalize SSID (Android often returns it wrapped in quotes)
      final cleanSsid = ssid.replaceAll('"', '').trim();
      final lowerSsid = cleanSsid.toLowerCase();

      // 2. Fetch all PENDING geofences
      final allPending = _box!
          .query(GeofenceRecord_.status.equals('PENDING'))
          .build()
          .find();

      if (allPending.isEmpty) return;

      bool anyTriggered = false;

      for (final record in allPending) {
        // 3. Logic: Check if current SSID is in the record's validSsids list (case-insensitive)
        final bool isMatch = record.validSsids.any(
          (s) => s.toLowerCase() == lowerSsid,
        );

        if (isMatch) {
          debugPrint(
            '🎯 [ForegroundService] Detective matched SSID "$cleanSsid" for record #${record.id} ("${record.title}"). Triggering...',
          );

          // 4. Trigger system-level notification via native bridge
          await _geofenceChannel.invokeMethod('fireSyntheticTrigger', {
            'id': record.id.toString(),
          });

          // 5. Mark as TRIGGERED (Completed) in local DB to prevent duplicates
          record.status = 'TRIGGERED';
          record.triggeredAt = DateTime.now();
          _box!.put(record);

          debugPrint(
            '✅ [ForegroundService] Reconciliation Triggered & Marked: ${record.title} (#${record.id})',
          );
          anyTriggered = true;
        }
      }

      if (!anyTriggered) {
        // Optional: debug log for silent monitoring
        // debugPrint('🔍 [ForegroundService] No SSID match found for $cleanSsid across ${allPending.length} records.');
      }
    } catch (e) {
      debugPrint('🔴 [ForegroundService] Reconciliation Error: $e');
    }
  }

  /// @brief Helper to update the notification with current connectivity status.
  Future<void> _updateStatus() async {
    final String? ssid = await _networkInfo.getWifiName();
    final String cleanSsid = (ssid != null && ssid.isNotEmpty)
        ? ssid.replaceAll('"', '').trim()
        : 'Disconnected';

    final String statusText = 'Network: $cleanSsid';

    FlutterForegroundTask.updateService(
      notificationTitle: 'Aitana Surveillance Active',
      notificationText: statusText,
      notificationIcon: _icon,
    );
  }
}

/// @brief Controller to initialize and manage the foreground service lifecycle.
class ForegroundServiceControl {
  /// @brief Track if the service is currently running.
  static final ValueNotifier<bool> isServiceRunning = ValueNotifier<bool>(
    false,
  );

  /// @brief Configures the foreground task settings.
  static Future<void> initForegroundTask() async {
    isServiceRunning.value = await FlutterForegroundTask.isRunningService;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'aitana_foreground_service',
        channelName: 'Aitana Background Monitor',
        channelDescription: 'Maintains geofence and SSID detection active.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 30000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// @brief Starts the foreground service if not already running.
  static Future<ServiceRequestResult> startService() async {
    if (await FlutterForegroundTask.isRunningService) {
      final result = await FlutterForegroundTask.restartService();
      if (result.success) isServiceRunning.value = true;
      return result;
    } else {
      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'Aitana Surveillance Active',
        notificationText: 'Initializing persistent monitor...',
        notificationIcon: ForegroundServiceHandler._icon,
        callback: startCallback,
      );
      if (result.success) isServiceRunning.value = true;
      return result;
    }
  }

  /// @brief Stops the foreground service.
  static Future<ServiceRequestResult> stopService() async {
    final result = await FlutterForegroundTask.stopService();
    if (result.success) isServiceRunning.value = false;
    return result;
  }
}
