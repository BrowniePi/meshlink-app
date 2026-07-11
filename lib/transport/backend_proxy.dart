import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../debug/debug_log.dart' as dbg;
import 'transport.dart';

/// Backend-via-node: run the app's backend HTTP flows through a mesh node
/// when the phone has no internet (venue WiFi is a closed network; BLE
/// reaches only the node). Node half: meshlink-node node/backend_proxy.py,
/// which executes the request over the node's own uplink — the WiFi LAN on
/// a macOS dev node, the backend's batman-adv mesh address on a Pi.
///
/// Wire contract — `MLBP1`-prefixed JSON control frames, the same
/// phone↔node demux pattern as the `MLPP1` telemetry ping:
///
///     app → node: MLBP1{"t":"req","id":"a3","method":"POST",
///                       "path":"/tickets","headers":{…},"body":"{…}"}
///     node → app: MLBP1{"t":"res","id":"a3","status":201,"body":"{…}"}
///                 MLBP1{"t":"res","id":"a3","status":0,"error":"…"}
///
/// status 0 = the node's uplink failed; real backend rejections keep their
/// HTTP status so callers' retryable/definitive handling is unaffected.

const _magic = 'MLBP1';
final Uint8List _magicBytes = Uint8List.fromList(utf8.encode(_magic));

/// Demux rule: proxy frames — and only they — start with `MLBP1`. A real
/// mesh packet starts with a random 16-byte msg_id (false match ~2^-40).
bool isBackendProxyFrame(Uint8List data) {
  if (data.length < _magicBytes.length) return false;
  for (var i = 0; i < _magicBytes.length; i++) {
    if (data[i] != _magicBytes[i]) return false;
  }
  return true;
}

/// One proxied backend answer. [status] is the backend's HTTP status.
class ProxyResponse {
  const ProxyResponse({required this.status, required this.body});

  final int status;
  final String body;
}

/// Raised when the request could not complete via the node: no node peer,
/// reply timeout, or the node reported an uplink failure (status 0).
class ProxyException implements Exception {
  const ProxyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The phone side of the MLBP1 channel: frames requests to the connected
/// node and correlates the replies. Attached to the [Transport] once it
/// exists ([FailoverTransport] does this and demuxes replies back in).
class NodeBackendChannel {
  Transport? _transport;
  int _nextId = 0;
  final Map<String, Completer<ProxyResponse>> _pending = {};

  void attach(Transport transport) => _transport = transport;

  /// Whether a request could go out right now: transport up with ≥1 peer.
  /// Peers may be relay phones rather than nodes — then the request simply
  /// times out and callers fall back to their normal failure path.
  bool get available =>
      _transport != null && _transport!.listPeers().isNotEmpty;

  /// Consume one demuxed `MLBP1` frame (the transport hands these over).
  void handleFrame(String peerId, Uint8List data) {
    final Map<String, dynamic> frame;
    try {
      frame = jsonDecode(utf8.decode(data.sublist(_magicBytes.length)))
          as Map<String, dynamic>;
    } catch (_) {
      return; // malformed → drop silently, per the wire contract
    }
    if (frame['t'] != 'res') return;
    final completer = _pending.remove(frame['id']);
    if (completer == null) return; // late reply after timeout
    final status = frame['status'];
    if (status is! int || status == 0) {
      completer.completeError(ProxyException(
          (frame['error'] as String?) ?? 'node could not reach the backend'));
      return;
    }
    completer
        .complete(ProxyResponse(status: status, body: frame['body'] as String? ?? ''));
  }

  /// Send one request via the node and await its reply. The timeout covers
  /// the whole round trip — BLE at 180-byte notify chunks is slow, so it is
  /// deliberately generous.
  Future<ProxyResponse> request({
    required String method,
    required String path,
    String? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final transport = _transport;
    final peers = transport?.listPeers() ?? const [];
    if (transport == null || peers.isEmpty) {
      throw const ProxyException('no mesh node connected');
    }
    final id = (_nextId++).toRadixString(16);
    final frame = <String, dynamic>{
      't': 'req',
      'id': id,
      'method': method,
      'path': path,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
      'body': ?body,
    };
    final completer = Completer<ProxyResponse>();
    _pending[id] = completer;
    dbg.DebugLog.instance.log('proxy', '$method $path via node ${peers.first}');
    try {
      // One Future.wait so both futures get their listeners in this same
      // synchronous block — a transport delivering the reply (or its error)
      // synchronously must never leave the reply future unobserved.
      final results = await Future.wait<Object?>([
        transport.send(peers.first,
            Uint8List.fromList(utf8.encode('$_magic${jsonEncode(frame)}'))),
        completer.future.timeout(timeout),
      ], eagerError: true);
      return results[1]! as ProxyResponse;
    } on TimeoutException {
      throw const ProxyException('node did not answer in time');
    } finally {
      _pending.remove(id);
    }
  }
}

/// Drop-in `http.Client` for the backend clients (auth, attestation, events,
/// directory): tries the internet first, and when that fails falls back to
/// the node channel if a mesh peer is connected. Callers keep their existing
/// status-code handling — a proxied response carries the backend's status.
class MeshBackendClient extends http.BaseClient {
  MeshBackendClient({
    required this.channel,
    http.Client? direct,
    this.directTimeout = const Duration(seconds: 8),
    this.authTimeout = const Duration(seconds: 75),
  }) : _direct = direct ?? http.Client();

  final NodeBackendChannel channel;
  final http.Client _direct;

  /// Cap on the direct attempt so the mesh fallback still fits within the
  /// callers' own request timeouts.
  final Duration directTimeout;

  /// TEMPORARY — the backend is on a Render free plan, which suspends the
  /// service when idle and takes ~50s to boot on the next request. Logging in
  /// or signing up is usually that first request, so the normal cap reports
  /// "Backend unreachable" while the server is merely waking. Drop this back
  /// to [directTimeout] once the backend is on an always-on plan.
  final Duration authTimeout;

  /// [directTimeout] exists only so a failed direct attempt still leaves room
  /// for the mesh fallback, so it applies whenever that fallback is actually
  /// there. With no node connected there is nothing to fall back to and
  /// nothing the short cap buys — so an auth call may wait out a cold start
  /// instead of failing at 8s.
  Duration _timeoutFor(Uri url) =>
      url.path.startsWith('/auth/') && !channel.available
          ? authTimeout
          : directTimeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Buffer the body up front: a BaseRequest finalizes once, and we may
    // need to replay it over the node channel.
    final bodyBytes = request is http.Request
        ? request.bodyBytes
        : await request.finalize().toBytes();
    try {
      return await _direct
          .send(_rebuild(request, bodyBytes))
          .timeout(_timeoutFor(request.url));
    } on Exception catch (e) {
      if (!channel.available) rethrow;
      dbg.DebugLog.instance
          .log('proxy', 'direct ${request.url.path} failed ($e) — via node');
      final auth = request.headers['Authorization'] ??
          request.headers['authorization'];
      final ProxyResponse response;
      try {
        response = await channel.request(
          method: request.method,
          path: request.url.hasQuery
              ? '${request.url.path}?${request.url.query}'
              : request.url.path,
          body: bodyBytes.isEmpty ? null : utf8.decode(bodyBytes),
          headers: {'authorization': ?auth},
        );
      } on ProxyException catch (e) {
        throw http.ClientException(e.message, request.url);
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode(response.body)),
        response.status,
        request: request,
        headers: const {'content-type': 'application/json'},
      );
    }
  }

  http.Request _rebuild(http.BaseRequest request, Uint8List bodyBytes) {
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bodyBytes;
    return copy;
  }

  @override
  void close() => _direct.close();
}
