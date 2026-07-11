import 'package:flutter/material.dart';

import '../auth/auth_chrome.dart';
import '../ui/firefly/firefly_theme.dart';
import 'event_store.dart';

/// Post-login gate: pick the event to join. The choice feeds the attestation
/// fetch (tokens are event-bound, Phase 5 §1) and is persisted by the caller.
/// The catalogue comes from GET /events; when the backend is unreachable the
/// compile-time default event stays available so a phone that is already at
/// the venue (mesh, no internet) is not locked out.
class EventSelectScreen extends StatefulWidget {
  const EventSelectScreen({
    super.key,
    required this.events,
    required this.defaultEvent,
    required this.onSelected,
  });

  final EventsClient events;

  /// Fallback offered when the catalogue fetch fails (BackendConfig.eventId).
  final EventInfo defaultEvent;

  final ValueChanged<EventInfo> onSelected;

  @override
  State<EventSelectScreen> createState() => _EventSelectScreenState();
}

class _EventSelectScreenState extends State<EventSelectScreen> {
  List<EventInfo>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _events = null;
      _error = null;
    });
    try {
      final events = await widget.events.list();
      if (!mounted) return;
      setState(() =>
          _events = events.isEmpty ? [widget.defaultEvent] : events);
    } on EventsException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Choose your event',
      subtitle: 'Off-grid messaging for events',
      children: [
        if (_error != null) ...[
          AuthBody(text: _error!),
          const SizedBox(height: 18),
          AuthButton(label: 'Try again', onTap: _load),
          const SizedBox(height: 6),
          Center(
            child: AuthLink(
              label: 'Continue with ${widget.defaultEvent.name}',
              onTap: () => widget.onSelected(widget.defaultEvent),
            ),
          ),
        ] else if (_events == null) ...[
          const Center(child: AuthSpinner()),
          const SizedBox(height: 18),
          const AuthBody(text: 'Fetching events…', center: true),
        ] else ...[
          const AuthBody(
              text: 'Your event pass and the venue mesh are tied to the '
                  'event you pick.'),
          const SizedBox(height: 14),
          for (final (i, event) in _events!.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            _EventTile(event: event, onTap: () => widget.onSelected(event)),
          ],
        ],
      ],
    );
  }
}

/// One joinable event — the AuthField capsule treatment as a tappable row.
class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.onTap});

  final EventInfo event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: c.glassLo,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.stroke),
        ),
        child: Row(
          children: [
            Icon(Icons.celebration_rounded, size: 19, color: c.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.name,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.text)),
                  if (event.name != event.eventId)
                    Text(event.eventId,
                        style: TextStyle(fontSize: 11, color: c.faint)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.faint),
          ],
        ),
      ),
    );
  }
}
