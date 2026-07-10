import 'dart:ui';

import 'package:flutter/material.dart';

import 'firefly_theme.dart';

/// Frosted glass panel — the design's recurring
/// `background:linear-gradient(135deg,hi,lo); border:1px solid stroke;
/// box-shadow:inset 0 1px 0 edge, shadow; backdrop-filter:blur(N)` stack.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 28,
    this.strong = false,
    this.blur = 20,
    this.drop = true,
    this.borderColor,
    this.padding,
    this.glow = false,
  });

  final Widget child;
  final double radius;

  /// Uses the brighter glass2 gradient (cards, dock) vs the softer chips.
  final bool strong;
  final double blur;
  final bool drop;
  final Color? borderColor;
  final EdgeInsetsGeometry? padding;

  /// Adds the accent halo used by the "finding" chip.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final border = borderColor ?? (strong ? c.stroke2 : c.stroke);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          if (glow) BoxShadow(color: c.accentGlow, blurRadius: 20),
          ...c.glassShadows(drop: drop),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              gradient: c.glass(strong: strong),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: border),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              // inset 0 1px 0 edge: hairline highlight along the top rim.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [c.edge.withValues(alpha: c.edge.a * .6),
                    Colors.transparent],
                stops: const [0, .06],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Round frosted icon button (map controls, close buttons, chat send).
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.iconSize = 20,
    this.color,
    this.filled = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final Color? color;

  /// Accent-filled (primary action) instead of glass.
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    Widget button = GestureDetector(
      onTap: onTap,
      child: filled
          ? Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent,
                boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 16)],
              ),
              child: Icon(icon, size: iconSize, color: c.accentInk),
            )
          : GlassPanel(
              radius: size / 2,
              strong: true,
              blur: 18,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, size: iconSize, color: color ?? c.dim),
              ),
            ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return button;
  }
}

/// Design toggle: 44x26 pill with a sliding white knob.
class GlassSwitch extends StatelessWidget {
  const GlassSwitch({super.key, required this.value, required this.onChanged,
      this.width = 44});

  final bool value;
  final ValueChanged<bool> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final knob = width == 44 ? 20.0 : 18.0;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: width,
        height: knob + 6,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: value ? c.accent : c.glassLo,
          border: Border.all(color: c.stroke),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: knob,
            height: knob,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(color: Color(0x4D000000), blurRadius: 4,
                    offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular initial avatar with the design's per-friend background colors.
class InitialAvatar extends StatelessWidget {
  const InitialAvatar({super.key, required this.name, this.size = 40,
      this.ringColor, this.background});

  final String name;
  final double size;
  final Color? ringColor;
  final Color? background;

  /// Stable, design-palette-adjacent color from the username.
  static Color colorFor(String name) {
    const palette = [
      Color(0xFFA06A9E), Color(0xFF4F8F7A), Color(0xFFB3764A),
      Color(0xFF5A7AB0), Color(0xFF4E9B96), Color(0xFF8A6FB8),
      Color(0xFFB05A6E), Color(0xFF5C6478),
    ];
    var h = 0;
    for (final u in name.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: background ?? colorFor(name),
        border: ringColor == null
            ? null
            : Border.all(color: ringColor!, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * .38,
        ),
      ),
    );
  }
}
