// RouteMapOsmPage (للراكب)

// تقرأ routes/{routeId} وتعرض polyline

// وتقرأ driver_locations وتعرض السيارات المرتبطة بنفس routeId.

import 'dart:async';

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
        .where('routeId', isEqualTo: widget.routeId)
        .snapshots();

    _driversSub = stream.listen((snap) {
      final List<_DriverMarker> matches = [];

      for (final doc in snap.docs) {
        // ignore: unnecessary_cast
        final data = doc.data() as Map<String, dynamic>;
        //التعريف  بتاع البيانات دا ضروري ما تشتغل بي تحذير الكاست

        final lat = data['lat'];
        final lng = data['lng'];
        if (lat == null || lng == null) continue;

        final p = LatLng((lat as num).toDouble(), (lng as num).toDouble());

        matches.add(_DriverMarker(id: doc.id, point: p));
      }

      if (!mounted) return;
      setState(() => driversOnRoute = matches);
    });
  }

  void _fitBounds() {
    if (routePoints.isEmpty) return;

    double minLat = routePoints.first.latitude;
    double maxLat = routePoints.first.latitude;
    double minLng = routePoints.first.longitude;
    double maxLng = routePoints.first.longitude;

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
              // Start / End
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

              // Drivers (Cars)
              ...driversOnRoute.map(
                (d) => Marker(
                  point: d.point,
                  width: 38,
                  height: 38,
                  child: const Icon(Icons.directions_car, size: 34),
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

  _DriverMarker({required this.id, required this.point});
}
