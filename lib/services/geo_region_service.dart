import 'dart:convert';
import 'package:http/http.dart' as http;

/// Converts GPS coordinates to a human-readable geographic region description
/// without requiring any internet connection or external API.
/// Uses bounding boxes for US states and broad world regions.
class GeoRegionService {
  static final Map<String, String> _locationCache = {};

  /// Asynchronously fetches municipality and state level detail using Nominatim.
  /// Falls back to the offline [describe] method if network is unavailable.
  static Future<String> getDetailedLocation(double lat, double lon) async {
    final cacheKey = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';
    if (_locationCache.containsKey(cacheKey)) {
      return _locationCache[cacheKey]!;
    }

    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=10',
      );
      final response = await http
          .get(url, headers: {'User-Agent': 'ebird_generator/1.0.0'})
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final state = address['state'] ?? address['region'] ?? '';
          final municipality =
              address['city'] ??
              address['town'] ??
              address['village'] ??
              address['municipality'] ??
              address['county'] ??
              '';

          String result = '';
          if (municipality.isNotEmpty) {
            result += municipality;
          }
          if (state.isNotEmpty) {
            if (result.isNotEmpty) result += ', ';
            result += state;
          }

          if (result.isNotEmpty) {
            _locationCache[cacheKey] = result;
            return result;
          }
        }
      }
    } catch (_) {
      // Ignore network errors and fall back to local description below
    }

    // Fallback to bounding box logic
    final fallback = describe(lat, lon);
    _locationCache[cacheKey] = fallback;
    return fallback;
  }

  /// Returns a natural language location string suitable for an ornithology prompt,
  /// e.g. "New Jersey, USA (northeastern United States)"
  static String describe(double lat, double lon) {
    // Try US states first (highest specificity)
    final state = _usState(lat, lon);
    if (state != null) return state;

    // Try Canadian provinces
    final province = _canadaProvince(lat, lon);
    if (province != null) return province;

    // Fall back to broad world regions
    return _worldRegion(lat, lon);
  }

  static String? _usState(double lat, double lon) {
    // Rough bounding boxes for US states (enough for species range narrowing)
    // Format: [minLat, maxLat, minLon, maxLon]
    final states = <String, List<double>>{
      'Maine': [43.1, 47.5, -71.1, -66.9],
      'New Hampshire': [42.7, 45.3, -72.6, -70.6],
      'Vermont': [42.7, 45.0, -73.4, -71.5],
      'Massachusetts': [41.2, 42.9, -73.5, -69.9],
      'Rhode Island': [41.1, 42.0, -71.9, -71.1],
      'Connecticut': [40.9, 42.0, -73.7, -71.8],
      'New York': [40.5, 45.0, -79.8, -71.8],
      'New Jersey': [38.9, 41.4, -75.6, -73.9],
      'Pennsylvania': [39.7, 42.3, -80.5, -74.7],
      'Delaware': [38.4, 39.8, -75.8, -75.0],
      'Maryland': [37.9, 39.7, -79.5, -75.0],
      'Virginia': [36.5, 39.5, -83.7, -75.2],
      'West Virginia': [37.2, 40.6, -82.6, -77.7],
      'North Carolina': [33.8, 36.6, -84.3, -75.5],
      'South Carolina': [32.0, 35.2, -83.4, -78.5],
      'Georgia': [30.4, 35.0, -85.6, -80.8],
      'Florida': [24.4, 31.0, -87.6, -80.0],
      'Alabama': [30.1, 35.0, -88.5, -84.9],
      'Mississippi': [30.1, 35.0, -91.7, -88.1],
      'Tennessee': [34.9, 36.7, -90.3, -81.6],
      'Kentucky': [36.5, 39.1, -89.6, -81.9],
      'Ohio': [38.4, 42.3, -84.8, -80.5],
      'Indiana': [37.8, 41.8, -88.1, -84.8],
      'Michigan': [41.7, 48.3, -90.4, -82.4],
      'Illinois': [36.9, 42.5, -91.5, -87.0],
      'Wisconsin': [42.5, 47.1, -92.9, -86.2],
      'Minnesota': [43.5, 49.4, -97.2, -89.5],
      'Iowa': [40.4, 43.5, -96.6, -90.1],
      'Missouri': [36.0, 40.6, -95.8, -89.1],
      'Arkansas': [33.0, 36.5, -94.6, -89.6],
      'Louisiana': [28.9, 33.0, -94.0, -88.8],
      'Texas': [25.8, 36.5, -106.6, -93.5],
      'Oklahoma': [33.6, 37.0, -103.0, -94.4],
      'Kansas': [37.0, 40.0, -102.1, -94.6],
      'Nebraska': [40.0, 43.0, -104.1, -95.3],
      'South Dakota': [42.5, 45.9, -104.1, -96.4],
      'North Dakota': [45.9, 49.0, -104.1, -96.6],
      'Montana': [44.4, 49.0, -116.0, -104.0],
      'Wyoming': [41.0, 45.0, -111.1, -104.1],
      'Colorado': [37.0, 41.0, -109.1, -102.0],
      'New Mexico': [31.3, 37.0, -109.0, -103.0],
      'Arizona': [31.3, 37.0, -114.8, -109.0],
      'Utah': [37.0, 42.0, -114.1, -109.0],
      'Nevada': [35.0, 42.0, -120.0, -114.0],
      'Idaho': [42.0, 49.0, -117.2, -111.0],
      'Oregon': [42.0, 46.3, -124.7, -116.5],
      'Washington': [45.5, 49.0, -124.8, -116.9],
      'California': [32.5, 42.0, -124.4, -114.1],
      'Alaska': [54.0, 71.5, -168.0, -130.0],
      'Hawaii': [18.9, 28.4, -178.4, -154.8],
    };

    for (final entry in states.entries) {
      final b = entry.value;
      if (lat >= b[0] && lat <= b[1] && lon >= b[2] && lon <= b[3]) {
        final subregion = _usSubregion(lat);
        return '${entry.key}, USA ($subregion)';
      }
    }
    return null;
  }

  /// Returns an eBird-compatible region code (e.g., "US-NY") based on bounding boxes.
  /// Falls back to country level, and returns null if out of bounds.
  static String? getEbirdRegionCode(double lat, double lon) {
    // US States
    final stateBoxes = <String, List<double>>{
      'US-ME': [43.1, 47.5, -71.1, -66.9],
      'US-NH': [42.7, 45.3, -72.6, -70.6],
      'US-VT': [42.7, 45.0, -73.4, -71.5],
      'US-MA': [41.2, 42.9, -73.5, -69.9],
      'US-RI': [41.1, 42.0, -71.9, -71.1],
      'US-CT': [40.9, 42.0, -73.7, -71.8],
      'US-NY': [40.5, 45.0, -79.8, -71.8],
      'US-NJ': [38.9, 41.4, -75.6, -73.9],
      'US-PA': [39.7, 42.3, -80.5, -74.7],
      'US-DE': [38.4, 39.8, -75.8, -75.0],
      'US-MD': [37.9, 39.7, -79.5, -75.0],
      'US-VA': [36.5, 39.5, -83.7, -75.2],
      'US-WV': [37.2, 40.6, -82.6, -77.7],
      'US-NC': [33.8, 36.6, -84.3, -75.5],
      'US-SC': [32.0, 35.2, -83.4, -78.5],
      'US-GA': [30.4, 35.0, -85.6, -80.8],
      'US-FL': [24.4, 31.0, -87.6, -80.0],
      'US-AL': [30.1, 35.0, -88.5, -84.9],
      'US-MS': [30.1, 35.0, -91.7, -88.1],
      'US-TN': [34.9, 36.7, -90.3, -81.6],
      'US-KY': [36.5, 39.1, -89.6, -81.9],
      'US-OH': [38.4, 42.3, -84.8, -80.5],
      'US-IN': [37.8, 41.8, -88.1, -84.8],
      'US-MI': [41.7, 48.3, -90.4, -82.4],
      'US-IL': [36.9, 42.5, -91.5, -87.0],
      'US-WI': [42.5, 47.1, -92.9, -86.2],
      'US-MN': [43.5, 49.4, -97.2, -89.5],
      'US-IA': [40.4, 43.5, -96.6, -90.1],
      'US-MO': [36.0, 40.6, -95.8, -89.1],
      'US-AR': [33.0, 36.5, -94.6, -89.6],
      'US-LA': [28.9, 33.0, -94.0, -88.8],
      'US-TX': [25.8, 36.5, -106.6, -93.5],
      'US-OK': [33.6, 37.0, -103.0, -94.4],
      'US-KS': [37.0, 40.0, -102.1, -94.6],
      'US-NE': [40.0, 43.0, -104.1, -95.3],
      'US-SD': [42.5, 45.9, -104.1, -96.4],
      'US-ND': [45.9, 49.0, -104.1, -96.6],
      'US-MT': [44.4, 49.0, -116.0, -104.0],
      'US-WY': [41.0, 45.0, -111.1, -104.1],
      'US-CO': [37.0, 41.0, -109.1, -102.0],
      'US-NM': [31.3, 37.0, -109.0, -103.0],
      'US-AZ': [31.3, 37.0, -114.8, -109.0],
      'US-UT': [37.0, 42.0, -114.1, -109.0],
      'US-NV': [35.0, 42.0, -120.0, -114.0],
      'US-ID': [42.0, 49.0, -117.2, -111.0],
      'US-OR': [42.0, 46.3, -124.7, -116.5],
      'US-WA': [45.5, 49.0, -124.8, -116.9],
      'US-CA': [32.5, 42.0, -124.4, -114.1],
      'US-AK': [54.0, 71.5, -168.0, -130.0],
      'US-HI': [18.9, 28.4, -178.4, -154.8],
    };

    for (final entry in stateBoxes.entries) {
      final b = entry.value;
      if (lat >= b[0] && lat <= b[1] && lon >= b[2] && lon <= b[3]) {
        return entry.key;
      }
    }
    
    // Canada check
    if (lat >= 42 && lat <= 83 && lon >= -141 && lon <= -52) {
      return 'CA';
    }

    // Rough world regions (fallback to country)
    if (lat > 14 && lat < 32 && lon > -118 && lon < -86) return 'MX'; // Mexico

    // If completely unknown, just return null so we use standard classifier without masking
    return null;
  }

  static String _usSubregion(double lat) {
    if (lat > 45) return 'northern United States';
    if (lat > 37) return 'northeastern/midwestern United States';
    if (lat > 30) return 'southeastern United States';
    return 'southern United States';
  }

  static String? _canadaProvince(double lat, double lon) {
    if (lat < 42 || lat > 83 || lon < -141 || lon > -52) return null;
    if (lon > -63) return 'Nova Scotia or Prince Edward Island, Canada';
    if (lon > -66.5) return 'New Brunswick, Canada';
    if (lon > -74 && lat < 53) return 'Quebec, Canada';
    if (lon > -88 && lat < 47) return 'Ontario, Canada';
    if (lon > -96) return 'Manitoba, Canada';
    if (lon > -110) return 'Saskatchewan, Canada';
    if (lon > -120) return 'Alberta, Canada';
    return 'British Columbia, Canada';
  }

  static String _worldRegion(double lat, double lon) {
    if (lat > 60) return 'Arctic/Subarctic region';
    if (lat < -60) return 'Antarctic region';

    // Europe
    if (lat > 35 && lat < 72 && lon > -12 && lon < 42) {
      if (lat > 55) return 'northern Europe (Scandinavia/UK)';
      if (lon < 5) return 'western Europe (France/Spain/Portugal)';
      if (lon < 20) return 'central Europe (Germany/Poland/Austria)';
      return 'eastern Europe or western Russia';
    }

    // Asia
    if (lat > 0 && lat < 75 && lon > 42 && lon < 180) {
      if (lon < 60) return 'Middle East or Central Asia';
      if (lon < 100) return 'South Asia or Southeast Asia';
      if (lat > 35) return 'eastern Asia (China/Japan/Korea)';
      return 'Southeast Asia';
    }

    // Africa
    if (lat > -35 && lat < 35 && lon > -20 && lon < 55) {
      if (lat > 20) return 'North Africa or Saharan region';
      if (lat > 0) return 'Sub-Saharan Africa (central/west)';
      return 'southern Africa';
    }

    // South America
    if (lat < 15 && lat > -60 && lon > -85 && lon < -35) {
      if (lat > 0) return 'northern South America (Venezuela/Colombia)';
      if (lat > -20) return 'central South America (Brazil/Peru)';
      return 'southern South America (Argentina/Chile)';
    }

    // Central America / Caribbean
    if (lat > 7 && lat < 25 && lon > -92 && lon < -60) {
      return 'Central America or Caribbean';
    }

    // Mexico
    if (lat > 14 && lat < 32 && lon > -118 && lon < -86) {
      return 'Mexico';
    }

    // Australia / Oceania
    if (lat < 0 && lon > 110 && lon < 180) {
      if (lat > -25) return 'northern Australia or Papua New Guinea';
      return 'southern Australia or New Zealand';
    }

    return 'coordinates (${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)})';
  }
}
