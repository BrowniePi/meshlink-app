import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/firefly/firefly_logo.dart';
import '../ui/firefly/firefly_theme.dart';
import '../ui/firefly/glass.dart';

/// Shared chrome for the account screens, in the Firefly design language:
/// the glowing logo + wordmark over the night gradient, with one frosted
/// glass card holding the form. [FireflyHome] provides [FireflyTheme] from
/// its own dark-mode toggle; pre-login there is no user preference yet, so
/// these screens follow the platform brightness instead.

/// Failure text color — matches the failed-DM tick in the chat panel.
const Color authErrorColor = Color(0xFFFF8A80);

/// TEMPORARY — the backend sleeps on Render's free plan and takes ~50s to boot
/// on the first request, which login/signup usually is. MeshBackendClient's
/// authTimeout allows for that wait; this tells the user why it is happening
/// rather than leaving them on a silent spinner for a minute. Remove both once
/// the backend is on an always-on plan.
const Duration authWakingAfter = Duration(seconds: 8);
const String authWakingMessage =
    'Waking the server — this can take up to a minute.';

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.hero = false,
  });

  final String title;

  /// Status line under the wordmark (the design's 11px dim line).
  final String? subtitle;

  /// Form content inside the glass card, below the title row.
  final List<Widget> children;

  /// Larger logo treatment for entry screens (login, welcome).
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    return FireflyTheme(
      colors: dark ? FfColors.dark : FfColors.light,
      child: Builder(builder: (context) {
        final c = FireflyTheme.of(context);
        // Route-scoped, not Navigator.canPop(): the latter is true whenever
        // *any* route sits above the first one, so login (still mounted under
        // a pushed screen) would rebuild with a back button it keeps after
        // that screen pops.
        final canPop = ModalRoute.of(context)?.canPop ?? false;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            decoration: BoxDecoration(gradient: c.bg),
            alignment: Alignment.center,
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FireflyLogo(size: hero ? 64 : 44, glow: 1),
                    const SizedBox(height: 12),
                    // The FIREFLY wordmark, sized for the header (mirrors
                    // FireflyWordmark's gradient treatment).
                    ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [c.logoHi, c.logoLo],
                      ).createShader(bounds),
                      child: Text(
                        'FIREFLY',
                        style: TextStyle(
                          fontSize: hero ? 22 : 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 6,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 5),
                      Text(subtitle!,
                          style: TextStyle(fontSize: 11, color: c.dim)),
                    ],
                    const SizedBox(height: 26),
                    GlassPanel(
                      radius: 28,
                      strong: true,
                      blur: 28,
                      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              if (canPop) ...[
                                GlassIconButton(
                                  icon: Icons.arrow_back_rounded,
                                  size: 32,
                                  iconSize: 18,
                                  onTap: () => Navigator.of(context).pop(),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(title,
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                        color: c.text)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          ...children,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Glass input capsule — the friends-panel add-friend field: glassLo fill,
/// radius 14, stroke border, faint leading icon, borderless dense TextField.
class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.controller,
    required this.icon,
    required this.hint,
    this.enabled = true,
    this.obscure = false,
    this.autofocus = false,
    this.keyboardType,
    this.autofillHints,
    this.inputFormatters,
    this.maxLength,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final bool enabled;
  final bool obscure;
  final bool autofocus;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.glassLo,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.stroke),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: c.faint),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              obscureText: obscure,
              autofocus: autofocus,
              keyboardType: keyboardType,
              autofillHints: autofillHints,
              inputFormatters: inputFormatters,
              maxLength: maxLength,
              cursorColor: c.accent,
              style: TextStyle(fontSize: 14, color: c.text),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: 14, color: c.faint),
                border: InputBorder.none,
                isDense: true,
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onSubmitted: onSubmitted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Accent primary CTA — the AccentButton spec (gold pill, radius 16, glow,
/// accentInk label) with a busy spinner state for network calls.
class AuthButton extends StatelessWidget {
  const AuthButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 16)],
        ),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: c.accentInk),
              )
            : Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.accentInk)),
      ),
    );
  }
}

/// Secondary navigation link (create account / forgot password / resend).
class AuthLink extends StatelessWidget {
  const AuthLink({
    super.key,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: enabled ? c.accent : c.faint)),
      ),
    );
  }
}

/// Accent progress spinner for in-card waiting states (attestation fetch,
/// event list load) — the AuthButton busy spinner, card-sized.
class AuthSpinner extends StatelessWidget {
  const AuthSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return SizedBox(
      width: 28,
      height: 28,
      child: CircularProgressIndicator(strokeWidth: 2.5, color: c.accent),
    );
  }
}

/// Glowing accent icon badge (verify / reset confirmation screens) — the
/// accent-soft circle with the firefly-tail glow.
class AuthBadge extends StatelessWidget {
  const AuthBadge({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.accentSoft,
        border: Border.all(color: c.accentLine),
        boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 24)],
      ),
      child: Icon(icon, size: 28, color: c.accent),
    );
  }
}

/// Body copy inside the glass card (13px dim). A widget rather than inline
/// Text because screens build above the [FireflyTheme] that [AuthScaffold]
/// provides — the theme is only readable from a context below it.
class AuthBody extends StatelessWidget {
  const AuthBody({super.key, required this.text, this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return Text(text,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: TextStyle(fontSize: 13, height: 1.45, color: c.dim));
  }
}

/// Panel-level notice line: coral for failures, accent for info — the
/// friends-panel `_notice` treatment.
class AuthNotice extends StatelessWidget {
  const AuthNotice({super.key, required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, color: error ? authErrorColor : c.accent)),
    );
  }
}
