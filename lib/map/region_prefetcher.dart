import 'dart:math';

import '../debug/debug_log.dart' as dbg;
import 'map_tile_store.dart';
import 'offline_tile_provider.dart';

/// Bulk-fills the tile store around the user's position while online, so the
/// map keeps working when the mesh is all they have. Runs opportunistically:
/// call [maybePrefetch] whenever a GPS fix arrives; it no-ops unless the user
/// has moved well away from the last prefetched centre.
///
/// Zooms 0–[mapSourceMaxZoom] over a ~[radiusM] box is a few dozen tiles
/// (z14 tiles are ~2.4 km wide), typically single-digit MB.
class MapRegionPrefetcher {
  MapRegionPrefetcher(this._store, this._provider);

  final MapTileStore _store;
  final OfflineFirstTileProvider _provider;

  static const double radiusM = 4000;

  double? _lastLat, _lastLon;
  bool _running = false;
  DateTime _notBefore = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> maybePrefetch(double lat, double lon) async {
    if (_running || DateTime.now().isBefore(_notBefore)) return;
    final lastLat = _lastLat, lastLon = _lastLon;
    if (lastLat != null && lastLon != null) {
      final dx = (lon - lastLon) * cos(lat * pi / 180) * 111320;
      final dy = (lat - lastLat) * 110540;
      if (sqrt(dx * dx + dy * dy) < radiusM / 2) return;
    }
    _running = true;
    try {
      final fetched = await _prefetch(lat, lon);
      // Only mark the centre done once a full pass succeeded, so a run cut
      // short by going offline is retried from the next fix.
      _lastLat = lat;
      _lastLon = lon;
      if (fetched > 0) {
        dbg.DebugLog.instance.log('map', 'prefetched $fetched tiles around '
            '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}');
      }
    } catch (e) {
      // Most likely offline; don't hammer retries on every GPS fix.
      _notBefore = DateTime.now().add(const Duration(minutes: 5));
      dbg.DebugLog.instance.log('map', 'prefetch stopped: $e',
          level: dbg.LogLevel.warn);
    } finally {
      _running = false;
    }
  }

  Future<int> _prefetch(double lat, double lon) async {
    var fetched = 0;
    final dLat = radiusM / 110540;
    final dLon = radiusM / (111320 * cos(lat * pi / 180));
    for (var z = 0; z <= mapSourceMaxZoom; z++) {
      final (x0, y0) = _tileAt(lon - dLon, lat + dLat, z);
      final (x1, y1) = _tileAt(lon + dLon, lat - dLat, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          if (await _store.has(z, x, y)) continue;
          final bytes = await _provider.fetchTile(z, x, y);
          await _store.put(z, x, y, bytes);
          fetched++;
        }
      }
    }
    return fetched;
  }

  /// Slippy-map tile containing a lon/lat at zoom z.
  (int, int) _tileAt(double lon, double lat, int z) {
    final n = 1 << z;
    final x = ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
    final latRad = lat * pi / 180;
    final y = ((1 - log(tan(latRad) + 1 / cos(latRad)) / pi) / 2 * n)
        .floor()
        .clamp(0, n - 1);
    return (x, y);
  }
}
