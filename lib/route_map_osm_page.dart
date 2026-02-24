// RouteMapOsmPage (للراكب)

// تقرأ routes/{routeId} وتعرض polyline

// وتقرأ driver_locations وتعرض السيارات المرتبطة بنفس routeId.
//  بالكيلومترلقد عدلت ت هذه الصحة للراكب لتعرض سعر التكلفةة
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
  final Distance _dist = const Distance();

  final String routesCollection = "routes";
  final String driversCollection = "driver_locations";

  List<LatLng> routePoints = [];
  LatLng? start;
  LatLng? end;

  bool loading = true;
  String? error;

  // drivers
  List<LatLng> driverPoints = [];
  StreamSubscription<QuerySnapshot>? _driversSub;

  // pricing
  double perKm = 0;
  double baseFare = 0;
  StreamSubscription<DocumentSnapshot>? _pricingSub;

  // passenger selection
  LatLng? pickup;
  LatLng? dropoff;
  double? tripKm;
  double? tripCost;

  @override
  void initState() {
    super.initState();
    _loadRouteThenListen();
  }

  @override
  void dispose() {
    _driversSub?.cancel();
    _pricingSub?.cancel();
    super.dispose();
  }

  Future<void> _loadRouteThenListen() async {
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
      _listenPricing();
    } catch (e) {
      setState(() {
        error = "فشل تحميل المسار: $e";
        loading = false;
      });
    }
  }

  // ---------- pricing ----------
  void _listenPricing() {
    _pricingSub?.cancel();
    final ref = FirebaseFirestore.instance
        .collection('settings')
        .doc('pricing');

    _pricingSub = ref.snapshots().listen((doc) {
      // ignore: unnecessary_cast
      final data = doc.data() as Map<String, dynamic>? ?? {};
      perKm = (data['perKm'] as num?)?.toDouble() ?? 0;
      baseFare = (data['baseFare'] as num?)?.toDouble() ?? 0;

      if (mounted) {
        setState(() {});
        _recalcFare();
      }
    });
  }

  // ---------- drivers ----------
  void _listenDrivers() {
    _driversSub?.cancel();

    final stream = FirebaseFirestore.instance
        .collection(driversCollection)
        .where('isOnline', isEqualTo: true)
        .where('routeId', isEqualTo: widget.routeId)
        .snapshots();

    _driversSub = stream.listen((snap) {
      final pts = <LatLng>[];

      for (final doc in snap.docs) {
        // ignore: unnecessary_cast
        final data = doc.data() as Map<String, dynamic>;
        final lat = data['lat'];
        final lng = data['lng'];
        if (lat == null || lng == null) continue;

        pts.add(LatLng((lat as num).toDouble(), (lng as num).toDouble()));
      }

      if (!mounted) return;
      setState(() => driverPoints = pts);
    });
  }

  // ---------- passenger distance on route ----------
  int _nearestIndex(LatLng p) {
    int bestIdx = 0;
    double best = double.infinity;

    for (int i = 0; i < routePoints.length; i++) {
      final d = _dist.as(LengthUnit.Meter, p, routePoints[i]);
      if (d < best) {
        best = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  double _distanceOnRouteKm(LatLng a, LatLng b) {
    if (routePoints.length < 2) return 0;

    int ia = _nearestIndex(a);
    int ib = _nearestIndex(b);

    int from = ia, to = ib;
    if (from > to) {
      final tmp = from;
      from = to;
      to = tmp;
    }

    double meters = 0;
    for (int i = from; i < to; i++) {
      meters += _dist.as(LengthUnit.Meter, routePoints[i], routePoints[i + 1]);
    }
    return meters / 1000.0;
  }

  void _recalcFare() {
    if (pickup == null || dropoff == null) return;
    final km = _distanceOnRouteKm(pickup!, dropoff!);
    final cost = baseFare + (km * perKm);

    setState(() {
      tripKm = km;
      tripCost = cost;
    });
  }

  void _onMapTap(LatLng p) {
    // أول ضغطة: pickup
    if (pickup == null) {
      setState(() {
        pickup = p;
        dropoff = null;
        tripKm = null;
        tripCost = null;
      });
      return;
    }

    // ثاني ضغطة: dropoff
    if (dropoff == null) {
      setState(() => dropoff = p);
      _recalcFare();
      return;
    }

    // ثالث ضغطة: reset واعتبرها pickup جديد
    setState(() {
      pickup = p;
      dropoff = null;
      tripKm = null;
      tripCost = null;
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

    // info text
    String info = "اضغط على الخريطة لتحديد نقطة البداية ثم النهاية";
    if (pickup != null && dropoff == null) info = "حدد نقطة النهاية";
    if (pickup != null && dropoff != null) {
      info =
          "المسافة: ${tripKm?.toStringAsFixed(2) ?? '--'} كم  •  السعر: ${tripCost?.toStringAsFixed(0) ?? '--'}";
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Passenger • Cost Preview"),
        actions: [
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _fitBounds,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                pickup = null;
                dropoff = null;
                tripKm = null;
                tripCost = null;
              });
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 15,
              onTap: (tapPos, latLng) => _onMapTap(latLng),
            ),
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
                  // Drivers
                  ...driverPoints.map(
                    (p) => Marker(
                      point: p,
                      width: 38,
                      height: 38,
                      child: const Icon(Icons.directions_car, size: 34),
                    ),
                  ),

                  // Route start/end
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

                  // Passenger pickup/dropoff
                  if (pickup != null)
                    Marker(
                      point: pickup!,
                      width: 44,
                      height: 44,
                      child: const Icon(Icons.my_location, size: 40),
                    ),
                  if (dropoff != null)
                    Marker(
                      point: dropoff!,
                      width: 44,
                      height: 44,
                      child: const Icon(Icons.location_on, size: 40),
                    ),
                ],
              ),
            ],
          ),

          // Info bar
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text("perKm=$perKm • baseFare=$baseFare"),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
