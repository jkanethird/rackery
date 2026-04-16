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
import '../../services/bird_names.dart';
import 'superellipse_border.dart';

/// A species search field with a floating overlay autocomplete dropdown.
///
/// Shows model-suggested species first, then falls back to a taxonomy-wide
/// fuzzy search across [scientificToCommon] when a query is typed.
class SpeciesFuzzyField extends StatefulWidget {
  final String speciesName;
  final List<String> possibleSpecies;
  final bool isSelected;
  final void Function(String) onSpeciesChanged;
  final void Function() onTapField;
  final void Function(bool isOpen)? onDropdownToggled;

  const SpeciesFuzzyField({
    super.key,
    required this.speciesName,
    required this.possibleSpecies,
    required this.isSelected,
    required this.onSpeciesChanged,
    required this.onTapField,
    this.onDropdownToggled,
  });

  @override
  State<SpeciesFuzzyField> createState() => _SpeciesFuzzyFieldState();
}

class _SpeciesFuzzyFieldState extends State<SpeciesFuzzyField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.speciesName == 'Unknown Bird' ? '' : widget.speciesName,
    );
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(SpeciesFuzzyField oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Deselecting the card: collapse overlay and blur focus
    if (!widget.isSelected && oldWidget.isSelected) {
      if (_focusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _focusNode.hasFocus) _focusNode.unfocus();
        });
      }
    }

    // External species name change (e.g. merged observation)
    if (widget.speciesName != oldWidget.speciesName &&
        _controller.text != widget.speciesName) {
      _controller.text =
          widget.speciesName == 'Unknown Bird' ? '' : widget.speciesName;
    }
  }

  @override
  void dispose() {
    _hideOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus && mounted) {
      _showOverlay();
    } else if (!_focusNode.hasFocus && mounted) {
      _hideOverlay();
      widget.onSpeciesChanged(_controller.text);
    }
  }

  void _hideOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
      widget.onDropdownToggled?.call(false);
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;
    widget.onDropdownToggled?.call(true);

    bool flipUp = false;
    try {
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final pos = box.localToGlobal(Offset.zero);
        final screenH = MediaQuery.of(context).size.height;
        final spaceBelow = screenH - pos.dy - box.size.height;
        if (spaceBelow < 250 && pos.dy > spaceBelow) flipUp = true;
      }
    } catch (_) {}

    _overlayEntry = OverlayEntry(
      builder: (ctx) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (ctx, value, _) {
          final query = value.text.toLowerCase();
          final modelCommons = widget.possibleSpecies
              .where((s) => s.toLowerCase().contains(query) && s != 'Unknown Bird')
              .toList();
          final taxonomyCommons = query.isNotEmpty
              ? scientificToCommon.values
                  .where((s) =>
                      s.toLowerCase().contains(query) && !modelCommons.contains(s))
                  .take(15)
              : <String>[];
          final options = [...modelCommons, ...taxonomyCommons];
          if (options.isEmpty) return const SizedBox.shrink();

          final list = TextFieldTapRegion(
            child: Material(
              elevation: 4.0,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 250),
                width: 300,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (ctx, idx) {
                    final option = options[idx];
                    return InkWell(
                      onTap: () {
                        widget.onSpeciesChanged(option);
                        _controller.text = option;
                        _hideOverlay();
                        _focusNode.unfocus();
                        if (mounted) setState(() {});
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(option),
                      ),
                    );
                  },
                ),
              ),
            ),
          );

          return Stack(
            children: [
              CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                targetAnchor: flipUp ? Alignment.topLeft : Alignment.bottomLeft,
                followerAnchor: flipUp ? Alignment.bottomLeft : Alignment.topLeft,
                offset: flipUp ? const Offset(0, -4) : const Offset(0, 4),
                child: list,
              ),
            ],
          );
        },
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasSelection =
        widget.speciesName.isNotEmpty && widget.speciesName != 'Unknown Bird';

    if (hasSelection) {
      final button = OutlinedButton.icon(
        onPressed: () {
          widget.onSpeciesChanged('Unknown Bird');
          if (mounted) {
            setState(() => _controller.text = '');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _focusNode.requestFocus();
            });
          }
        },
        icon: const Icon(Icons.clear, size: 16),
        label: Text(
          widget.speciesName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: const SuperellipseBorder(m: 200.0, n: 20.0),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );

      return Padding(
        padding: const EdgeInsets.only(bottom: 4.0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: !widget.isSelected
              ? GestureDetector(
                  onTap: widget.onTapField,
                  child: AbsorbPointer(child: button),
                )
              : button,
        ),
      );
    }

    // --- Autocomplete text field ---
    Widget field;
    if (!widget.isSelected) {
      field = GestureDetector(
        onTap: widget.onTapField,
        child: AbsorbPointer(
          child: TextFormField(
            controller: _controller,
            focusNode: _focusNode,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8.0),
            ),
            style: const TextStyle(fontSize: 16),
            readOnly: true,
          ),
        ),
      );
    } else {
      field = TextFormField(
        controller: _controller,
        focusNode: _focusNode,
        decoration: const InputDecoration(labelText: 'Species'),
        onFieldSubmitted: (value) {
          widget.onSpeciesChanged(value);
          _hideOverlay();
          Future.microtask(() {
            if (mounted) setState(() {});
          });
        },
        onChanged: (value) {
          // Optimistic local update so the overlay filters immediately
        },
      );
    }

    return CompositedTransformTarget(link: _layerLink, child: field);
  }
}
