// RouteMapOsmPage (للراكب)

// تقرأ routes/{routeId} وتعرض polyline

// وتقرأ driver_locations وتعرض السيارات المرتبطة بنفس routeId.........

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class DriverOnlinePage extends StatefulWidget {
  final String routeId;
  final String? routeName;

  const DriverOnlinePage({super.key, required this.routeId, this.routeName});

  @override
  State<DriverOnlinePage> createState() => _DriverOnlinePageState();
}

class _DriverOnlinePageState extends State<DriverOnlinePage> {
  bool _isOnline = false;
  String _status = 'Offline';
  Timer? _timer;

  // ✅ هنا مكان initState الصحيح (داخل الـ State)
  @override
  void initState() {
    super.initState();
    debugPrint(
      "DriverOnlinePage opened routeId=${widget.routeId} routeName=${widget.routeName}",
    );
  }

  Future<User> _ensureSignedIn() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser != null) return auth.currentUser!;
    final cred = await auth.signInAnonymously();
    return cred.user!;
  }

  // ✅ صلحنا التحذير: كل if داخل {}
  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw 'شغّل الـ GPS (Location) من الجهاز';
    }

    LocationPermission perm = await Geolocator.checkPermission();

    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.denied) {
      throw 'رفضت صلاحية الموقع';
    }

    if (perm == LocationPermission.deniedForever) {
      throw 'الصلاحية مرفوضة نهائيًا. فعّلها من Settings';
    }
  }

  Future<void> _sendLocationOnce() async {
    final user = await _ensureSignedIn();
    await _ensureLocationPermission();

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 12),
      ),
    );

    // ✅ نخزن موقع السائق + المسار المختار
    await FirebaseFirestore.instance
        .collection('driver_locations')
        .doc(user.uid)
        .set({
          'driverId': user.uid,
          'routeId': widget.routeId, // ✅ مهم
          'routeName': widget.routeName, // اختياري
          'lat': pos.latitude,
          'lng': pos.longitude,
          'isOnline': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    setState(() {
      _status =
          'Online on ${widget.routeName ?? widget.routeId}\n'
          '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
    });
  }

  Future<void> _goOnline() async {
    setState(() {
      _isOnline = true;
      _status = 'Going Online...';
    });

    try {
      await _sendLocationOnce().timeout(const Duration(seconds: 15));

      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 8), (_) async {
        try {
          await _sendLocationOnce().timeout(const Duration(seconds: 15));
        } catch (e) {
          if (!mounted) return;
          setState(() => _status = 'Location update failed: $e');
        }
      });
    } catch (e) {
      _timer?.cancel();
      if (!mounted) return;
      setState(() {
        _isOnline = false;
        _status = 'Failed to go online: $e';
      });
    }
  }

  Future<void> _goOffline() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance
          .collection('driver_locations')
          .doc(user.uid)
          .set({
            'isOnline': false,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    }

    _timer?.cancel();
    setState(() {
      _isOnline = false;
      _status = 'Offline';
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Driver • ${widget.routeName ?? "Route"}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isOnline ? null : _goOnline,
                    child: const Text('Go Online'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isOnline ? _goOffline : null,
                    child: const Text('Go Offline'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
