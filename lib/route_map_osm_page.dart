import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class RouteMapOsmPage extends StatefulWidget {
  final String routeId;
  const RouteMapOsmPage({super.key, required this.routeId});
  @override
  State<RouteMapOsmPage> createState() => _RouteMapOsmPageState();
}

class _RouteMapOsmPageState extends State<RouteMapOsmPage> {
  final mapController = MapController();

  // ✅ نفس الداتا بتاعتك
  final String collection = "routes";
  String get docId => widget.routeId;

  List<LatLng> routePoints = [];
  LatLng? start;
  LatLng? end;

  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadRoute();
  }

  Future<void> _loadRoute() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(collection)
          .doc(docId)
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

      // start/end لو موجودين، وإلا أول/آخر نقطة
      final GeoPoint? startGp = data['start'];
      final GeoPoint? endGp = data['end'];

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

      // زووم مناسب حول المسار
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitBounds();
      });
    } catch (e) {
      setState(() {
        error = "فشل تحميل المسار: $e";
        loading = false;
      });
    }
  }

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
        title: const Text("Route Map (OpenStreetMap)"),
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

          // ✅ خط المسار
          PolylineLayer(
            polylines: [Polyline(points: routePoints, strokeWidth: 5)],
          ),

          // ✅ ماركر بداية/نهاية
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
            ],
          ),
        ],
      ),
    );
  }
}
