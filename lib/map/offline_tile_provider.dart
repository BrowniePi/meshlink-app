import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'map_tile_store.dart';

/// OpenFreeMap TileJSON endpoint; resolved once per session to the dated
/// tile URL template it advertises (the snapshot path changes over time, so
/// hardcoding a template would eventually 404).
const String _tileJsonUrl = 'https://tiles.openfreemap.org/planet';

/// Max zoom the tile source provides; the renderer overzooms beyond it.
const int mapSourceMaxZoom = 14;

/// Vector tile provider for the real-world map: local store first (bundled
/// demo area + everything previously fetched), network fill on miss with
/// write-through. Tiles are effectively immutable, so cache-first is both
/// the fast path and, when offline, the only path — no connectivity checks
/// needed.
class OfflineFirstTileProvider extends VectorTileProvider {
  OfflineFirstTileProvider(this._store);

  final MapTileStore _store;
  Future<String?>? _template;

  @override
  int get maximumZoom => mapSourceMaxZoom;

  @override
  int get minimumZoom => 0;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final cached = await _store.get(tile.z, tile.x, tile.y);
    if (cached != null) return cached;
    final bytes = await fetchTile(tile.z, tile.x, tile.y);
    await _store.put(tile.z, tile.x, tile.y, bytes);
    return bytes;
  }

  /// Fetch a tile from the network, bypassing the store.
  Future<Uint8List> fetchTile(int z, int x, int y) async {
    final template = await (_template ??= _resolveTemplate());
    if (template == null) {
      _template = null; // retry TileJSON next time
      throw ProviderException(
          message: 'offline: no tile URL template', retryable: Retryable.none);
    }
    final url = template
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    final http.Response response;
    try {
      response = await http.get(Uri.parse(url));
    } on http.ClientException catch (e) {
      throw ProviderException(message: e.message, retryable: Retryable.none);
    }
    if (response.statusCode != 200) {
      throw ProviderException(
          message: 'tile $z/$x/$y: HTTP ${response.statusCode}',
          statusCode: response.statusCode,
          retryable:
              response.statusCode >= 500 ? Retryable.retry : Retryable.none);
    }
    return response.bodyBytes;
  }

  Future<String?> _resolveTemplate() async {
    try {
      final response = await http.get(Uri.parse(_tileJsonUrl));
      if (response.statusCode != 200) return null;
      final tiles =
          (jsonDecode(response.body) as Map<String, dynamic>)['tiles'];
      return (tiles as List).first as String;
    } catch (_) {
      return null;
    }
  }
}
