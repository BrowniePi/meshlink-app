import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Persistent "Mesh Network Active · No Internet (by design)" strip, shown
/// whenever the WiFi mesh is enabled (WiFi Mesh Add-On §3.3).
///
/// The app-scoped network request already suppresses the OS's generic
/// broken-internet warning; this is deliberately redundant with that — the
/// explanation lives where the user is actually looking, so "connected but
/// no internet" reads as intentional, not a malfunction.
class MeshStatusIndicator extends StatelessWidget {
  const MeshStatusIndicator({super.key, required this.wifiEnabled});

  /// Follows [FailoverTransport.wifiEnabled].
  final ValueListenable<bool> wifiEnabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: wifiEnabled,
      builder: (context, enabled, _) {
        if (!enabled) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_tethering,
                    size: 16, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Mesh Network Active · No Internet (by design)',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
