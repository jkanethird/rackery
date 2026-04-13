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

part of 'checklist_controller.dart';

/// CSV export actions for [ChecklistController].
extension ExportActions on ChecklistController {
  Future<void> exportCsv(BuildContext context) async {
    final saveLocation = await getSaveLocation(
      suggestedName: 'ebird_checklist.csv',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (saveLocation == null) return;
    String outputFile = saveLocation.path;

    if (!outputFile.endsWith('.csv')) outputFile += '.csv';
    await CsvService.generateEbirdCsv(observations, outputFile);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV exported to $outputFile')));
    }
  }
}
