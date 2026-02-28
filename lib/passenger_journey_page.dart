import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class PassengerJourneyPage extends StatefulWidget {
  final ValueNotifier<String?> selectedRouteId;
  const PassengerJourneyPage({super.key, required this.selectedRouteId});

  @override
  State<PassengerJourneyPage> createState() => _PassengerJourneyPageState();
}

class _PassengerJourneyPageState extends State<PassengerJourneyPage> {
  final MapController mapController = MapController();
  final Distance _dist = const Distance();

  // Route
  String? routeId;
  String routeName = '';
  List<LatLng> routePoints = [];
  List<LatLng> segmentPoints = [];
  LatLng? routeStart;
  LatLng? routeEnd;

  bool loadingRoute = false;
  String? routeError;

  // Drivers
  List<LatLng> driverPoints = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _driversSub;

  // Pricing
  double perKm = 0;
  double baseFare = 0;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _pricingSub;

  // Passenger selection
  LatLng? pickup;
  LatLng? dropoff;
  bool pickingPickup = false;
  double? tripKm;
  double? tripCost;

  // Trip state
  String? activeTripId;
  String tripStatusText = 'لم يتم تأكيد رحلة بعد';
  Timer? _passengerTimer;
  bool broadcasting = false;

  @override
  void initState() {
    super.initState();
    widget.selectedRouteId.addListener(_onRouteChanged);
    _listenPricing();

    final id = widget.selectedRouteId.value;
    if (id != null) _loadRoute(id);
  }

  @override
  void dispose() {
    widget.selectedRouteId.removeListener(_onRouteChanged);
    _driversSub?.cancel();
    _pricingSub?.cancel();
    _stopPassengerBroadcast();
    super.dispose();
  }

  void _onRouteChanged() {
    final id = widget.selectedRouteId.value;
    if (id == null) return;
    _loadRoute(id);
  }

  // ---------------- Pricing ----------------
  void _listenPricing() {
    _pricingSub?.cancel();
    _pricingSub = FirebaseFirestore.instance
        .collection('settings')
        .doc('pricing')
        .snapshots()
        .listen((doc) {
          final data = doc.data() ?? {};
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

  // ---------------- Load Route ----------------
  Future<void> _loadRoute(String id) async {
    // نلغي أي بث/رحلة قديمة عند تغيير المسار
    await _stopPassengerBroadcast();
    activeTripId = null;
    tripStatusText = 'لم يتم تأكيد رحلة بعد';

    setState(() {
      routeId = id;
      loadingRoute = true;
      routeError = null;

      routeName = '';
      routePoints = [];
      segmentPoints = [];
      routeStart = null;
      routeEnd = null;

      driverPoints = [];
      pickup = null;
      dropoff = null;
      tripKm = null;
      tripCost = null;
      pickingPickup = false;
    });

    try {
      final snap = await FirebaseFirestore.instance
          .collection('routes')
          .doc(id)
          .get();
      if (!snap.exists) {
        setState(() {
          routeError = "المسار غير موجود";
          loadingRoute = false;
        });
        return;
      }

      final data = snap.data() ?? {};
      routeName = (data['name'] ?? 'Route') as String;

      final points = (data['points'] ?? []) as List;
      final pts = points.map((p) {
        final gp = p as GeoPoint;
        return LatLng(gp.latitude, gp.longitude);
      }).toList();

      if (pts.isEmpty) {
        setState(() {
          routeError = "مافي نقاط في المسار";
          loadingRoute = false;
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
        loadingRoute = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitBounds(routePoints, padding: 60);
      });

      _listenDriversForRoute(id);
    } catch (e) {
      setState(() {
        routeError = "فشل تحميل المسار: $e";
        loadingRoute = false;
      });
    }
  }

  // ---------------- Drivers ----------------
  void _listenDriversForRoute(String id) {
    _driversSub?.cancel();
    _driversSub = FirebaseFirestore.instance
        .collection('driver_locations')
        .where('isOnline', isEqualTo: true)
        .where('routeId', isEqualTo: id)
        .snapshots()
        .listen((snap) {
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

  // ---------------- Geometry ----------------
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

  LatLng _snapToRoute(LatLng p) => routePoints[_nearestIndex(p)];

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
      _fitBounds(seg, padding: 80);
    });
  }

  void _recalcFare() {
    if (pickup == null || dropoff == null) return;

    final km = _distanceOnRouteKm(pickup!, dropoff!);
    final cost = baseFare + (km * perKm);

    setState(() {
      tripKm = km;
      tripCost = cost;
    });

    _buildSegmentAndZoom();
  }

  void _fitBounds(List<LatLng> pts, {double padding = 40}) {
    if (pts.isEmpty) return;

    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;

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

  // ---------------- Map Tap ----------------
  void _onMapTap(LatLng p) {
    if (routeId == null || routePoints.isEmpty) {
      _snack("اختر مسار أولاً");
      return;
    }

    final snapped = _snapToRoute(p);

    if (pickingPickup) {
      setState(() {
        pickup = snapped;
        pickingPickup = false;
        segmentPoints = [];
        tripKm = null;
        tripCost = null;
      });
      _recalcFare();
      return;
    }

    if (pickup == null) {
      setState(() {
        pickup = snapped;
        dropoff = null;
        segmentPoints = [];
        tripKm = null;
        tripCost = null;
      });
      return;
    }

    if (dropoff == null) {
      setState(() => dropoff = snapped);
      _recalcFare();
      return;
    }

    // تغيير النهاية بسرعة
    setState(() {
      dropoff = snapped;
      segmentPoints = [];
      tripKm = null;
      tripCost = null;
    });
    _recalcFare();
  }

  // ---------------- Auth ----------------
  Future<String> _ensureSignedIn() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser != null) return auth.currentUser!.uid;
    final cred = await auth.signInAnonymously();
    return cred.user!.uid;
  }

  // ---------------- Passenger Broadcast ----------------
  Future<LatLng?> _getCurrentLatLng() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return null;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 12),
      ),
    );
    return LatLng(pos.latitude, pos.longitude);
  }

  void _startPassengerBroadcast({required String uid, required String tripId}) {
    _stopPassengerBroadcast();

    broadcasting = true;

    Future<void> pushOnce() async {
      final p = await _getCurrentLatLng();
      if (p == null) return;

      await FirebaseFirestore.instance
          .collection('passenger_locations')
          .doc(uid)
          .set({
            'passengerId': uid,
            'tripId': tripId,
            'routeId': routeId,
            'lat': p.latitude,
            'lng': p.longitude,
            'isActive': true,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    }

    pushOnce();
    _passengerTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => pushOnce(),
    );
  }

  Future<void> _stopPassengerBroadcast() async {
    _passengerTimer?.cancel();
    _passengerTimer = null;

    if (!broadcasting) return;
    broadcasting = false;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    await FirebaseFirestore.instance
        .collection('passenger_locations')
        .doc(uid)
        .set({
          'isActive': false,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  // ---------------- Confirm / Cancel Trip ----------------
  Future<void> _confirmTrip() async {
    if (routeId == null) {
      _snack("اختر مسار أولاً");
      return;
    }
    if (pickup == null ||
        dropoff == null ||
        tripKm == null ||
        tripCost == null) {
      _snack("حدد البداية والنهاية أولاً");
      return;
    }

    final uid = await _ensureSignedIn();

    final ref = await FirebaseFirestore.instance
        .collection('trip_requests')
        .add({
          'routeId': routeId,
          'routeName': routeName,
          'passengerId': uid,
          'pickup': GeoPoint(pickup!.latitude, pickup!.longitude),
          'dropoff': GeoPoint(dropoff!.latitude, dropoff!.longitude),
          'distanceKm': tripKm,
          'cost': tripCost,
          'perKm': perKm,
          'baseFare': baseFare,
          'status': 'waiting_driver',
          'createdAt': FieldValue.serverTimestamp(),
        });

    if (!mounted) return;
    setState(() {
      activeTripId = ref.id;
      tripStatusText = 'في انتظار السائق ليصلك';
    });

    _startPassengerBroadcast(uid: uid, tripId: ref.id);

    _snack("تم تأكيد الرحلة ✅");
  }

  Future<void> _cancelTrip() async {
    final id = activeTripId;
    if (id == null) return;

    await FirebaseFirestore.instance.collection('trip_requests').doc(id).set({
      'status': 'canceled',
      'canceledAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _stopPassengerBroadcast();

    if (!mounted) return;
    setState(() {
      activeTripId = null;
      tripStatusText = 'تم إلغاء الرحلة';
    });

    _snack("تم الإلغاء");
  }

  Future<void> _useMyLocationAsPickup() async {
    if (routeId == null || routePoints.isEmpty) {
      _snack("اختر مسار أولاً");
      return;
    }

    final p = await _getCurrentLatLng();
    if (p == null) {
      _snack("تعذر تحديد موقعك (GPS/Permissions)");
      return;
    }

    final snapped = _snapToRoute(p);

    setState(() {
      pickup = snapped;
      dropoff = null;
      segmentPoints = [];
      tripKm = null;
      tripCost = null;
      pickingPickup = false;
    });

    mapController.move(snapped, 16);
    _snack("تم تحديد البداية من موقعك (على المسار)");
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final canConfirm =
        routeId != null &&
        pickup != null &&
        dropoff != null &&
        tripCost != null &&
        activeTripId == null;

    return Scaffold(
      body: Stack(
        children: [
          // MAP
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: const LatLng(15.5000, 32.5600),
              initialZoom: 13,
              onTap: (tapPos, latLng) => _onMapTap(latLng),
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName: "com.example.project1",
              ),

              if (routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5,
                      color: Colors.blueGrey,
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
                  // drivers
                  ...driverPoints.map(
                    (p) => Marker(
                      point: p,
                      width: 38,
                      height: 38,
                      child: const Icon(Icons.directions_car, size: 34),
                    ),
                  ),

                  // route start/end
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

                  // passenger
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

          // Bottom Sheet
          DraggableScrollableSheet(
            minChildSize: 0.16,
            initialChildSize: 0.22,
            maxChildSize: 0.75,
            builder: (context, scrollController) {
              return Material(
                elevation: 12,
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: theme.dividerColor.withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            routeId == null ? "اختر مساراً" : "رحلتي",
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        if (routeId != null)
                          TextButton(
                            onPressed: () {
                              setState(() {
                                widget.selectedRouteId.value = null;
                                routeId = null;
                                routeName = '';
                                routePoints = [];
                                segmentPoints = [];
                                pickup = null;
                                dropoff = null;
                                tripKm = null;
                                tripCost = null;
                                driverPoints = [];
                                activeTripId = null;
                                tripStatusText = 'لم يتم تأكيد رحلة بعد';
                                pickingPickup = false;
                              });
                            },
                            child: const Text("تغيير"),
                          ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    if (loadingRoute) ...[
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 16),
                    ],
                    if (routeError != null) ...[
                      Text(
                        routeError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ✅ اختيار مسار داخل نفس الصفحة (بدون انتقال)
                    if (routeId == null) ...[
                      const Text(
                        "المسارات المتاحة",
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      _RoutesInlineList(
                        onPickRoute: (id) => widget.selectedRouteId.value = id,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        "بعد اختيار المسار: اضغط على الخريطة لتحديد البداية/النهاية.",
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 80),
                    ] else ...[
                      // Route selected summary
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: .6),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              routeName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "العربات على نفس المسار: ${driverPoints.length}",
                            ),
                            const SizedBox(height: 6),
                            Text("perKm=$perKm • baseFare=$baseFare"),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Trip status (بديل زر المحفظة داخل الشيت)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.dividerColor.withValues(alpha: .5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                activeTripId == null
                                    ? (pickup == null
                                          ? "حدد البداية من الخريطة أو من موقعك"
                                          : (dropoff == null
                                                ? "حدد نقطة النهاية"
                                                : "جاهز للتأكيد"))
                                    : tripStatusText,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (activeTripId != null) ...[
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _cancelTrip,
                                child: const Text("إلغاء"),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Actions
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: activeTripId != null
                                  ? null
                                  : () => setState(
                                      () => pickingPickup = !pickingPickup,
                                    ),
                              icon: Icon(
                                pickingPickup
                                    ? Icons.check
                                    : Icons.edit_location_alt,
                              ),
                              label: Text(
                                pickingPickup
                                    ? "اضغط للخريطة"
                                    : "تغيير البداية",
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: activeTripId != null
                                  ? null
                                  : _useMyLocationAsPickup,
                              icon: const Icon(Icons.my_location),
                              label: const Text("موقعي"),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Cost + confirm
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.dividerColor.withValues(alpha: .5),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "المسافة: ${tripKm?.toStringAsFixed(2) ?? '--'} كم",
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "التكلفة: ${tripCost?.toStringAsFixed(0) ?? '--'}",
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: canConfirm ? _confirmTrip : null,
                                child: const Text("تأكيد الرحلة"),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),
                      Text(
                        "الإلغاء يوقف بث موقعك قبل منطق تأكيد الركوب.",
                        style: TextStyle(color: theme.hintColor),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// ✅ قائمة المسارات داخل BottomSheet (بدون Navigation)
class _RoutesInlineList extends StatelessWidget {
  final void Function(String routeId) onPickRoute;
  const _RoutesInlineList({required this.onPickRoute});

  @override
  Widget build(BuildContext context) {
    // ⚠️ يحتاج Composite Index: routes(active ASC, createdAt DESC)
    final q = FirebaseFirestore.instance
        .collection('routes')
        .where('active', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .limit(10);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: q.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text("Index required / Error: ${snap.error}");
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Text("لا توجد مسارات فعّالة الآن.");

        return Column(
          children: docs.map((doc) {
            final data = doc.data();
            final name = (data['name'] ?? 'Route') as String;
            final pointsCount = (data['points'] as List?)?.length ?? 0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onPickRoute(doc.id),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: .45),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.directions_bus_filled),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text("نقاط: $pointsCount"),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
