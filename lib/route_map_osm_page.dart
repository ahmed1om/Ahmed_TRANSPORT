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

  final String collection = "routes";
  String get docId => widget.routeId;

  List<LatLng> routePoints = [];
  LatLng? start;
  LatLng? end;

  bool loading = true;
  String? error;

  // ✅ فلترة بسيطة: ما نضيف نقطة جديدة إلا إذا ابتعدت X متر
  static const double _minDistanceMeters = 10; // غيّرها 5/15 حسب رغبتك
  final Distance _distance = const Distance();

  List<LatLng> _filterClosePoints(List<LatLng> pts) {
    if (pts.isEmpty) return pts;
    final out = <LatLng>[pts.first];
    for (int i = 1; i < pts.length; i++) {
      final d = _distance.as(LengthUnit.Meter, out.last, pts[i]);
      if (d >= _minDistanceMeters) out.add(pts[i]);
    }
    // تأكد آخر نقطة موجودة (عشان النهاية ما تضيع)
    if (out.last != pts.last) out.add(pts.last);
    return out;
  }

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

      final rawPts = points.map((p) {
        final gp = p as GeoPoint;
        return LatLng(gp.latitude, gp.longitude);
      }).toList();

      if (rawPts.isEmpty) {
        setState(() {
          error = "مافي نقاط في المسار";
          loading = false;
        });
        return;
      }

      // ✅ فلترة النقاط لتنعيم المسار
      final pts = _filterClosePoints(rawPts);

      // start/end لو موجودين وإلا أول/آخر نقطة
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

      WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds());
    } catch (e) {
      setState(() {
        error = "فشل تحميل المسار: $e";
        loading = false;
      });
    }
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
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(40, 90, 40, 40),
      ),
    );
  }

  // ✅ Marker احترافي: دائرة + حرف
  Widget _markerBadge({required String text, required Color color}) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            blurRadius: 10,
            offset: Offset(0, 4),
            color: Colors.black26,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
      ),
    );
  }

  // ✅ حساب مسافة تقريبية للمسار (مفيد في UI)
  double _routeDistanceKm(List<LatLng> pts) {
    if (pts.length < 2) return 0;
    double meters = 0;
    for (int i = 1; i < pts.length; i++) {
      meters += _distance.as(LengthUnit.Meter, pts[i - 1], pts[i]);
    }
    return meters / 1000.0;
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
    final distKm = _routeDistanceKm(routePoints);

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
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(initialCenter: center, initialZoom: 15),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName: "com.example.project1",
              ),

              // ✅ (1) حد خارجي للمسار (يخلي المسار واضح فوق الخريطة)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: routePoints,
                    strokeWidth: 10,
                    color: Colors.black.withValues(alpha: 0.45),
                    strokeCap: StrokeCap.round,
                    strokeJoin: StrokeJoin.round,
                  ),
                ],
              ),

              // ✅ (2) المسار نفسه (فوق الحد)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: routePoints,
                    strokeWidth: 6,
                    color: Colors.blueAccent,
                    strokeCap: StrokeCap.round,
                    strokeJoin: StrokeJoin.round,
                  ),
                ],
              ),

              // ✅ (3) Markers بداية/نهاية شكل احترافي
              MarkerLayer(
                markers: [
                  if (start != null)
                    Marker(
                      point: start!,
                      width: 40,
                      height: 40,
                      child: _markerBadge(text: "S", color: Colors.green),
                    ),
                  if (end != null)
                    Marker(
                      point: end!,
                      width: 40,
                      height: 40,
                      child: _markerBadge(text: "E", color: Colors.red),
                    ),
                ],
              ),
            ],
          ),

          // ✅ شريط معلومات بسيط (اختياري لكن مفيد)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 14,
                    offset: Offset(0, 6),
                    color: Colors.black26,
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.route),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Points: ${routePoints.length}  •  Distance: ${distKm.toStringAsFixed(2)} km",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
