import 'package:flutter/material.dart';

import 'firefly_theme.dart';

/// The 800x800 stadium backdrop from the design: concentric stands, the
/// field with STAGE / PIT / FLOOR, section numbers and gate chips. Pure
/// decoration — an honest offline stand-in for a tile map, matching the
/// design's fictional venue.
class VenueMapBackdrop extends StatelessWidget {
  const VenueMapBackdrop({super.key});

  static const sections = [
    ('101', Offset(400, 74)), ('104', Offset(636, 148)),
    ('107', Offset(726, 400)), ('110', Offset(636, 652)),
    ('113', Offset(400, 726)), ('116', Offset(164, 652)),
    ('119', Offset(74, 400)), ('122', Offset(164, 148)),
  ];
  static const gates = [
    ('GATE N', Offset(400, 22)), ('GATE E', Offset(778, 400)),
    ('GATE S', Offset(400, 778)), ('GATE W', Offset(22, 400)),
  ];

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return SizedBox(
      width: 800,
      height: 800,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CustomPaint(size: const Size(800, 800), painter: _BowlPainter(c)),
          // STAGE plate
          Positioned(
            left: 300,
            top: 236,
            child: Container(
              width: 200,
              height: 56,
              decoration: BoxDecoration(
                gradient: c.glass(strong: true),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.stroke2),
                boxShadow: [c.shadow],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_note_rounded, size: 17, color: c.dim),
                  const SizedBox(width: 8),
                  Text('STAGE',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 4,
                          color: c.dim)),
                ],
              ),
            ),
          ),
          _label('PIT', const Offset(400, 330), c.faint, 11, 3),
          _label('FLOOR', const Offset(400, 437), c.faint, 11, 4),
          for (final (text, at) in sections)
            _label(text, at, c.faint, 11, 1.5, weight: FontWeight.w600),
          for (final (text, at) in gates)
            Positioned(
              left: at.dx - 40,
              top: at.dy - 11,
              child: Container(
                width: 80,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: c.glass(),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: c.stroke),
                ),
                child: Text(text,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                        color: c.faint)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(String text, Offset at, Color color, double size,
      double spacing, {FontWeight weight = FontWeight.w400}) {
    return Positioned(
      left: at.dx - 60,
      top: at.dy - size,
      child: SizedBox(
        width: 120,
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: size,
                letterSpacing: spacing,
                fontWeight: weight,
                color: color)),
      ),
    );
  }
}

class _BowlPainter extends CustomPainter {
  _BowlPainter(this.c);
  final FfColors c;

  @override
  void paint(Canvas canvas, Size size) {
    const center = Offset(400, 400);

    // outer bowl: inset 22, 1.5px stroke2 border, bowl fill
    canvas.drawCircle(center, 378, Paint()..color = c.bowl);
    canvas.drawCircle(
        center,
        378,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = c.stroke2);

    // stands: two thick annuli (inset 50 border 46; inset 140 border 52)
    canvas.drawCircle(
        center,
        350 - 23,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 46
          ..color = c.tier1);
    canvas.drawCircle(
        center,
        260 - 26,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 52
          ..color = c.tier2);

    // field: inset 216, radius 150
    final field = RRect.fromRectAndRadius(
        const Rect.fromLTWH(216, 216, 368, 368), const Radius.circular(150));
    canvas.drawRRect(field, Paint()..color = c.field);
    canvas.drawRRect(
        field,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = c.stroke);
  }

  @override
  bool shouldRepaint(_BowlPainter old) => old.c != c;
}

/// Dashed accent "find" line from you to the target, with a ring around the
/// target — the design's animated SVG overlay.
class FindLinePainter extends CustomPainter {
  FindLinePainter({
    required this.from,
    required this.to,
    required this.accent,
    required this.accentLine,
    required this.phase,
  });

  final Offset from;
  final Offset to;
  final Color accent;
  final Color accentLine;

  /// 0–1 animation phase driving the marching dashes.
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = accent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const dash = 6.0, gap = 8.0;
    final v = to - from;
    final len = v.distance;
    if (len > 1) {
      final dir = v / len;
      var t = -(dash + gap) + phase * (dash + gap);
      while (t < len) {
        final a = t.clamp(0, len).toDouble();
        final b = (t + dash).clamp(0, len).toDouble();
        if (b > a) {
          canvas.drawLine(from + dir * a, from + dir * b, paint);
        }
        t += dash + gap;
      }
    }
    canvas.drawCircle(
        to,
        30,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = accentLine);
  }

  @override
  bool shouldRepaint(FindLinePainter old) =>
      old.from != from || old.to != to || old.phase != phase;
}
