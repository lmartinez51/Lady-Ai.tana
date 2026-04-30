class LocationDefinition {
  final double lat;
  final double lng;
  final double radius;
  final List<String> targetSsids;

  const LocationDefinition({
    required this.lat,
    required this.lng,
    this.radius = 200.0,
    this.targetSsids = const [],
  });
}
