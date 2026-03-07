import 'dart:math';
import 'package:flutter/material.dart';

class SineWaveProgressIndicator extends StatefulWidget {
  final double value; // 0.0 to 1.0
  final Color? color;
  final Color? backgroundColor;

  const SineWaveProgressIndicator({
    super.key,
    required this.value,
    this.color,
    this.backgroundColor,
  });

  @override
  State<SineWaveProgressIndicator> createState() =>
      _SineWaveProgressIndicatorState();
}

class _SineWaveProgressIndicatorState extends State<SineWaveProgressIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: widget.value),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, child) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return SizedBox(
              height: 12,
              width: double.infinity,
              child: CustomPaint(
                painter: SineWavePainter(
                  progress: animatedValue,
                  phase: _controller.value * 2 * pi,
                  color: widget.color ?? Theme.of(context).colorScheme.primary,
                  backgroundColor: widget.backgroundColor ??
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class SineWavePainter extends CustomPainter {
  final double progress;
  final double phase;
  final Color color;
  final Color backgroundColor;

  SineWavePainter({
    required this.progress,
    required this.phase,
    required this.color,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = 4.0;
    
    // Paint for the unfilled (straight line) part
    final bgPaint = Paint()
      ..color = backgroundColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Paint for the filled (squiggly) part
    final fgPaint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final double filledWidth = size.width * progress;
    final double centerY = size.height / 2;
    
    final double amplitude = 3.5;
    final double wavelength = 40.0;
    
    // Draw background squiggly line from filledWidth to size.width
    if (progress < 1.0) {
      final bgPath = Path();
      
      // Calculate first point of background wave
      double bgStartY = centerY + sin((filledWidth / wavelength) * 2 * pi - phase * 2) * amplitude;
      bgPath.moveTo(filledWidth, bgStartY);
      
      for (double x = filledWidth + 1.0; x <= size.width; x += 1.0) {
        double y = centerY + sin((x / wavelength) * 2 * pi - phase * 2) * amplitude;
        bgPath.lineTo(x, y);
      }
      
      canvas.drawPath(bgPath, bgPaint);
    }

    if (progress > 0.0) {
      // Draw squiggly line from 0 to filledWidth
      final fgPath = Path();
      
      // Calculate first point
      double fgStartY = centerY + sin(-phase * 2) * amplitude;
      fgPath.moveTo(0, fgStartY);
      
      for (double x = 1; x <= filledWidth; x += 1.0) {
        double y = centerY + sin((x / wavelength) * 2 * pi - phase * 2) * amplitude;
        fgPath.lineTo(x, y);
      }
      
      canvas.drawPath(fgPath, fgPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SineWavePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.phase != phase;
  }
}
