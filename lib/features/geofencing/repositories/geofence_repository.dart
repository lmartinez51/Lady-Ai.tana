import 'package:aitana/core/domain/entities/geofence_record.dart';
import 'package:aitana/objectbox.g.dart';
import 'package:flutter/foundation.dart';

/// Repository that handles all persistence operations for [GeofenceRecord] entities.
///
/// Accepts an already-initialized ObjectBox [Store] — it never opens its own.
/// This ensures the entire app shares a single Store instance (via [ObjectBoxService]).
class GeofenceRepository {
  final Box<GeofenceRecord> _box;

  GeofenceRepository(Store store) : _box = store.box<GeofenceRecord>();

  // ---------------------------------------------------------------------------
  // Write operations
  // ---------------------------------------------------------------------------

  /// Creates a new [GeofenceRecord] with status "PENDING" and inserts it.
  ///
  /// Returns the ObjectBox-assigned ID of the new record.
  int addPendingGeofence(String title, String locationKey) {
    final record = GeofenceRecord(
      title: title,
      locationKey: locationKey,
      status: 'PENDING',
      createdAt: DateTime.now(),
    );
    return _box.put(record);
  }

  /// Marks an existing record as "TRIGGERED" and records the exact timestamp.
  ///
  /// Returns `true` if the record was found and updated, `false` if not found.
  bool markAsTriggered(int id) {
    final record = _box.get(id);
    if (record == null) return false;

    record.status = 'TRIGGERED';
    record.triggeredAt = DateTime.now();
    _box.put(record);
    return true;
  }

  /// Marks an existing record as "FAILED" (e.g. location key could not be resolved).
  ///
  /// Returns `true` if the record was found and updated, `false` if not found.
  bool markAsFailed(int id) {
    final record = _box.get(id);
    if (record == null) return false;

    record.status = 'FAILED';
    _box.put(record);
    return true;
  }

  /// Removes a specific record from the ObjectBox box.
  void deleteGeofence(int id) {
    _box.remove(id);
  }

  /// Removes all records from the ObjectBox box.
  void deleteAllGeofences() {
    _box.removeAll();
  }

  /// Removes old completed records (TRIGGERED or FAILED) to keep the DB clean.
  void purgeOldRecords({int hoursOld = 48}) {
    final cutoff = DateTime.now().subtract(Duration(hours: hoursOld));
    
    final query = _box.query(
      GeofenceRecord_.status.oneOf(['TRIGGERED', 'FAILED'])
      .and(GeofenceRecord_.createdAt.lessThan(cutoff.millisecondsSinceEpoch))
    ).build();

    final idsToRemove = query.findIds();
    if (idsToRemove.isNotEmpty) {
      _box.removeMany(idsToRemove);
      debugPrint('🗑️ [GeofenceRepository] Purged ${idsToRemove.length} old geofence records.');
    }
    
    query.close();
  }

  // ---------------------------------------------------------------------------
  // Read operations
  // ---------------------------------------------------------------------------

  /// Returns all records whose status is "PENDING".
  List<GeofenceRecord> getPendingGeofences() {
    return _box.query(GeofenceRecord_.status.equals('PENDING')).build().find();
  }

  /// Returns every [GeofenceRecord] in the database, in insertion order.
  ///
  /// Callers are responsible for sorting if a specific order is required.
  List<GeofenceRecord> getAllRecords() {
    return _box.getAll();
  }
}
