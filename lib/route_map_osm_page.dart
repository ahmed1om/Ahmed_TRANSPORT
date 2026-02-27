// هذا الملف هو لصفحة الراكب بيعرض الخرطة والمسار
//  الفرق بينو انو بيعتمد النقطة بتاعت بداية الرحلة حقت الراكب
//  GPS بالـ
//  بناء على موقعه الحالي، وبيحدد نقطة البداية دي
//   تلقائياً، وبيحسب المسافة والتكلفة بناءً على المسار المخزن في Firestore. كمان بيعرض السواقين المتصلين على نفس المسار.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
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

  final String routesCollection = "routes";
  final String driversCollection = "driver_locations";

  // Route
  List<LatLng> routePoints = [];
  List<LatLng> segmentPoints = []; // ✅ الجزء المحدد من المسار
  LatLng? routeStart;
  LatLng? routeEnd;

  bool loading = true;
  String? error;

  // Drivers on same route
  List<LatLng> driverPoints = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _driversSub;

  // Pricing (global)
  double perKm = 0;
  double baseFare = 0;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _pricingSub;

  // Passenger selection
  LatLng? pickup; // start
  LatLng? dropoff; // end
  bool pickingPickup = false; // لو true: الضغطة الجاية تعيّن pickup
  double? tripKm;
  double? tripCost;

  // GPS status message
  String? gpsStatus;

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

  // ---------------- Load Route ----------------
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

      final data = snap.data() as Map<String, dynamic>;
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
        routeStart = s;
        routeEnd = e;
        loading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitBounds(routePoints);
      });

      _listenDrivers();
      _listenPricing();

      // ✅ pickup تلقائي من GPS
      await _setPickupFromGPS();
    } catch (e) {
      setState(() {
        error = "فشل تحميل المسار: $e";
        loading = false;
      });
    }
  }

  // ---------------- Pricing ----------------
  void _listenPricing() {
    _pricingSub?.cancel();

    final ref = FirebaseFirestore.instance
        .collection('settings')
        .doc('pricing');

    _pricingSub = ref.snapshots().listen((doc) {
      final data = doc.data() ?? <String, dynamic>{};
      final newPerKm = (data['perKm'] as num?)?.toDouble() ?? 0;
      final newBase = (data['baseFare'] as num?)?.toDouble() ?? 0;

      if (!mounted) return;
      setState(() {
        perKm = newPerKm;
        baseFare = newBase;
      });

      _recalcFare();
    });
  }

  // ---------------- Drivers ----------------
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
        final data = doc.data();
        final lat = data['lat'];
        final lng = data['lng'];
        if (lat == null || lng == null) continue;

        pts.add(LatLng((lat as num).toDouble(), (lng as num).toDouble()));
      }

      if (!mounted) return;
      setState(() => driverPoints = pts);
    });
  }

  // ---------------- GPS Pickup ----------------
  Future<void> _setPickupFromGPS() async {
    try {
      if (!mounted) return;
      setState(() => gpsStatus = "جارٍ تحديد موقعك...");

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() => gpsStatus = "شغّل GPS (Location) من الجهاز");
        return;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }

      if (perm == LocationPermission.denied) {
        if (!mounted) return;
        setState(() => gpsStatus = "تم رفض صلاحية الموقع");
        return;
      }

      if (perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(
          () => gpsStatus = "فعّل الصلاحية من Settings (Denied Forever)",
        );
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );

      if (!mounted) return;
      setState(() {
        pickup = LatLng(pos.latitude, pos.longitude);
        gpsStatus = null;
        // ما نمسح dropoff تلقائياً هنا (إلا لو داير)
        segmentPoints = [];
        tripKm = null;
        tripCost = null;
      });

      // لو في dropoff موجودة، أعد الحساب
      _recalcFare();

      // زوم خفيف على موقع الراكب
      mapController.move(pickup!, 16);
    } catch (e) {
      if (!mounted) return;
      setState(() => gpsStatus = "فشل تحديد الموقع: $e");
    }
  }

  // ---------------- Route Distance + Segment ----------------
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
      final t = from;
      from = to;
      to = t;
    }

    double meters = 0;
    for (int i = from; i < to; i++) {
      meters += _dist.as(LengthUnit.Meter, routePoints[i], routePoints[i + 1]);
    }
    return meters / 1000.0;
  }

  void _buildSegmentAndZoom() {
    if (pickup == null || dropoff == null) return;
    if (routePoints.length < 2) return;

    int a = _nearestIndex(pickup!);
    int b = _nearestIndex(dropoff!);

    int from = a, to = b;
    if (from > to) {
      final t = from;
      from = to;
      to = t;
    }

    final seg = routePoints.sublist(from, to + 1);

    setState(() => segmentPoints = seg);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitBounds(seg, padding: 60);
    });
  }

  void _recalcFare() {
    if (pickup == null || dropoff == null) return;

    final km = _distanceOnRouteKm(pickup!, dropoff!);
    final cost = baseFare + (km * perKm);

    if (!mounted) return;
    setState(() {
      tripKm = km;
      tripCost = cost;
    });

    _buildSegmentAndZoom();
  }

  // ---------------- Map Tap Logic ----------------
  void _onMapTap(LatLng p) {
    // لو المستخدم اختار تغيير البداية
    if (pickingPickup) {
      setState(() {
        pickup = p;
        pickingPickup = false;
        // نعيد حساب/Segment لو في dropoff
        segmentPoints = [];
        tripKm = null;
        tripCost = null;
      });
      _recalcFare();
      return;
    }

    // لو pickup ما اتحدد (مثلاً GPS فشل)
    if (pickup == null) {
      setState(() {
        pickup = p;
        dropoff = null;
        segmentPoints = [];
        tripKm = null;
        tripCost = null;
      });
      return;
    }

    // أول تحديد للنهاية
    if (dropoff == null) {
      setState(() => dropoff = p);
      _recalcFare();
      return;
    }

    // تغيير النهاية (بدون reset كامل)
    setState(() {
      dropoff = p;
      segmentPoints = [];
      tripKm = null;
      tripCost = null;
    });
    _recalcFare();
  }

  // ---------------- Fit Bounds ----------------
  void _fitBounds(List<LatLng> pts, {double padding = 40}) {
    if (pts.isEmpty) return;

    double minLat = pts.first.latitude;
    double maxLat = pts.first.latitude;
    double minLng = pts.first.longitude;
    double maxLng = pts.first.longitude;

    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
    mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: EdgeInsets.all(padding)),
    );
  }

  void _resetAll() {
    setState(() {
      dropoff = null;
      tripKm = null;
      tripCost = null;
      segmentPoints = [];
      pickingPickup = false;
    });
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

    final center = routeStart ?? routePoints.first;

    String info = "حدد نقطة النهاية من الخريطة";
    if (pickup == null) info = "حدد البداية أو اضغط (موقعي)";
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
            onPressed: () => _fitBounds(routePoints),
            tooltip: "Fit full route",
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in_map),
            onPressed: segmentPoints.length >= 2
                ? () => _fitBounds(segmentPoints, padding: 60)
                : null,
            tooltip: "Fit selected segment",
          ),
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _setPickupFromGPS,
            tooltip: "موقعي كبداية",
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetAll,
            tooltip: "Reset end",
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

              // ✅ المسار كامل + segment (مختلف اللون)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: routePoints,
                    strokeWidth: 5,
                    color: Colors.blue,
                  ),
                  if (segmentPoints.length >= 2)
                    Polyline(
                      points: segmentPoints,
                      strokeWidth: 9,
                      color: Colors.red,
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
                  if (routeStart != null)
                    Marker(
                      point: routeStart!,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.play_arrow, size: 36),
                    ),
                  if (routeEnd != null)
                    Marker(
                      point: routeEnd!,
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
                color: Colors.white.withOpacity(0.92),
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
                  if (gpsStatus != null) ...[
                    const SizedBox(height: 6),
                    Text(gpsStatus!, style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),

      // زر تغيير البداية (يدوي) + زر موقعي
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(
                  pickingPickup ? Icons.check : Icons.edit_location_alt,
                ),
                label: Text(
                  pickingPickup ? "اضغط بالخريطة للبداية" : "تغيير البداية",
                ),
                onPressed: () {
                  setState(() => pickingPickup = !pickingPickup);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.my_location),
                label: const Text("موقعي"),
                onPressed: _setPickupFromGPS,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
