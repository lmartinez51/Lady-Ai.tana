import 'package:objectbox/objectbox.dart';

/// Represents a historical log entry for a geofence action scheduled by the LLM.
///
/// A record starts with status [GeofenceStatus.pending] and transitions to
/// [GeofenceStatus.triggered] when the OS fires the location notification,
/// or [GeofenceStatus.cancelled] if the user or the system aborts it.
@Entity()
class GeofenceRecord {
  /// ObjectBox primary key. 0 means "new" — the store assigns the real ID on insert.
  @Id()
  int id = 0;

  /// The human-readable action title given by the LLM (e.g. "Go to HR").
  String title;

  /// The location key that triggers this geofence (e.g. "work", "home").
  String locationKey;

  /// Current lifecycle status of the geofence.
  /// One of: "PENDING", "TRIGGERED", or "CANCELLED".
  String status;

  /// Timestamp of when the LLM scheduled this geofence.
  @Property(type: PropertyType.date)
  DateTime createdAt;

  /// Timestamp of when the OS actually fired the location notification.
  /// Null until the geofence transitions to "TRIGGERED".
  @Property(type: PropertyType.date)
  DateTime? triggeredAt;

  GeofenceRecord({
    this.id = 0,
    required this.title,
    required this.locationKey,
    this.status = 'PENDING',
    DateTime? createdAt,
    this.triggeredAt,
  }) : createdAt = createdAt ?? DateTime.now();
}
