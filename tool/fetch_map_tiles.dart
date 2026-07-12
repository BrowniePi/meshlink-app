// Dev-time helper: download the OpenFreeMap vector tiles covering a bounding
// box into assets/map_tiles/, so the app ships with an offline map floor for
// the demo area. Run once (and re-run only if the area changes):
//
//   dart run tool/fetch_map_tiles.dart --bbox <west,south,east,north>
//
// Defaults to central Mumbai. Tiles are fetched z0–14 (14 is the source's
// max zoom; the renderer overzooms beyond that), flat-named z_x_y.pbf so a
// single `assets/map_tiles/` entry in pubspec.yaml picks them all up.
//
// Be polite: this hits a free public service, so keep the box venue-sized
// (a few km). A ~5 km box is well under a hundred tiles.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

const tileJsonUrl = 'https://tiles.openfreemap.org/planet';
const maxZoom = 14;
const outDir = 'assets/map_tiles';

// Central Mumbai, ~6 km box.
const defaultBbox = [72.79, 18.90, 72.88, 18.99];

void main(List<String> args) async {
  var bbox = defaultBbox;
  final i = args.indexOf('--bbox');
  if (i >= 0 && i + 1 < args.length) {
    bbox = args[i + 1].split(',').map(double.parse).toList();
    if (bbox.length != 4) {
      stderr.writeln('--bbox wants west,south,east,north');
      exit(1);
    }
  }
  final [west, south, east, north] = bbox;

  final client = HttpClient();
  final template = await _tileTemplate(client);
  stdout.writeln('tile template: $template');

  final dir = Directory(outDir)..createSync(recursive: true);
  var fetched = 0, bytes = 0;
  for (var z = 0; z <= maxZoom; z++) {
    final (x0, y0) = _tileAt(west, north, z);
    final (x1, y1) = _tileAt(east, south, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final file = File('${dir.path}/${z}_${x}_$y.pbf');
        if (file.existsSync()) continue;
        final url = template
            .replaceAll('{z}', '$z')
            .replaceAll('{x}', '$x')
            .replaceAll('{y}', '$y');
        final data = await _get(client, url);
        file.writeAsBytesSync(data);
        fetched++;
        bytes += data.length;
        stdout.write('\rz$z: $fetched tiles, ${bytes ~/ 1024} KB   ');
      }
    }
  }
  client.close();
  stdout.writeln('\ndone: $fetched new tiles, ${bytes ~/ 1024} KB in $outDir');
}

Future<String> _tileTemplate(HttpClient client) async {
  final body = utf8.decode(await _get(client, tileJsonUrl));
  return (jsonDecode(body) as Map<String, dynamic>)['tiles'][0] as String;
}

Future<List<int>> _get(HttpClient client, String url) async {
  final req = await client.getUrl(Uri.parse(url));
  final res = await req.close();
  if (res.statusCode != 200) {
    throw HttpException('$url -> ${res.statusCode}');
  }
  return [for (final chunk in await res.toList()) ...chunk];
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
