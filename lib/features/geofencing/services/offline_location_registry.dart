import 'package:aitana/features/geofencing/models/location_definition.dart';

/// A dedicated registry for offline locations.
/// Extracted to maintain a clean architecture and prepare for future
/// dynamic expansions (e.g., adding locations dynamically via AI or ObjectBox).
class OfflineLocationRegistry {
  /// A local, offline map of known locations and their precise coordinates.
  /// Keys should be kept lowercase for easier matching.
  static final Map<String, LocationDefinition> locations = {
    'home': const LocationDefinition(
      lat: 31.726613,
      lng: -106.421693,
      targetSsids: ['IZZI-DDCA-5G', 'INFINITUME9DD', 'IZZI-DDCA'],
    ), // Home
    'walmart': const LocationDefinition(
      lat: 31.829360156802256,
      lng: -106.44666058048483,
    ), // Walmart off Dyer St
    'whataburger': const LocationDefinition(
      lat: 31.80805310345237,
      lng: -106.44444444294544,
    ), // Whataburger off Dyer St
    'hooters': const LocationDefinition(
      lat: 31.778754628144075,
      lng: -106.38485860797832,
    ), // Hooters off Sunmount Dr
    'work': const LocationDefinition(
      lat: 31.809109876174546,
      lng: -106.47005251213741,
      targetSsids: ['Thin_Client'],
    ), // Work
  };

  /// Attempts to find a matching location in the offline registry.
  /// Returns a [LocationDefinition], or null if the place is unknown.
  static LocationDefinition? resolveLocation(String placeName) {
    // Normalize the input: lowercase and trim whitespace
    final normalizedInput = placeName.toLowerCase().trim();

    // Simple exact match or partial match
    for (final key in locations.keys) {
      if (normalizedInput.contains(key)) {
        return locations[key];
      }
    }

    return null;
  }
}
