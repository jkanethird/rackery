import 'dart:math';
import 'package:flutter/material.dart';

/// A squircle-like [OutlinedBorder] based on the superellipse equation
/// |x/a|^m + |y/b|^n = 1.
///
/// Use [m] and [n] to control the exponents (higher → more rectangular).
class SuperellipseBorder extends OutlinedBorder {
  final double m;
  final double n;

  const SuperellipseBorder({
    required this.m,
    required this.n,
    super.side,
  });

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _getPath(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _getPath(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side != BorderSide.none) {
      canvas.drawPath(_getPath(rect), side.toPaint());
    }
  }

  Path _getPath(Rect rect) {
    final path = Path();
    final a = rect.width / 2;
    final b = rect.height / 2;
    final cx = rect.center.dx;
    final cy = rect.center.dy;

    const segments = 100;
    for (int i = 0; i <= segments; i++) {
      final t = i * 2 * pi / segments;
      final cosT = cos(t);
      final sinT = sin(t);
      final x = cx + a * (cosT.sign * pow(cosT.abs(), 2 / m));
      final y = cy + b * (sinT.sign * pow(sinT.abs(), 2 / n));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) =>
      SuperellipseBorder(m: m, n: n, side: side.scale(t));

  @override
  OutlinedBorder copyWith({BorderSide? side, double? m, double? n}) {
    return SuperellipseBorder(
      m: m ?? this.m,
      n: n ?? this.n,
      side: side ?? this.side,
    );
  }
}
