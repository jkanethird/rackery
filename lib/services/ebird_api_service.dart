import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'geo_region_service.dart';

class EbirdApiService {
  static const String _baseUrl = 'https://api.ebird.org/v2';
  static Map<String, String>? _speciesCodeToComNameCache;
  static final Map<String, Set<String>> _maskCache = {};

  /// Retrieves the stored eBird API Key
  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('ebird_api_key');
  }

  /// Sets the stored eBird API Key
  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ebird_api_key', key);
  }

  /// Ensures the taxonomy map is populated so we can map 'speciesCode' to 'comName'
  static Future<void> _ensureTaxonomy(String apiKey) async {
    if (_speciesCodeToComNameCache != null) return;

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/ref/taxonomy/ebird?fmt=json'),
        headers: {'X-eBirdApiToken': apiKey},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final List<dynamic> taxonomy = jsonDecode(response.body);
        _speciesCodeToComNameCache = {};
        for (final item in taxonomy) {
          final code = item['speciesCode'] as String?;
          final comName = item['comName'] as String?;
          if (code != null && comName != null) {
            _speciesCodeToComNameCache![code] = comName;
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch taxonomy: $e');
    }
  }

  /// Gets a Set of common names allowed for a given date and location.
  /// If the date is within the last 30 days, fetches recent observations (seasonal & geographic).
  /// If older, falls back to the regional checklist (geographic only).
  static Future<Set<String>?> getSpeciesMask(
      double lat, double lon, DateTime? date) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) return null;

    final now = DateTime.now();
    final isRecent = date == null || now.difference(date).inDays <= 30;

    final cacheKey = '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}_$isRecent';
    if (_maskCache.containsKey(cacheKey)) {
      return _maskCache[cacheKey];
    }

    Set<String>? mask;
    if (isRecent) {
      mask = await _getRecentSpecies(lat, lon, apiKey);
    } else {
      mask = await _getRegionalSpecies(lat, lon, apiKey);
    }

    if (mask != null) {
      _maskCache[cacheKey] = mask;
    }
    return mask;
  }

  static Future<Set<String>?> _getRecentSpecies(
      double lat, double lon, String apiKey) async {
    try {
      // Fetch recent observations within a 50km radius
      final response = await http.get(
        Uri.parse('$_baseUrl/data/obs/geo/recent?lat=$lat&lng=$lon&dist=50&back=30'),
        headers: {'X-eBirdApiToken': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> observations = jsonDecode(response.body);
        final Set<String> allowedSpecies = {};
        
        for (final obs in observations) {
          final comName = obs['comName'] as String?;
          if (comName != null) {
            allowedSpecies.add(comName);
          }
        }
        
        return allowedSpecies.isNotEmpty ? allowedSpecies : null;
      }
    } catch (e) {
      debugPrint('eBird API recent obs error: $e');
    }
    return null;
  }

  static Future<Set<String>?> _getRegionalSpecies(
      double lat, double lon, String apiKey) async {
    final regionCode = GeoRegionService.getEbirdRegionCode(lat, lon);
    if (regionCode == null) return null;

    await _ensureTaxonomy(apiKey);
    if (_speciesCodeToComNameCache == null) return null;

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/product/spplist/$regionCode'),
        headers: {'X-eBirdApiToken': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> speciesCodes = jsonDecode(response.body);
        final Set<String> allowedSpecies = {};
        
        for (final code in speciesCodes) {
          final comName = _speciesCodeToComNameCache![code.toString()];
          if (comName != null) {
            allowedSpecies.add(comName);
          }
        }
        
        return allowedSpecies.isNotEmpty ? allowedSpecies : null;
      }
    } catch (e) {
      debugPrint('eBird API regional spplist error: $e');
    }
    return null;
  }
}
