import 'package:flutter/material.dart';

import 'firefly_theme.dart';

/// The firefly mark from the design — two wings, head, thorax, glowing tail
/// — drawn on the design's 32x32 viewBox and scaled to [size].
class FireflyLogo extends StatelessWidget {
  const FireflyLogo({super.key, this.size = 38, this.tailColor, this.glow = 0});

  final double size;

  /// Tail (abdomen) color; defaults to the accent. The map "you" marker
  /// dims it to faint when offline.
  final Color? tailColor;

  /// 0–1 strength of the drop-shadow glow around the tail.
  final double glow;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return CustomPaint(
      size: Size.square(size),
      painter: _FireflyPainter(
        wing: c.wing,
        body: c.bodyFill,
        tail: tailColor ?? c.accent,
        glowColor: c.accentGlow,
        glow: glow,
      ),
    );
  }
}

class _FireflyPainter extends CustomPainter {
  _FireflyPainter({
    required this.wing,
    required this.body,
    required this.tail,
    required this.glowColor,
    required this.glow,
  });

  final Color wing;
  final Color body;
  final Color tail;
  final Color glowColor;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 32;
    canvas.scale(s);

    void ellipse(double cx, double cy, double rx, double ry, double rotDeg,
        Paint paint) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rotDeg * 3.14159265 / 180);
      canvas.drawOval(
          Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
          paint);
      canvas.restore();
    }

    final wingPaint = Paint()..color = wing;
    ellipse(10.5, 11, 3.4, 7, -34, wingPaint);
    ellipse(21.5, 11, 3.4, 7, 34, wingPaint);

    final bodyPaint = Paint()..color = body;
    canvas.drawCircle(const Offset(16, 7.5), 2.6, bodyPaint);
    ellipse(16, 14, 3.6, 5, 0, bodyPaint);

    if (glow > 0) {
      final glowPaint = Paint()
        ..color = glowColor.withValues(alpha: glowColor.a * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
      canvas.drawCircle(const Offset(16, 22.5), 7.5, glowPaint);
    }
    canvas.drawCircle(const Offset(16, 22.5), 5, Paint()..color = tail);
  }

  @override
  bool shouldRepaint(_FireflyPainter old) =>
      wing != old.wing || body != old.body || tail != old.tail ||
      glow != old.glow;
}

/// The centered glassy FIREFLY wordmark with the mesh status line under it.
class FireflyWordmark extends StatelessWidget {
  const FireflyWordmark({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FireflyLogo(size: 18),
            const SizedBox(width: 9),
            ShaderMask(
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [c.logoHi, c.logoLo],
              ).createShader(bounds),
              child: const Text(
                'FIREFLY',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(status, style: TextStyle(fontSize: 11, color: c.dim)),
      ],
    );
  }
}
