import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import '../identity/secure_storage.dart';

/// One joinable event from the backend's GET /events catalogue.
class EventInfo {
  const EventInfo({required this.eventId, required this.name});

  final String eventId;
  final String name;

  Map<String, dynamic> toJson() => {'event_id': eventId, 'name': name};

  static EventInfo fromJson(Map<String, dynamic> json) => EventInfo(
        eventId: json['event_id'] as String,
        name: (json['name'] as String?) ?? json['event_id'] as String,
      );
}

/// Persists the event the user chose to join. The attestation token is bound
/// to this event id (nodes reject any other), so it is read at launch before
/// the onboarding gate and survives restarts like the token itself.
class EventStore {
  EventStore(this._storage);

  static const String _key = 'meshlink_event_v1';

  final SecureStorage _storage;

  Future<EventInfo?> read() async {
    final raw = await _storage.read(_key);
    if (raw == null) return null;
    try {
      return EventInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // unreadable → re-select
    }
  }

  Future<void> write(EventInfo event) =>
      _storage.write(_key, jsonEncode(event.toJson()));
}

/// Raised when the event catalogue cannot be fetched; always retryable (the
/// picker also offers the compile-time default event as an offline path).
class EventsException implements Exception {
  const EventsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches the joinable-event catalogue (GET /events).
class EventsClient {
  EventsClient({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  final BackendConfig config;
  final http.Client _client;

  Future<List<EventInfo>> list() async {
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('${config.baseUrl}/events'))
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const EventsException(
          'Backend timed out — check the connection and try again');
    } catch (_) {
      throw const EventsException('Cannot reach the ticketing backend');
    }
    if (response.statusCode != 200) {
      throw EventsException('Backend error (${response.statusCode})');
    }
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return [
        for (final e in body['events'] as List)
          EventInfo.fromJson(e as Map<String, dynamic>)
      ];
    } catch (_) {
      throw const EventsException('Malformed event list from backend');
    }
  }

  void close() => _client.close();
}
