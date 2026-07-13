import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';
import '../debug/debug_log.dart' as dbg;
import '../identity/token_storage.dart';

/// Raised when the attestation fetch cannot complete. [retryable] is true for
/// transient failures (network, 5xx) the UI should offer to retry, and false
/// for definitive rejections (bad ticket, wrong event, expired) that a retry
/// won't fix.
class AttestationException implements Exception {
  const AttestationException(this.message, {required this.retryable});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// Phase 5 onboarding: turn the device identity into a stored attestation
/// token by walking the backend's simulated ticket → token chain
/// (Phase 5 §1). Transient failures are retried with exponential backoff;
/// definitive rejections surface immediately as a non-retryable exception.
class AttestationFlow {
  AttestationFlow({
    required this.config,
    http.Client? client,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 500),
  }) : _client = client ?? http.Client();

  final BackendConfig config;
  final http.Client _client;
  final int maxAttempts;
  final Duration baseBackoff;

  /// Fetch a fresh token for [devicePubkeyHex] (hex of the Ed25519 public
  /// key). Purchases a ticket, exchanges it for a token, and returns both the
  /// token and its expiry. Throws [AttestationException] on failure.
  Future<AttestationToken> fetchToken(String devicePubkeyHex) async {
    dbg.DebugLog.instance.log('attest',
        'fetchToken: event=${config.eventId} device=${_short(devicePubkeyHex)}');
    final ticketId = await _retry(() => _createTicket(devicePubkeyHex));
    final token = await _retry(() => _requestToken(ticketId, devicePubkeyHex));
    dbg.DebugLog.instance.log('attest',
        'token acquired (expires ${token.expiresAt.toIso8601String()})');
    return token;
  }

  Future<String> _createTicket(String buyerPubkey) async {
    dbg.DebugLog.instance.log('attest', 'POST /functions/v1/tickets');
    final response = await _post('/functions/v1/tickets', {
      'event_id': config.eventId,
      'buyer_pubkey': buyerPubkey,
    });
    final ticketId = _decode(response)['ticket_id'] as String;
    dbg.DebugLog.instance.log('attest', 'ticket created: $ticketId');
    return ticketId;
  }

  Future<AttestationToken> _requestToken(
      String ticketId, String devicePubkey) async {
    dbg.DebugLog.instance
        .log('attest', 'POST /functions/v1/attestation-token (ticket $ticketId)');
    final response = await _post('/functions/v1/attestation-token', {
      'ticket_id': ticketId,
      'event_id': config.eventId,
      'device_pubkey': devicePubkey,
    });
    final body = _decode(response);
    return AttestationToken(
      token: body['token'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (body['expires_at'] as int) * 1000,
      ),
    );
  }

  static String _short(String hex) =>
      hex.length <= 12 ? hex : '${hex.substring(0, 12)}…';

  Future<http.Response> _post(String path, Map<String, dynamic> body) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('${config.baseUrl}$path'),
            headers: {
              'Content-Type': 'application/json',
              'apikey': config.anonKey,
              'Authorization': 'Bearer ${config.anonKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const AttestationException(
          'Backend timed out — check the connection and try again',
          retryable: true);
    } catch (_) {
      throw const AttestationException(
          'Cannot reach the ticketing backend', retryable: true);
    }

    final code = response.statusCode;
    if (code >= 200 && code < 300) return response;
    // 4xx are definitive (bad/expired ticket, wrong event); 5xx are transient.
    final reason = _errorReason(response) ?? 'Backend error ($code)';
    dbg.DebugLog.instance.log('attest', 'POST $path -> $code: $reason',
        level: dbg.LogLevel.error);
    throw AttestationException(reason, retryable: code >= 500);
  }

  Map<String, dynamic> _decode(http.Response r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  /// The Edge Functions return `{"detail": "..."}` on error (same shape the
  /// FastAPI backend used) — surface it if present.
  String? _errorReason(http.Response r) {
    try {
      final detail = (jsonDecode(r.body) as Map<String, dynamic>)['detail'];
      return detail is String ? detail : null;
    } catch (_) {
      return null;
    }
  }

  Future<T> _retry<T>(Future<T> Function() action) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await action();
      } on AttestationException catch (e) {
        if (!e.retryable || attempt >= maxAttempts) rethrow;
        dbg.DebugLog.instance.log('attest',
            'attempt $attempt/$maxAttempts failed (${e.message}) — backing off',
            level: dbg.LogLevel.warn);
        await Future<void>.delayed(baseBackoff * (1 << (attempt - 1)));
      }
    }
  }

  void close() => _client.close();
}
