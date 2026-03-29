part of 'checklist_controller.dart';

/// CSV export actions for [ChecklistController].
extension ExportActions on ChecklistController {
  Future<void> exportCsv(BuildContext context) async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'ebird_checklist.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (outputFile == null) return;

    if (!outputFile.endsWith('.csv')) outputFile += '.csv';
    await CsvService.generateEbirdCsv(observations, outputFile);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('CSV exported to $outputFile')));
    }
  }
}
