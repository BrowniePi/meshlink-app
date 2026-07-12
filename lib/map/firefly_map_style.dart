import 'package:flutter/material.dart' hide Theme;
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../ui/firefly/firefly_theme.dart';

/// Builds the vector-map render theme for the real-world map mode, in the
/// Firefly palette: near-monochrome glass tones on the app background, with
/// no cartographic colour of its own so markers and accent chrome stay the
/// loudest thing on screen.
///
/// The style targets the OpenMapTiles schema (what OpenFreeMap serves) with
/// the single source id [sourceId].
const String mapSourceId = 'openmaptiles';

Theme fireflyMapTheme(FfColors c) =>
    ThemeReader().read(_styleJson(_MapTones(c)));

/// Map-specific tones derived from the Firefly palette. The base tokens are
/// translucent whites/inks meant for glass panels; tiles need opaque paint,
/// so each tone is the token flattened onto the background colour.
class _MapTones {
  _MapTones(this.c)
      : bg = _mid(c),
        text = c.dim,
        halo = _mid(c).withValues(alpha: .85) {
    final dark = c.brightness == Brightness.dark;
    water = dark ? const Color(0xFF161D2C) : const Color(0xFFC9D4E0);
    green = dark ? const Color(0xFF14201D) : const Color(0xFFD7E1D4);
    landuse = _flat(dark ? 0x06FFFFFF : 0x071D2130);
    building = _flat(dark ? 0x12FFFFFF : 0x141D2130);
    roadMinor = _flat(dark ? 0x1AFFFFFF : 0xB3FFFFFF);
    roadMid = _flat(dark ? 0x26FFFFFF : 0xE6FFFFFF);
    roadMajor = _flat(dark ? 0x38FFFFFF : 0xFFFFFFFF);
    casing = dark ? const Color(0xFF0A0C12) : const Color(0xFFD2D6DE);
    rail = _flat(dark ? 0x14FFFFFF : 0x1F1D2130);
    boundary = _flat(dark ? 0x2EFFFFFF : 0x2E1D2130);
  }

  final FfColors c;

  /// Opaque backdrop: the middle stop of the app's background gradient.
  final Color bg;
  final Color text;
  final Color halo;
  late final Color water,
      green,
      landuse,
      building,
      roadMinor,
      roadMid,
      roadMajor,
      casing,
      rail,
      boundary;

  static Color _mid(FfColors c) =>
      (c.bg as LinearGradient).colors[1];

  /// Flatten a translucent ARGB value onto the map background.
  Color _flat(int argb) => Color.alphaBlend(Color(argb), _mid(c));
}

String _rgba(Color color) => 'rgba(${(color.r * 255).round()},'
    '${(color.g * 255).round()},${(color.b * 255).round()},${color.a})';

Map<String, dynamic> _styleJson(_MapTones t) {
  final faint = _rgba(t.c.faint);
  final dim = _rgba(t.c.dim);
  final halo = _rgba(t.halo);

  Map<String, dynamic> line(
    String id,
    dynamic filter,
    Color color,
    List<List<num>> widthStops, {
    List<num>? dash,
    int minzoom = 0,
  }) =>
      {
        'id': id,
        'type': 'line',
        'source': mapSourceId,
        'source-layer': 'transportation',
        if (minzoom > 0) 'minzoom': minzoom,
        'filter': filter,
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {
          'line-color': _rgba(color),
          'line-width': {'base': 1.4, 'stops': widthStops},
          'line-dasharray': ?dash,
        },
      };

  return {
    'version': 8,
    'name': 'firefly',
    'sources': {
      mapSourceId: {'type': 'vector'},
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': _rgba(t.bg)},
      },
      {
        'id': 'landcover',
        'type': 'fill',
        'source': mapSourceId,
        'source-layer': 'landcover',
        'filter': ['in', 'class', 'grass', 'wood', 'farmland', 'sand'],
        'paint': {'fill-color': _rgba(t.green)},
      },
      {
        'id': 'landuse',
        'type': 'fill',
        'source': mapSourceId,
        'source-layer': 'landuse',
        'filter': [
          'in', 'class', 'residential', 'commercial', 'industrial',
          'suburb', 'neighbourhood'
        ],
        'paint': {'fill-color': _rgba(t.landuse)},
      },
      {
        'id': 'park',
        'type': 'fill',
        'source': mapSourceId,
        'source-layer': 'park',
        'paint': {'fill-color': _rgba(t.green)},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': mapSourceId,
        'source-layer': 'water',
        'paint': {'fill-color': _rgba(t.water)},
      },
      {
        'id': 'waterway',
        'type': 'line',
        'source': mapSourceId,
        'source-layer': 'waterway',
        'paint': {
          'line-color': _rgba(t.water),
          'line-width': {
            'base': 1.3,
            'stops': [
              [11, 0.5],
              [20, 6]
            ]
          },
        },
      },
      {
        'id': 'building',
        'type': 'fill',
        'source': mapSourceId,
        'source-layer': 'building',
        'minzoom': 13,
        'paint': {
          'fill-color': _rgba(t.building),
          'fill-outline-color': _rgba(t.casing),
        },
      },
      line(
        'road-major-casing',
        ['in', 'class', 'motorway', 'trunk', 'primary'],
        t.casing,
        [
          [7, 1.4],
          [20, 26]
        ],
        minzoom: 7,
      ),
      line(
        'road-path',
        ['in', 'class', 'path', 'track', 'pedestrian'],
        t.roadMinor,
        [
          [14, 0.8],
          [20, 4]
        ],
        dash: [2, 2],
        minzoom: 14,
      ),
      line(
        'road-minor',
        ['in', 'class', 'minor', 'service'],
        t.roadMinor,
        [
          [12, 0.6],
          [20, 12]
        ],
        minzoom: 12,
      ),
      line(
        'road-mid',
        ['in', 'class', 'secondary', 'tertiary'],
        t.roadMid,
        [
          [9, 0.8],
          [20, 18]
        ],
        minzoom: 9,
      ),
      line(
        'road-major',
        ['in', 'class', 'motorway', 'trunk', 'primary'],
        t.roadMajor,
        [
          [7, 1],
          [20, 22]
        ],
        minzoom: 7,
      ),
      line(
        'rail',
        ['in', 'class', 'rail', 'transit'],
        t.rail,
        [
          [10, 0.8],
          [20, 5]
        ],
        dash: [4, 3],
        minzoom: 10,
      ),
      {
        'id': 'boundary',
        'type': 'line',
        'source': mapSourceId,
        'source-layer': 'boundary',
        'filter': ['<=', 'admin_level', 6],
        'paint': {
          'line-color': _rgba(t.boundary),
          'line-dasharray': [3, 3],
          'line-width': 1,
        },
      },
      {
        'id': 'road-name',
        'type': 'symbol',
        'source': mapSourceId,
        'source-layer': 'transportation_name',
        'minzoom': 14,
        'layout': {
          'symbol-placement': 'line',
          'text-field': '{name}',
          'text-font': ['Space Grotesk'],
          'text-size': 11,
        },
        'paint': {
          'text-color': faint,
          'text-halo-color': halo,
          'text-halo-width': 1.2,
        },
      },
      {
        'id': 'place-minor',
        'type': 'symbol',
        'source': mapSourceId,
        'source-layer': 'place',
        'minzoom': 11,
        'filter': ['in', 'class', 'suburb', 'neighbourhood', 'quarter'],
        'layout': {
          'text-field': '{name}',
          'text-font': ['Space Grotesk'],
          'text-size': 11,
          'text-letter-spacing': 0.15,
          'text-transform': 'uppercase',
        },
        'paint': {
          'text-color': faint,
          'text-halo-color': halo,
          'text-halo-width': 1.4,
        },
      },
      {
        'id': 'place-major',
        'type': 'symbol',
        'source': mapSourceId,
        'source-layer': 'place',
        'filter': ['in', 'class', 'city', 'town', 'village'],
        'layout': {
          'text-field': '{name}',
          'text-font': ['Space Grotesk'],
          'text-size': {
            'stops': [
              [4, 11],
              [12, 16]
            ]
          },
        },
        'paint': {
          'text-color': dim,
          'text-halo-color': halo,
          'text-halo-width': 1.4,
        },
      },
    ],
  };
}
