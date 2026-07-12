import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent local vector-tile storage for the real-world map: a flat
/// directory of `z_x_y.pbf` files in app documents, with the tiles bundled in
/// `assets/map_tiles/` as a read-only floor underneath. Every tile fetched
/// online is written through here, so the offline coverage grows as the map
/// is used; [MapRegionPrefetcher] bulk-fills it around the user.
class MapTileStore {
  MapTileStore._(this._dir, this._assetTiles);

  final Directory _dir;
  final Set<String> _assetTiles;

  /// Rough disk budget for downloaded tiles. Old tiles are evicted (least
  /// recently written first) when a put pushes usage past this.
  static const int maxBytes = 40 * 1024 * 1024;

  static Future<MapTileStore> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/map_tiles');
    await dir.create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assetTiles = {
      for (final key in manifest.listAssets())
        if (key.startsWith('assets/map_tiles/')) key,
    };
    return MapTileStore._(dir, assetTiles);
  }

  String _name(int z, int x, int y) => '${z}_${x}_$y.pbf';

  /// The tile from disk cache or the bundled assets, or null if we've never
  /// had it.
  Future<Uint8List?> get(int z, int x, int y) async {
    final file = File('${_dir.path}/${_name(z, x, y)}');
    if (await file.exists()) return file.readAsBytes();
    final asset = 'assets/map_tiles/${_name(z, x, y)}';
    if (_assetTiles.contains(asset)) {
      return (await rootBundle.load(asset)).buffer.asUint8List();
    }
    return null;
  }

  Future<bool> has(int z, int x, int y) async =>
      _assetTiles.contains('assets/map_tiles/${_name(z, x, y)}') ||
      await File('${_dir.path}/${_name(z, x, y)}').exists();

  Future<void> put(int z, int x, int y, Uint8List bytes) async {
    await File('${_dir.path}/${_name(z, x, y)}').writeAsBytes(bytes);
    await _evictIfOver();
  }

  Future<void> _evictIfOver() async {
    final files = <(File, FileStat)>[
      await for (final e in _dir.list())
        if (e is File) (e, await e.stat()),
    ];
    var total = files.fold(0, (a, f) => a + f.$2.size);
    if (total <= maxBytes) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in files) {
      if (total <= maxBytes) break;
      try {
        await file.delete();
        total -= stat.size;
      } on FileSystemException {
        // Concurrent delete/write; skip.
      }
    }
  }
}
