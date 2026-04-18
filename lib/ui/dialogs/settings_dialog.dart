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
import 'package:rackery/services/ebird_api_service.dart';

/// Shows the eBird API key settings dialog and resolves when dismissed.
Future<void> showSettingsDialog(BuildContext context, String executionProvider) async {
  final currentKey = await EbirdApiService.getApiKey() ?? '';
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => _SettingsDialog(initialKey: currentKey, executionProvider: executionProvider),
  );
}

class _SettingsDialog extends StatefulWidget {
  final String initialKey;
  final String executionProvider;
  const _SettingsDialog({required this.initialKey, required this.executionProvider});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _keyController;
  bool _isTesting = false;
  bool _isObscured = true;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: widget.initialKey);
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _testKey() async {
    setState(() => _isTesting = true);
    final isValid = await EbirdApiService.verifyApiKey(_keyController.text);
    if (!mounted) return;
    setState(() => _isTesting = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isValid ? '✅ API Key is valid' : '❌ Invalid API Key or network error',
        ),
        backgroundColor: isValid ? Colors.green.shade800 : Colors.red.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _keyController,
            obscureText: _isObscured,
            decoration: InputDecoration(
              labelText: 'eBird API Key',
              hintText: 'Paste your eBird API Token here',
              helperText: 'Required for geographic & seasonal filtering.',
              suffixIcon: IconButton(
                icon: Icon(_isObscured ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _isObscured = !_isObscured),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isTesting ? null : _testKey,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(_isTesting ? 'Testing...' : 'Test API Key'),
            ),
          ),
          const SizedBox(height: 24),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'System Information',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'ONNX Execution Provider: ${widget.executionProvider}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            EbirdApiService.setApiKey(_keyController.text.trim());
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
