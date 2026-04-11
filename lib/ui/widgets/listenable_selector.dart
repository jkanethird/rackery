import 'package:flutter/material.dart';

/// A widget that listens to a [Listenable] (like a ChangeNotifier) and rebuilds
/// only when the value returned by the [selector] function changes.
///
/// This avoids rebuilding the entire widget tree when only a subset of state updates.
class ListenableSelector<T extends Listenable, R> extends StatefulWidget {
  final T listenable;
  final R Function(T) selector;
  final Widget Function(BuildContext context, R value, Widget? child) builder;
  final Widget? child;

  const ListenableSelector({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
    this.child,
  });

  @override
  State<ListenableSelector<T, R>> createState() => _ListenableSelectorState<T, R>();
}

class _ListenableSelectorState<T extends Listenable, R> extends State<ListenableSelector<T, R>> {
  late R _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector(widget.listenable);
    widget.listenable.addListener(_listener);
  }

  @override
  void didUpdateWidget(covariant ListenableSelector<T, R> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_listener);
      _value = widget.selector(widget.listenable);
      widget.listenable.addListener(_listener);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_listener);
    super.dispose();
  }

  void _listener() {
    final newValue = widget.selector(widget.listenable);
    if (_value != newValue) {
      setState(() {
        _value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _value, widget.child);
  }
}
