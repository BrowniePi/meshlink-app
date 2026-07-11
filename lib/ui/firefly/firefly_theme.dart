import 'package:flutter/material.dart';

/// Firefly design tokens — Dart mirror of the `[data-ff-theme]` CSS variable
/// blocks in the Firefly v5 design (Claude Design project). One [FfColors]
/// per theme; widgets read them via [FireflyTheme.of].
class FfColors {
  const FfColors({
    required this.bg,
    required this.text,
    required this.dim,
    required this.faint,
    required this.glassHi,
    required this.glassLo,
    required this.glass2Hi,
    required this.glass2Lo,
    required this.stroke,
    required this.stroke2,
    required this.edge,
    required this.shadow,
    required this.scrim,
    required this.accent,
    required this.accentSoft,
    required this.accentLine,
    required this.accentGlow,
    required this.accentInk,
    required this.bubbleInHi,
    required this.bubbleInLo,
    required this.bowl,
    required this.tier1,
    required this.tier2,
    required this.field,
    required this.bodyFill,
    required this.wing,
    required this.logoHi,
    required this.logoLo,
    required this.brightness,
  });

  final Gradient bg;
  final Color text;
  final Color dim;
  final Color faint;
  final Color glassHi;
  final Color glassLo;
  final Color glass2Hi;
  final Color glass2Lo;
  final Color stroke;
  final Color stroke2;
  final Color edge;
  final BoxShadow shadow;
  final Color scrim;
  final Color accent;
  final Color accentSoft;
  final Color accentLine;
  final Color accentGlow;
  final Color accentInk;
  final Color bubbleInHi;
  final Color bubbleInLo;
  final Color bowl;
  final Color tier1;
  final Color tier2;
  final Color field;
  final Color bodyFill;
  final Color wing;
  final Color logoHi;
  final Color logoLo;
  final Brightness brightness;

  static const FfColors dark = FfColors(
    bg: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF0B0D13), Color(0xFF10131C), Color(0xFF141826)],
      stops: [0, .55, 1],
    ),
    text: Color(0xFFEEF0F5),
    dim: Color(0x8FEEF0F5),
    faint: Color(0x4DEEF0F5),
    glassHi: Color(0x17FFFFFF),
    glassLo: Color(0x08FFFFFF),
    glass2Hi: Color(0x24FFFFFF),
    glass2Lo: Color(0x0FFFFFFF),
    stroke: Color(0x1CFFFFFF),
    stroke2: Color(0x33FFFFFF),
    edge: Color(0x38FFFFFF),
    shadow: BoxShadow(
        color: Color(0x73020308), blurRadius: 30, offset: Offset(0, 12)),
    scrim: Color(0x8005060A),
    accent: Color(0xFFE6B34D),
    accentSoft: Color(0x21E6B34D),
    accentLine: Color(0x66E6B34D),
    accentGlow: Color(0x66E6B34D),
    accentInk: Color(0xFF181104),
    bubbleInHi: Color(0x1AFFFFFF),
    bubbleInLo: Color(0x0AFFFFFF),
    bowl: Color(0x04FFFFFF),
    tier1: Color(0x09FFFFFF),
    tier2: Color(0x0EFFFFFF),
    field: Color(0x0F6E9682),
    bodyFill: Color(0xFF3D4358),
    wing: Color(0x59FFFFFF),
    logoHi: Color(0xF5FFFFFF),
    logoLo: Color(0x6BFFFFFF),
    brightness: Brightness.dark,
  );

  static const FfColors light = FfColors(
    bg: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFEFF0F3), Color(0xFFE9EBEF), Color(0xFFE3E7EE)],
      stops: [0, .55, 1],
    ),
    text: Color(0xFF1D2130),
    dim: Color(0x941D2130),
    faint: Color(0x521D2130),
    glassHi: Color(0xBFFFFFFF),
    glassLo: Color(0x66FFFFFF),
    glass2Hi: Color(0xF0FFFFFF),
    glass2Lo: Color(0x9EFFFFFF),
    stroke: Color(0x1A1D2130),
    stroke2: Color(0x2E1D2130),
    edge: Color(0xF2FFFFFF),
    shadow: BoxShadow(
        color: Color(0x21323750), blurRadius: 30, offset: Offset(0, 12)),
    scrim: Color(0x80E4E6EE),
    accent: Color(0xFFA97B1E),
    accentSoft: Color(0x1CA97B1E),
    accentLine: Color(0x61A97B1E),
    accentGlow: Color(0x66DCA028),
    accentInk: Color(0xFFFFFFFF),
    bubbleInHi: Color(0xD9FFFFFF),
    bubbleInLo: Color(0x8CFFFFFF),
    bowl: Color(0x051D2130),
    tier1: Color(0x0D1D2130),
    tier2: Color(0x131D2130),
    field: Color(0x14468264),
    bodyFill: Color(0xFF565E7C),
    wing: Color(0xE6FFFFFF),
    logoHi: Color(0xEB1D2130),
    logoLo: Color(0x731D2130),
    brightness: Brightness.light,
  );

  /// Glass panel fill — the design's `linear-gradient(135deg, hi, lo)`.
  Gradient glass({bool strong = false}) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: strong ? [glass2Hi, glassLo] : [glassHi, glassLo],
      );

  /// Drop shadow for floating glass panels. (The design's inset edge
  /// highlight is drawn by [GlassPanel] as a hairline top border instead —
  /// Flutter's inner BoxShadow doesn't render the CSS effect faithfully.)
  List<BoxShadow> glassShadows({bool drop = true}) => [if (drop) shadow];
}

/// InheritedWidget carrying the active [FfColors]; rebuilds on theme flips.
class FireflyTheme extends InheritedWidget {
  const FireflyTheme({super.key, required this.colors, required super.child});

  final FfColors colors;

  static FfColors of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FireflyTheme>()!.colors;

  @override
  bool updateShouldNotify(FireflyTheme oldWidget) =>
      oldWidget.colors != colors;
}
