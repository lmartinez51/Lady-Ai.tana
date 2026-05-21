import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aitana/core/constants/native_channels.dart';
import 'package:aitana/core/database/objectbox_service.dart';
import 'package:aitana/features/geofencing/repositories/geofence_repository.dart';
import 'package:aitana/features/geofencing/services/offline_location_registry.dart';
import 'package:aitana/core/services/foreground_service_handler.dart';

class GeofenceService {
  // Singleton pattern
  static final GeofenceService _instance = GeofenceService._internal();
  factory GeofenceService() => _instance;

  GeofenceService._internal() {
    // Listen for callbacks coming FROM Kotlin → Dart (e.g., geofence ENTER events).
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  static const MethodChannel _channel = MethodChannel(NativeChannels.geofence);

  /// Convenience accessor — safe because ObjectBoxService.create() always runs in main() first.
  GeofenceRepository get _repo => ObjectBoxService.instance.geofenceRepository;

  /// Initializes the service and triggers the startup state reconciliation.
  Future<void> init() async {
    await syncGeofenceState();
    _repo.purgeOldRecords(hoursOld: 48);

    // ── Reboot Survival Logic ────────────────────────────────────────────────
    // Native geofences (Google Play Services) are lost on device reboots.
    // We must re-register all PENDING records from ObjectBox into the OS.
    await _reRegisterPendingGeofences();
    final pending = _repo.getPendingGeofences();

    // If there are still pending geofences, ensure the foreground service is active
    if (pending.isNotEmpty) {
      debugPrint(
        '🛡️ [GeofenceService] Active geofences detected. Ensuring foreground service is running.',
      );
      await ForegroundServiceControl.startService();
    } else {
      await _stopSurveillanceIfNoPending(reason: 'startup reconciliation');
    }

    debugPrint('🧹 [GeofenceService] Auto-sweeper finished...');
  }

  Future<void> _stopSurveillanceIfNoPending({required String reason}) async {
    if (_repo.getPendingGeofences().isNotEmpty) return;

    await ForegroundServiceControl.refreshServiceState();
    if (!ForegroundServiceControl.isServiceRunning.value) return;

    debugPrint('No pending geofences after $reason. Stopping Surveillance.');
    await ForegroundServiceControl.stopService();
  }

  /// Restores native monitoring for all geofences that are still PENDING in ObjectBox.
  Future<void> _reRegisterPendingGeofences() async {
    final pending = _repo.getPendingGeofences();
    if (pending.isEmpty) return;

    debugPrint(
      '🔄 [GeofenceService] Restoring ${pending.length} native geofences from persistence...',
    );

    for (final record in pending) {
      // Re-resolve location to get fresh coordinates (or use cached ones if we added them to the record)
      // For now, we resolve by name again.
      // Ideally, GeofenceRecord should store lat/lng/radius to avoid registry mismatches.
      final locationDef = OfflineLocationRegistry.resolveLocation(
        record.locationKey,
      );

      if (locationDef != null) {
        await addGeofence(
          id: record.id.toString(),
          title: record.title,
          lat: locationDef.lat,
          lng: locationDef.lng,
          radius: locationDef.radius,
          targetSsids: locationDef.targetSsids,
        );
      } else {
        debugPrint(
          '⚠️ [GeofenceService] Could not restore record #${record.id}: Unknown location "${record.locationKey}"',
        );
      }
    }
  }

  /// Synchronizes the geofence state from Kotlin to Dart on startup.
  Future<void> syncGeofenceState() async {
    try {
      // 1. Sync triggered geofences
      final List<dynamic>? rawIds = await _channel.invokeMethod(
        'getTriggeredGeofences',
      );
      final triggeredIds = rawIds?.cast<String>() ?? [];

      // 2. Sync registered/active geofences from Kotlin
      final List<dynamic>? rawRegisteredIds = await _channel.invokeMethod(
        'getRegisteredGeofences',
      );

      final pendingRecords = _repo.getPendingGeofences();

      for (final record in pendingRecords) {
        final recordIdStr = record.id.toString();

        if (triggeredIds.contains(recordIdStr)) {
          _repo.markAsTriggered(record.id);
          debugPrint(
            '🔄 [GeofenceService] Synced record #${record.id} to TRIGGERED from Kotlin state.',
          );
        } else if (rawRegisteredIds != null) {
          final registeredIds = rawRegisteredIds.cast<String>();
          if (!registeredIds.contains(recordIdStr)) {
            // It is PENDING in Dart, but NOT registered in Kotlin titles map!
            // This means it was dismissed or exited natively while Dart was offline.
            _repo.markAsTriggered(record.id);
            debugPrint(
              '🔄 [GeofenceService] Synced record #${record.id} to TRIGGERED because it was cleared natively.',
            );
          }
        }
      }
    } catch (e) {
      debugPrint('🔴 [GeofenceService] Error syncing geofence state: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Kotlin → Dart callback handler
  // ---------------------------------------------------------------------------

  /// Handles MethodChannel calls invoked FROM the native Kotlin layer.
  Future<void> _handleNativeCallback(MethodCall call) async {
    switch (call.method) {
      case 'onGeofenceTriggered':
        final rawId = call.arguments as String?;
        if (rawId == null) {
          debugPrint(
            '⚠️ [GeofenceService] onGeofenceTriggered received null ID.',
          );
          return;
        }
        final id = int.tryParse(rawId);
        if (id == null) {
          debugPrint(
            '⚠️ [GeofenceService] Invalid triggered ID (not an int): $rawId',
          );
          return;
        }
        final success = _repo.markAsTriggered(id);
        if (success) {
          await _stopSurveillanceIfNoPending(reason: 'native trigger');
        }
        debugPrint(
          success
              ? '✅ [GeofenceService] GeofenceRecord #$id marked as TRIGGERED.'
              : '⚠️ [GeofenceService] GeofenceRecord #$id not found in DB.',
        );
        break;

      case 'onGeofenceCleared':
        final rawId = call.arguments as String?;
        if (rawId == null) {
          debugPrint(
            '⚠️ [GeofenceService] onGeofenceCleared received null ID.',
          );
          return;
        }
        final id = int.tryParse(rawId);
        if (id == null) {
          debugPrint(
            '⚠️ [GeofenceService] Invalid cleared ID (not an int): $rawId',
          );
          return;
        }
        final success = _repo.markAsTriggered(id);
        if (success) {
          await _stopSurveillanceIfNoPending(reason: 'native clear');
        }
        debugPrint(
          success
              ? '✅ [GeofenceService] GeofenceRecord #$id cleared natively, marked as TRIGGERED in DB.'
              : '⚠️ [GeofenceService] GeofenceRecord #$id not found in DB.',
        );
        break;

      default:
        debugPrint(
          '⚠️ [GeofenceService] Unknown native method: ${call.method}',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Dart → Kotlin calls
  // ---------------------------------------------------------------------------

  /// Requests the necessary Fine and Background location permissions natively.
  Future<bool> requestPermissions() async {
    try {
      final String result = await _channel.invokeMethod(
        'requestLocationPermissions',
      );
      return result == 'granted';
    } on PlatformException catch (e) {
      debugPrint('🔴 [GeofenceService] Permission Error: ${e.message}');
      return false;
    } catch (e) {
      debugPrint(
        '🔴 [GeofenceService] Unexpected error requesting permissions: $e',
      );
      return false;
    }
  }

  /// Sends coordinates to the native layer to be monitored by Google Play Services.
  /// The [id] MUST be the String representation of the ObjectBox GeofenceRecord ID
  /// so that the trigger callback can look it up and mark it as TRIGGERED.
  Future<bool> addGeofence({
    required String id,
    required String title,
    required double lat,
    required double lng,
    double radius = 200.0,
    List<String> targetSsids = const [],
  }) async {
    final hasPermissions = await requestPermissions();
    if (!hasPermissions) {
      debugPrint(
        '🔴 [GeofenceService] Cannot add Geofence: Permissions denied.',
      );
      return false;
    }

    try {
      final String result = await _channel.invokeMethod('addGeofence', {
        'id': id,
        'title': title,
        'lat': lat,
        'lng': lng,
        'radius': radius,
        'targetSsids': targetSsids,
      });

      if (result == 'success') {
        debugPrint(
          '🎯 [GeofenceService] Geofence successfully added natively: $id',
        );

        // ── Auto-Wake Logic ──────────────────────────────────────────────────
        // Ensure the Detective (Foreground Service) is awake to monitor SSIDs.
        if (!ForegroundServiceControl.isServiceRunning.value) {
          debugPrint(
            '🟢 [Auto-Wake] New geofence created. Waking up the surveillance service.',
          );
          await ForegroundServiceControl.startService();
        }
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint('🔴 [GeofenceService] Native Error: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('🔴 [GeofenceService] Unexpected Error: $e');
      return false;
    }
  }

  /// High-level function: Takes a place name, looks it up in the external registry,
  /// and adds the geofence.
  ///
  /// Executes the ID Handshake:
  ///   1. Persists a PENDING [GeofenceRecord] in ObjectBox to obtain a unique integer ID.
  ///   2. Resolves [placeName] to coordinates via [OfflineLocationRegistry].
  ///   3. Passes the integer ID (as a String) to Kotlin as the Android `requestId`.
  ///
  /// If coordinate resolution fails, the PENDING record is immediately marked FAILED
  /// in ObjectBox to maintain log integrity.
  Future<bool> addGeofenceByName({
    required String taskId,
    required String placeName,
    double radius = 200.0,
  }) async {
    // ── Step 1: Resolve coordinates ──────────────────────────────────────────
    final locationDef = OfflineLocationRegistry.resolveLocation(placeName);

    if (locationDef == null) {
      debugPrint('⚠️ [GeofenceService] Unknown location: $placeName.');
      return false;
    }

    debugPrint(
      '🔍 [GeofenceService] Location resolved! $placeName → ${locationDef.lat}, ${locationDef.lng}',
    );

    // ── Step 2: Persist first → obtain authoritative integer ID ─────────────
    // We pass the valid SSIDs from the registry to the persistence layer
    final recordId = _repo.addPendingGeofence(
      taskId,
      placeName,
      validSsids: locationDef.targetSsids,
    );
    debugPrint(
      '🗄️ [GeofenceService] Created GeofenceRecord #$recordId (PENDING) for "$taskId" @ "$placeName"',
    );

    // ── Step 3: Send the integer ID to Kotlin as the requestId ──────────────
    final success = await addGeofence(
      id: recordId.toString(), // integer ID → String for the MethodChannel
      title: taskId,
      lat: locationDef.lat,
      lng: locationDef.lng,
      radius: locationDef.radius,
      targetSsids: locationDef.targetSsids,
    );

    if (!success) {
      debugPrint(
        '🔴 [GeofenceService] Native registration failed for record #$recordId.',
      );
    }

    return success;
  }

  /// Removes a geofence both natively and locally from ObjectBox.
  Future<void> removeGeofenceRecord(int id) async {
    try {
      // 1. Unregister natively to clean up Android state (Play Services, Snipe maps, etc.)
      await _channel.invokeMethod('removeGeofence', {'id': id.toString()});

      // 2. Remove locally from ObjectBox
      _repo.deleteGeofence(id);
      await _stopSurveillanceIfNoPending(reason: 'manual geofence removal');

      debugPrint(
        '🗑️ [GeofenceService] Geofence #$id removed natively and locally.',
      );
    } on PlatformException catch (e) {
      debugPrint(
        '🔴 [GeofenceService] Native Error removing geofence #$id: ${e.message}',
      );
    } catch (e) {
      debugPrint(
        '🔴 [GeofenceService] Unexpected Error removing geofence #$id: $e',
      );
    }
  }

  /// Removes all geofences both natively and locally.
  Future<void> clearAllGeofenceRecords() async {
    try {
      final allRecords = _repo.getAllRecords();

      // Remove each native registration one by one
      for (final record in allRecords) {
        try {
          await _channel.invokeMethod('removeGeofence', {
            'id': record.id.toString(),
          });
        } catch (e) {
          debugPrint(
            '⚠️ [GeofenceService] Native Error removing geofence #${record.id}: $e',
          );
          // Continue with the loop even if one fails
        }
      }

      // Wipe the entire ObjectBox table
      _repo.deleteAllGeofences();
      await _stopSurveillanceIfNoPending(reason: 'manual clear all');

      debugPrint(
        '🧹 [GeofenceService] All geofences cleared natively and locally.',
      );
    } catch (e) {
      debugPrint(
        '🔴 [GeofenceService] Unexpected Error clearing all geofences: $e',
      );
    }
  }
}
