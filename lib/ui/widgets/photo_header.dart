// Rackery - Automatic bird identification and eBird checklist generation.
// Copyright (C) 2026 Joseph J. Kane III
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'package:flutter/material.dart';
import 'package:rackery/services/geo_region_service.dart';

class PhotoHeader extends StatelessWidget {
  final double? latitude;
  final double? longitude;
  final String filename;

  const PhotoHeader({
    super.key,
    this.latitude,
    this.longitude,
    required this.filename,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        if (latitude != null && longitude != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 12, color: Colors.blueGrey),
              const SizedBox(width: 3),
              Flexible(
                child: FutureBuilder<String>(
                  future: GeoRegionService.getDetailedLocation(
                    latitude!,
                    longitude!,
                  ),
                  builder: (context, snapshot) {
                    return SelectableText(
                      snapshot.data ??
                          GeoRegionService.describe(latitude!, longitude!),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.blueGrey,
                      ),
                      textAlign: TextAlign.center,
                    );
                  },
                ),
              ),
            ],
          ),
        const SizedBox(height: 2),
        SelectableText(
          filename,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
