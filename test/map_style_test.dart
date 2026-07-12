import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/map/firefly_map_style.dart';
import 'package:meshlink_app/ui/firefly/firefly_theme.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('firefly map style parses into a render theme for both themes', () {
    for (final colors in [FfColors.dark, FfColors.light]) {
      final theme = fireflyMapTheme(colors);
      expect(theme.tileSources, contains(mapSourceId));
      // background + fills + roads + labels; a silently-dropped layer would
      // shrink this.
      expect(theme.layers.length, greaterThanOrEqualTo(15));
    }
  });

  test('a bundled tile renders with the firefly theme', () async {
    // Any z14 tile from the bundled demo area exercises the style against
    // the real OpenMapTiles schema (bad source-layer names or filters would
    // render nothing or throw).
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final tileAsset = manifest
        .listAssets()
        .firstWhere((a) => a.startsWith('assets/map_tiles/14_'));
    final bytes = (await rootBundle.load(tileAsset)).buffer.asUint8List();

    final theme = fireflyMapTheme(FfColors.dark);
    final tile = vtr.TileFactory(theme, const vtr.Logger.noop())
        .createTileData(vtr.VectorTileReader().read(bytes));
    // Streets exist in central Mumbai; an empty layer set means the style
    // and the tile schema don't line up.
    expect(tile.layers, isNotEmpty);
  });
}
