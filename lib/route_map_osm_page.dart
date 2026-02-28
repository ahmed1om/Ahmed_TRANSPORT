// هذا الملف هو لصفحة الراكب بيعرض الخرطة والمسار
//  الفرق بينو انو بيعتمد النقطة بتاعت بداية الرحلة حقت الراكب
//  GPS بالـ
//  بناء على موقعه الحالي، وبيحدد نقطة البداية دي
//   تلقائياً، وبيحسب المسافة والتكلفة بناءً على المسار المخزن في Firestore. كمان بيعرض السواقين المتصلين على نفس المسار.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
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

  // Firestore
  final String routesCollection = "routes";
  final String driversCollection = "driver_locations";

  // Route geometry
  List<LatLng> routePoints = [];
  List<LatLng> segmentPoints = []; // ✅ الجزء بين pickup و dropoff
  LatLng? start;
  LatLng? end;

  // UI state
  bool loading = true;
  String? error;

  // Drivers markers
  List<LatLng> driverPoints = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _driversSub;

  // Pricing (settings/pricing)
  double perKm = 0;
  double baseFare = 0;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _pricingSub;

  // Passenger selection
  LatLng? pickup; // (snapped to route)
  LatLng? dropoff; // (snapped to route)
  double? tripKm;
  double? tripCost;

  // Optional: last request id
  String? lastRequestId;

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

  // ------------------- LOAD ROUTE -------------------

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

      final data = snap.data() ?? {};
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

  // ------------------- PRICING -------------------

  void _listenPricing() {
    _pricingSub?.cancel();

    final ref = FirebaseFirestore.instance
        .collection('settings')
        .doc('pricing');

    _pricingSub = ref.snapshots().listen((
      DocumentSnapshot<Map<String, dynamic>> doc,
    ) {
      final data = doc.data() ?? {};
      final newPerKm = (data['perKm'] as num?)?.toDouble() ?? 0;
      final newBaseFare = (data['baseFare'] as num?)?.toDouble() ?? 0;

      if (!mounted) return;
      setState(() {
        perKm = newPerKm;
        baseFare = newBaseFare;
      });

      _recalcFare(); // لو في pickup/dropoff
    });
  }

  // ------------------- DRIVERS -------------------

  void _listenDrivers() {
    _driversSub?.cancel();

    final stream = FirebaseFirestore.instance
        .collection(driversCollection)
        .withConverter<Map<String, dynamic>>(
          fromFirestore: (s, _) => s.data() ?? {},
          toFirestore: (m, _) => m,
        )
        .where('isOnline', isEqualTo: true)
        .where('routeId', isEqualTo: widget.routeId)
        .snapshots();

    _driversSub = stream.listen((snap) {
      final pts = <LatLng>[];

      for (final doc in snap.docs) {
        final data = doc.data(); // ✅ بدون cast

        final lat = data['lat'];
        final lng = data['lng'];
        if (lat == null || lng == null) continue;

        pts.add(LatLng((lat as num).toDouble(), (lng as num).toDouble()));
      }

      if (!mounted) return;
      setState(() => driverPoints = pts);
    });
  }

  // ------------------- ROUTE HELPERS -------------------

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

  /// يرجع (from,to) مرتبة تصاعدياً
  (int from, int to) _orderedIndices(LatLng a, LatLng b) {
    final ia = _nearestIndex(a);
    final ib = _nearestIndex(b);
    if (ia <= ib) return (ia, ib);
    return (ib, ia);
  }

  double _distanceOnRouteKm(LatLng a, LatLng b) {
    if (routePoints.length < 2) return 0;

    final (from, to) = _orderedIndices(a, b);

    double meters = 0;
    for (int i = from; i < to; i++) {
      meters += _dist.as(LengthUnit.Meter, routePoints[i], routePoints[i + 1]);
    }
    return meters / 1000.0;
  }

  void _buildSegment() {
    if (pickup == null || dropoff == null) {
      segmentPoints = [];
      return;
    }

    final (from, to) = _orderedIndices(pickup!, dropoff!);

    // ✅ segment = نقاط المسار بين أقرب نقطتين
    segmentPoints = routePoints.sublist(from, to + 1);
  }

  void _recalcFare() {
    if (pickup == null || dropoff == null) return;

    final km = _distanceOnRouteKm(pickup!, dropoff!);
    final cost = baseFare + (km * perKm);

    _buildSegment();

    if (!mounted) return;
    setState(() {
      tripKm = km;
      tripCost = cost;
    });
  }

  // ------------------- MAP INTERACTION -------------------

  /// نخلي النقطة تتثبت على أقرب نقطة في routePoints (عشان segment يكون مضبوط)
  LatLng _snapToRoute(LatLng p) => routePoints[_nearestIndex(p)];

  void _onMapTap(LatLng p) {
    final snapped = _snapToRoute(p);

    // أول ضغطة: pickup
    if (pickup == null) {
      setState(() {
        pickup = snapped;
        dropoff = null;
        tripKm = null;
        tripCost = null;
        segmentPoints = [];
        lastRequestId = null;
      });
      return;
    }

    // ثاني ضغطة: dropoff
    if (dropoff == null) {
      setState(() => dropoff = snapped);
      _recalcFare();
      return;
    }

    // ثالث ضغطة: reset واعتبرها pickup جديد
    setState(() {
      pickup = snapped;
      dropoff = null;
      tripKm = null;
      tripCost = null;
      segmentPoints = [];
      lastRequestId = null;
    });
  }

  Future<void> _useMyLocationAsPickup() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        _toast("شغّل الـ GPS من الجهاز");
        return;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        _toast("رفضت صلاحية الموقع");
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        _toast("الصلاحية مرفوضة نهائياً - فعّلها من Settings");
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );

      final snapped = _snapToRoute(LatLng(pos.latitude, pos.longitude));

      setState(() {
        pickup = snapped;
        dropoff = null;
        tripKm = null;
        tripCost = null;
        segmentPoints = [];
        lastRequestId = null;
      });

      _toast("تم تحديد البداية من موقعك الحالي (على أقرب نقطة في المسار)");
    } catch (e) {
      _toast("فشل تحديد الموقع: $e");
    }
  }

  // ------------------- CONFIRM (اختياري) -------------------

  Future<String> _ensureSignedIn() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser != null) return auth.currentUser!.uid;
    final cred = await auth.signInAnonymously();
    return cred.user!.uid;
  }

  Future<void> _confirmTrip() async {
    if (pickup == null ||
        dropoff == null ||
        tripKm == null ||
        tripCost == null) {
      _toast("حدد البداية والنهاية أولاً");
      return;
    }

    try {
      final uid = await _ensureSignedIn();

      final ref = await FirebaseFirestore.instance
          .collection('trip_requests')
          .add({
            'routeId': widget.routeId,
            'passengerId': uid,
            'pickup': GeoPoint(pickup!.latitude, pickup!.longitude),
            'dropoff': GeoPoint(dropoff!.latitude, dropoff!.longitude),
            'distanceKm': tripKm,
            'cost': tripCost,
            'perKm': perKm,
            'baseFare': baseFare,
            'status': 'requested',
            'createdAt': FieldValue.serverTimestamp(),
          });

      if (!mounted) return;
      setState(() => lastRequestId = ref.id);

      _toast("تم تأكيد الرحلة ✅");
    } catch (e) {
      _toast("فشل تأكيد الرحلة: $e");
    }
  }

  // ------------------- UI HELPERS -------------------

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  // ------------------- BUILD -------------------

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

    // Info text
    String info = "اضغط لتحديد البداية ثم النهاية";
    if (pickup != null && dropoff == null) info = "حدد نقطة النهاية";
    if (pickup != null && dropoff != null) {
      info =
          "المسافة: ${tripKm?.toStringAsFixed(2) ?? '--'} كم • السعر: ${tripCost?.toStringAsFixed(0) ?? '--'}";
    }

    return Scaffold(
      appBar: AppBar(
        title: Text("المسار + السواقين (${driverPoints.length})"),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _useMyLocationAsPickup,
            tooltip: "استخدم موقعي كنقطة بداية",
          ),
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _fitBounds,
            tooltip: "إظهار كامل المسار",
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                pickup = null;
                dropoff = null;
                tripKm = null;
                tripCost = null;
                segmentPoints = [];
                lastRequestId = null;
              });
            },
            tooltip: "Reset",
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

              // ✅ المسار الكامل (لون خفيف)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: routePoints,
                    strokeWidth: 6,
                    color: Colors.blueGrey,
                  ),
                ],
              ),

              // ✅ Segment بين البداية والنهاية (لون واضح)
              if (segmentPoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: segmentPoints,
                      strokeWidth: 8,
                      color: Colors.green,
                    ),
                  ],
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

          // Info card (top)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.all(12),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text("perKm=$perKm • baseFare=$baseFare"),
                  if (lastRequestId != null) ...[
                    const SizedBox(height: 6),
                    Text("RequestId: $lastRequestId"),
                  ],
                ],
              ),
            ),
          ),

          // Confirm bar (bottom) - اختياري
          if (pickup != null && dropoff != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 18,
                      offset: Offset(0, 8),
                      color: Colors.black26,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "المسافة: ${tripKm?.toStringAsFixed(2) ?? '--'} كم\n"
                        "التكلفة: ${tripCost?.toStringAsFixed(0) ?? '--'}",
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      onPressed: _confirmTrip,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text("تأكيد"),
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
