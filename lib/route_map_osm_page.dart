// RouteMapOsmPage (للراكب)

// تقرأ routes/{routeId} وتعرض polyline

// وتقرأ driver_locations وتعرض السيارات المرتبطة بنفس routeId.

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class RouteMapOsmPage extends StatefulWidget {
  final String routeId;
  const RouteMapOsmPage({super.key, required this.routeId});

  @override
  State<RouteMapOsmPage> createState() => _RouteMapOsmPageState();
}

class _RouteMapOsmPageState extends State<RouteMapOsmPage> {
  final MapController mapController = MapController();

  final String routesCollection = "routes";
  final String driversCollection = "driver_locations";

  final Distance _distance = const Distance();

  // ✅ عدّلها حسب رغبتك: 80 / 120 / 200
  final double thresholdMeters = 150;

  List<LatLng> routePoints = [];
  LatLng? start;
  LatLng? end;

  bool loading = true;
  String? error;

  List<_DriverMarker> driversOnRoute = [];
  StreamSubscription<QuerySnapshot>? _driversSub;

  @override
  void initState() {
    super.initState();
    _loadRouteThenListenDrivers();
  }

  @override
  void dispose() {
    _driversSub?.cancel();
    super.dispose();
  }

  Future<void> _loadRouteThenListenDrivers() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(routesCollection)
          .doc(widget.routeId)
          .get();

      if (!snap.exists) {
        setState(() {
          error = "المسار غير موجود";
          loading = false;
        });
        return;
      }

      final data = snap.data()!;
      final List points = (data['points'] ?? []) as List;

      final pts = points.map((p) {
        final gp = p as GeoPoint;
        return LatLng(gp.latitude, gp.longitude);
      }).toList();

      if (pts.isEmpty) {
        setState(() {
          error = "مافي نقاط في المسار";
          loading = false;
        });
        return;
      }

      final GeoPoint? startGp = data['start'] as GeoPoint?;
      final GeoPoint? endGp = data['end'] as GeoPoint?;

      final s = startGp != null
          ? LatLng(startGp.latitude, startGp.longitude)
          : pts.first;

      final e = endGp != null
          ? LatLng(endGp.latitude, endGp.longitude)
          : pts.last;

      setState(() {
        routePoints = pts;
        start = s;
        end = e;
        loading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds());

      _listenDrivers();
    } catch (e) {
      setState(() {
        error = "فشل تحميل المسار: $e";
        loading = false;
      });
    }
  }

  void _listenDrivers() {
    _driversSub?.cancel();

    final stream = FirebaseFirestore.instance
        .collection(driversCollection)
        .where('isOnline', isEqualTo: true)
        .where('routeId', isEqualTo: widget.routeId) // ✅ فلترة حسب المسار
        .snapshots();

    _driversSub = stream.listen((snap) {
      final List<_DriverMarker> matches = [];

      for (final doc in snap.docs) {
        final data = doc.data() as Map<String, dynamic>;

        final lat = data['lat'];
        final lng = data['lng'];
        if (lat == null || lng == null) continue;

        final p = LatLng((lat as num).toDouble(), (lng as num).toDouble());
        matches.add(
          _DriverMarker(id: doc.id, point: p, distanceToRouteMeters: 0),
        );
      }

      if (!mounted) return;
      setState(() => driversOnRoute = matches);
    });
  }

  // ---------------- Geo helpers ----------------

  LatLngBounds _routeBounds(List<LatLng> pts) {
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;

    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    return LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }

  bool _inBoundsWithPadding(
    LatLng p,
    LatLngBounds b, {
    required double padMeters,
  }) {
    // 1° lat تقريباً 111km
    final padLat = padMeters / 111000.0;

    // 1° lng يعتمد على latitude
    final metersPerDegLng =
        111000.0 * math.cos(p.latitude * math.pi / 180.0).abs().clamp(0.2, 1.0);
    final padLng = padMeters / metersPerDegLng;

    return p.latitude >= (b.southWest.latitude - padLat) &&
        p.latitude <= (b.northEast.latitude + padLat) &&
        p.longitude >= (b.southWest.longitude - padLng) &&
        p.longitude <= (b.northEast.longitude + padLng);
  }

  double _minDistancePointToPolylineMeters(LatLng p, List<LatLng> poly) {
    if (poly.length < 2) {
      return _distance.as(LengthUnit.Meter, p, poly.first);
    }

    double best = double.infinity;
    for (int i = 0; i < poly.length - 1; i++) {
      final a = poly[i];
      final b = poly[i + 1];
      final d = _distancePointToSegmentMeters(p, a, b);
      if (d < best) best = d;
    }
    return best;
  }

  // مسافة نقطة إلى segment (تقريب مسطح محلي بالمتر)
  double _distancePointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final ax = 0.0;
    final ay = 0.0;

    final bx = _metersEast(a, b);
    final by = _metersNorth(a, b);

    final px = _metersEast(a, p);
    final py = _metersNorth(a, p);

    final dx = bx - ax;
    final dy = by - ay;

    final len2 = dx * dx + dy * dy;
    if (len2 == 0) {
      return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    }

    double t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);

    final cx = ax + t * dx;
    final cy = ay + t * dy;

    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  double _metersNorth(LatLng origin, LatLng p) {
    return (p.latitude - origin.latitude) * 111000.0;
  }

  double _metersEast(LatLng origin, LatLng p) {
    final latRad = origin.latitude * math.pi / 180.0;
    final metersPerDeg = 111000.0 * math.cos(latRad).abs().clamp(0.2, 1.0);
    return (p.longitude - origin.longitude) * metersPerDeg;
  }

  // ---------------- Map helpers ----------------

  void _fitBounds() {
    if (routePoints.isEmpty) return;

    double minLat = routePoints.first.latitude,
        maxLat = routePoints.first.latitude;
    double minLng = routePoints.first.longitude,
        maxLng = routePoints.first.longitude;

    for (final p in routePoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
    mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Route Map (OSM)")),
        body: Center(child: Text(error!, textAlign: TextAlign.center)),
      );
    }

    final center = start ?? routePoints.first;

    return Scaffold(
      appBar: AppBar(
        title: Text("Drivers on Route (${driversOnRoute.length})"),
        actions: [
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _fitBounds,
            tooltip: "Fit route",
          ),
        ],
      ),
      body: FlutterMap(
        mapController: mapController,
        options: MapOptions(initialCenter: center, initialZoom: 15),
        children: [
          TileLayer(
            urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            userAgentPackageName: "com.example.project1",
          ),

          PolylineLayer(
            polylines: [Polyline(points: routePoints, strokeWidth: 5)],
          ),

          MarkerLayer(
            markers: [
              if (start != null)
                Marker(
                  point: start!,
                  width: 40,
                  height: 40,
                  child: const Icon(Icons.play_arrow, size: 36),
                ),
              if (end != null)
                Marker(
                  point: end!,
                  width: 40,
                  height: 40,
                  child: const Icon(Icons.flag, size: 30),
                ),

              // ✅ كل السواقين داخل المسار
              ...driversOnRoute.map(
                (d) => Marker(
                  point: d.point,
                  width: 34,
                  height: 34,
                  child: const Icon(Icons.local_taxi, size: 28),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DriverMarker {
  final String id;
  final LatLng point;
  final double distanceToRouteMeters;

  _DriverMarker({
    required this.id,
    required this.point,
    required this.distanceToRouteMeters,
  });
}
