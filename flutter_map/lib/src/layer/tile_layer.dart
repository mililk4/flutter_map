import 'dart:typed_data';

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:latlong/latlong.dart';
import 'package:flutter_map/src/core/bounds.dart';
import 'package:flutter_map/src/core/point.dart';
import 'package:flutter_map/src/map/map.dart';
import 'package:flutter_map/src/core/util.dart' as util;
import 'package:tuple/tuple.dart';
import 'package:quiver/core.dart';
import 'layer.dart';

class TileLayerOptions extends LayerOptions {
  final String urlTemplate;
  final double tileSize;
  final double maxZoom;
  final bool zoomReverse;
  final double zoomOffset;
  Map<String, String> additionalOptions;
  TileLayerOptions({
    this.urlTemplate,
    this.tileSize = 256.0,
    this.maxZoom = 18.0,
    this.zoomReverse = false,
    this.zoomOffset = 0.0,
    this.additionalOptions = const <String, String>{},
  });
}

class TileLayer extends StatefulWidget {
  final TileLayerOptions options;
  final MapState mapState;

  TileLayer({
    this.options,
    this.mapState,
  });

  State<StatefulWidget> createState() {
    return new _TileLayerState();
  }
}

class _TileLayerState extends State<TileLayer>
    with SingleTickerProviderStateMixin {
  MapState get map => widget.mapState;
  TileLayerOptions get options => widget.options;
  Bounds _globalTileRange;
  Tuple2<double, double> _wrapX;
  Tuple2<double, double> _wrapY;
  double _tileZoom;
  Level _level;

  Map<String, Tile> _tiles = {};
  Map<double, Level> _levels = {};

  void initState() {
    super.initState();
    _resetView();
    _controller = new AnimationController(vsync: this)
      ..addListener(_handleFlingAnimation);
  }

  String getTileUrl(Coords coords) {
    var data = <String, String>{
      'x': coords.x.round().toString(),
      'y': coords.y.round().toString(),
      'z': coords.z.round().toString(),
    };
    var allOpts = new Map.from(data)..addAll(this.options.additionalOptions);
    return util.template(this.options.urlTemplate, allOpts);
  }

  void _resetView() {
    this._setView(map.center, map.zoom);
  }

  void _setView(LatLng center, double zoom) {
    var tileZoom = this._clampZoom(zoom.round().toDouble());
    if (_tileZoom != tileZoom) {
      _tileZoom = tileZoom;
      _updateLevels();
      _resetGrid();
    }
    _setZoomTransforms(center, zoom);
  }

  Level _updateLevels() {
    var zoom = this._tileZoom;
    var maxZoom = this.options.maxZoom;

    if (zoom == null) return null;

    List<double> toRemove = [];
    for (var z in this._levels.keys) {
      if (_levels[z].children.length > 0 || z == zoom) {
        _levels[z].zIndex = maxZoom = (zoom - z).abs();
      } else {
        toRemove.add(z);
      }
    }

    for (var z in toRemove) {
      _removeTilesAtZoom(z);
    }

    var level = _levels[zoom];
    var map = this.map;

    if (level == null) {
      level = _levels[zoom] = new Level();
      level.zIndex = maxZoom;
      var newOrigin = map.project(map.unproject(map.getPixelOrigin()), zoom);
      if (newOrigin != null) {
        level.origin = newOrigin;
      } else {
        level.origin = new Point(0.0, 0.0);
      }
      level.zoom = zoom;

      _setZoomTransform(level, map.center, map.zoom);
    }
    this._level = level;
    return level;
  }

  void _setZoomTransform(Level level, LatLng center, double zoom) {
    var scale = map.getZoomScale(zoom, level.zoom);
    var pixelOrigin = map.getNewPixelOrigin(center, zoom).round();
    if (level.origin == null) {
      return;
    }
    var translate = level.origin.multiplyBy(scale) - pixelOrigin;
    level.translatePoint = translate;
    level.scale = scale;
  }

  void _setZoomTransforms(LatLng center, double zoom) {
    for (var i in this._levels.keys) {
      this._setZoomTransform(_levels[i], center, zoom);
    }
  }

  void _removeTilesAtZoom(double zoom) {
    List<String> toRemove = [];
    for (var key in _tiles.keys) {
      if (_tiles[key].coords.z != zoom) {
        continue;
      }
      toRemove.add(key);
    }
    for (var key in toRemove) {
      _removeTile(key);
    }
  }

  void _removeTile(String key) {
    var tile = _tiles[key];
    if (tile == null) {
      return;
    }
    _tiles[key].current = false;
  }

  _resetGrid() {
    var map = this.map;
    var crs = map.options.crs;
    var tileSize = this.getTileSize();
    var tileZoom = _tileZoom;

    var bounds = map.getPixelWorldBounds(_tileZoom);
    if (bounds != null) {
      _globalTileRange = _pxBoundsToTileRange(bounds);
    }

    // wrapping
    this._wrapX = crs.wrapLng;
    if (_wrapX != null) {
      var first = (map.project(new LatLng(0.0, crs.wrapLng.item1), tileZoom).x /
              tileSize.x)
          .floor()
          .toDouble();
      var second =
          (map.project(new LatLng(0.0, crs.wrapLng.item2), tileZoom).x /
                  tileSize.y)
              .ceil()
              .toDouble();
      _wrapX = new Tuple2(first, second);
    }

    this._wrapY = crs.wrapLat;
    if (_wrapY != null) {
      var first = (map.project(new LatLng(crs.wrapLat.item1, 0.0), tileZoom).y /
              tileSize.x)
          .floor()
          .toDouble();
      var second =
          (map.project(new LatLng(crs.wrapLat.item2, 0.0), tileZoom).y /
                  tileSize.y)
              .ceil()
              .toDouble();
      _wrapY = new Tuple2(first, second);
    }
  }

  double _clampZoom(double zoom) {
    // todo
    return zoom;
  }

  Point getTileSize() {
    return new Point(options.tileSize, options.tileSize);
  }

  Widget build(BuildContext context) {
    var pixelBounds = _getTiledPixelBounds(map.center);
    var tileRange = _pxBoundsToTileRange(pixelBounds);
    var tileCenter = tileRange.getCenter();
    var queue = <Coords>[];

    // mark tiles as out of view...
    for (var key in this._tiles.keys) {
      var c = this._tiles[key].coords;
      if (c.z != this._tileZoom) {
        _tiles[key].current = false;
      }
    }

    _setView(map.center, map.zoom);

    for (var j = tileRange.min.y; j <= tileRange.max.y; j++) {
      for (var i = tileRange.min.x; i <= tileRange.max.x; i++) {
        var coords = new Coords(i.toDouble(), j.toDouble());
        coords.z = this._tileZoom;

        if (!this._isValidTile(coords)) {
          continue;
        }

        // Add all valid tiles to the queue on Flutter
        queue.add(coords);
      }
    }

    if (queue.length > 0) {
      for (var i = 0; i < queue.length; i++) {
        _tiles[_tileCoordsToKey(queue[i])] =
            new Tile(_wrapCoords(queue[i]), true);
      }
    }

    var tilesToRender = <Tile>[];
    for (var tile in _tiles.values) {
      if ((tile.coords.z - _level.zoom).abs() > 1) {
        continue;
      }
      tilesToRender.add(tile);
    }
    tilesToRender.sort((aTile, bTile) {
      var a = aTile.coords;
      var b = bTile.coords;
      // a = 13, b = 12, b is less than a, the result should be positive.
      if (a.z != b.z) {
        return (b.z - a.z).toInt();
      }
      return (a.distanceTo(tileCenter) - b.distanceTo(tileCenter)).toInt();
    });

    var tileWidgets = <Widget>[];
    for (var tile in tilesToRender) {
      tileWidgets.add(_createTileWidget(tile.coords));
    }

    return new GestureDetector(
      onScaleStart: _handleScaleStart,
      onScaleUpdate: _handleScaleUpdate,
      onScaleEnd: _handleScaleEnd,
      child: new Container(
        child: new Stack(
          children: tileWidgets,
        ),
        color: Colors.grey[300],
      ),
    );
  }

  Point _offsetToPoint(Offset offset) {
    return new Point(offset.dx, offset.dy);
  }

  Offset _pointToOffset(Point point) {
    return new Offset(point.x, point.y);
  }

  LatLng _mapCenterStart;
  double _mapZoomStart;
  Point _focalPointStart;

  Offset _animationOffset = Offset.zero;

  void _handleScaleStart(ScaleStartDetails details) {
    setState(() {
      _mapZoomStart = map.zoom;
      _mapCenterStart = map.center;

      // Get the widget's offset
      var renderObject = context.findRenderObject() as RenderBox;
      var boxOffset = renderObject.localToGlobal(Offset.zero);

      // determine the focal point within the widget
      var localFocalPoint = _offsetToPoint(details.focalPoint - boxOffset);
      _focalPointStart = localFocalPoint;

      _controller.stop();
    });
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      var dScale = details.scale;
      for (var i = 0; i < 2; i++) {
        dScale = math.sqrt(dScale);
      }
      var renderObject = context.findRenderObject() as RenderBox;
      var boxOffset = renderObject.localToGlobal(Offset.zero);

      // Draw the focal point
      var localFocalPoint = _offsetToPoint(details.focalPoint - boxOffset);

      // get the focal point in global coordinates
      var dFocalPoint = localFocalPoint - _focalPointStart;

      var focalCenterDistance = localFocalPoint - (map.size / 2);
      var newCenter = map.project(_mapCenterStart) +
          focalCenterDistance.multiplyBy(1 - 1 / dScale) -
          dFocalPoint;

      var offsetPt = newCenter - map.project(_mapCenterStart);
      _animationOffset = _pointToOffset(offsetPt);

      var newZoom = _mapZoomStart * dScale;
      map.move(map.unproject(newCenter), newZoom);
    });
  }

  AnimationController _controller;
  Animation<Offset> _flingAnimation;
  static const double _kMinFlingVelocity = 800.0;

  void _handleScaleEnd(ScaleEndDetails details) {
    final double magnitude = details.velocity.pixelsPerSecond.distance;
    if (magnitude < _kMinFlingVelocity) return;
    final Offset direction = details.velocity.pixelsPerSecond / magnitude;
    final double distance = (Offset.zero & context.size).shortestSide;
    _flingAnimation = new Tween<Offset>(
            begin: _animationOffset,
            end: _animationOffset - direction * distance)
        .animate(_controller);
    _controller
      ..value = 0.0
      ..fling(velocity: magnitude / 1000.0);
  }

  void _handleFlingAnimation() {
    setState(() {
      _animationOffset = _flingAnimation.value;
      var newCenterPoint = map.project(_mapCenterStart) +
          new Point(_animationOffset.dx, _animationOffset.dy);
      var newCenter = map.unproject(newCenterPoint);
      map.move(newCenter, map.zoom);
    });
  }

  Bounds _getTiledPixelBounds(LatLng center) {
    var mapZoom = map.zoom;
    var scale = map.getZoomScale(mapZoom, this._tileZoom);
    var pixelCenter = map.project(center, this._tileZoom).floor();
    var halfSize = map.size / (scale * 2);
    return new Bounds(pixelCenter - halfSize, pixelCenter + halfSize);
  }

  Bounds _pxBoundsToTileRange(Bounds bounds) {
    var tileSize = this.getTileSize();
    return new Bounds(
      bounds.min.unscaleBy(tileSize).floor(),
      bounds.max.unscaleBy(tileSize).ceil() - new Point(1, 1),
    );
  }

  bool _isValidTile(Coords coords) {
    var crs = map.options.crs;
    if (!crs.infinite) {
      var bounds = _globalTileRange;
      if ((crs.wrapLng == null &&
              (coords.x < bounds.min.x || coords.x > bounds.max.x)) ||
          (crs.wrapLat == null &&
              (coords.y < bounds.min.y || coords.y > bounds.max.y))) {
        return false;
      }
    }
    return true;
  }

  String _tileCoordsToKey(Coords coords) {
    return "${coords.x}:${coords.y}:${coords.z}";
  }

  Widget _createTileWidget(Coords coords) {
    var tilePos = _getTilePos(coords);
    var level = _levels[coords.z];
    var tileSize = getTileSize();
    var pos = (tilePos).multiplyBy(level.scale) + level.translatePoint;
    var width = tileSize.x * level.scale;
    var height = tileSize.y * level.scale;
    var blankImageBytes = new Uint8List(0);

    return new Positioned(
      left: pos.x,
      top: pos.y,
      width: width,
      height: height,
      child: new Container(
        child: new FadeInImage(
          fadeInDuration: const Duration(milliseconds: 100),
          key: new Key(_tileCoordsToKey(coords)),
          // here `bytes` is a Uint8List containing the bytes for the in-memory image
          placeholder: new MemoryImage(blankImageBytes),
          image: new NetworkImage(getTileUrl(coords)),
          fit: BoxFit.fill,
        ),
      ),
    );
  }

  _wrapCoords(Coords coords) {
    var newCoords = new Coords(
      _wrapX != null
          ? util.wrapNum(coords.x.toDouble(), _wrapX)
          : coords.x.toDouble(),
      _wrapY != null
          ? util.wrapNum(coords.y.toDouble(), _wrapY)
          : coords.y.toDouble(),
    );
    newCoords.z = coords.z;
    return newCoords;
  }

  Point _getTilePos(Coords coords) {
    var level = _levels[coords.z];
    return coords.scaleBy(this.getTileSize()) - level.origin;
  }
}

class Tile {
  final Coords coords;
  bool current;
  Tile(this.coords, this.current);
}

class Level {
  List children = [];
  double zIndex;
  Point origin;
  double zoom;
  Point translatePoint;
  double scale;
}

class Coords<T extends num> extends Point<T> {
  T z;
  Coords(T x, T y) : super(x, y);
  String toString() => 'Coords($x, $y, $z)';
  bool operator ==(other) {
    if (other is Coords) {
      return this.x == other.x && this.y == other.y && this.z == other.z;
    }
    return false;
  }

  int get hashCode => hash3(x, y, z);
}
