import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';

import 'admin_pricing_page.dart'; // ✅ صفحة التسعير (perKm/baseFare)

class AdminRouteSmartPage extends StatefulWidget {
  const AdminRouteSmartPage({super.key});

  @override
  State<AdminRouteSmartPage> createState() => _AdminRouteSmartPageState();
}

class _AdminRouteSmartPageState extends State<AdminRouteSmartPage> {
  final _nameCtrl = TextEditingController();

  LatLng? _start;
  LatLng? _end;

  bool _loadingRoute = false;
  bool _saving = false;
  String _status = '';

  List<LatLng> _routePoints = [];

  void _onMapTap(TapPosition tapPos, LatLng latlng) {
    setState(() {
      if (_start == null) {
        _start = latlng;
        _status = 'Start set ✅ (اضغط مرة ثانية لتحديد End)';
      } else if (_end == null) {
        _end = latlng;
        _status = 'End set ✅ (اضغط Generate Route)';
      } else {
        // إذا ضغط مرة ثالثة: نبدأ من جديد
        _start = latlng;
        _end = null;
        _routePoints.clear();
        _status = 'Start reset ✅ (حدد End من جديد)';
      }
    });
  }

  Future<void> _generateRoute() async {
    if (_start == null || _end == null) {
      setState(() => _status = 'حدد Start و End أولاً');
      return;
    }

    setState(() {
      _loadingRoute = true;
      _status = 'Generating route...';
      _routePoints.clear();
    });

    try {
      // OSRM expects lon,lat
      final sLon = _start!.longitude;
      final sLat = _start!.latitude;
      final eLon = _end!.longitude;
      final eLat = _end!.latitude;

      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$sLon,$sLat;$eLon,$eLat'
        '?overview=full&geometries=geojson&alternatives=false&steps=false',
      );

      final res = await http.get(url).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw 'OSRM HTTP ${res.statusCode}';
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>?;

      if (routes == null || routes.isEmpty) {
        throw 'No routes returned';
      }

      final geometry = routes[0]['geometry'] as Map<String, dynamic>;
      final coords = geometry['coordinates'] as List<dynamic>;

      // coordinates = [[lon,lat],[lon,lat],...]
      final pts = coords.map((c) {
        final lon = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        return LatLng(lat, lon);
      }).toList();

      setState(() {
        _routePoints = pts;
        _status = 'Route ready ✅ نقاط: ${_routePoints.length}';
      });
    } catch (e) {
      setState(() => _status = 'Generate failed: $e');
    } finally {
      setState(() => _loadingRoute = false);
    }
  }

  Future<void> _saveRoute() async {
    final name = _nameCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _status = 'اكتب اسم المسار');
      return;
    }
    if (_start == null || _end == null) {
      setState(() => _status = 'حدد Start و End أولاً');
      return;
    }
    if (_routePoints.length < 2) {
      setState(() => _status = 'اعمل Generate Route أولاً');
      return;
    }

    setState(() {
      _saving = true;
      _status = 'Saving...';
    });

    try {
      final geoPoints = _routePoints
          .map((p) => GeoPoint(p.latitude, p.longitude))
          .toList();

      await FirebaseFirestore.instance.collection('routes').add({
        'name': name,
        'active': true,
        'mode': 'driving',
        'start': GeoPoint(_start!.latitude, _start!.longitude),
        'end': GeoPoint(_end!.latitude, _end!.longitude),
        'points': geoPoints,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _saving = false;
        _status = 'Saved ✅';
        _start = null;
        _end = null;
        _routePoints.clear();
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _status = 'Save failed: $e';
      });
    }
  }

  void _clearAll() {
    setState(() {
      _start = null;
      _end = null;
      _routePoints.clear();
      _status = 'Cleared';
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[];

    if (_start != null) {
      markers.add(
        Marker(
          point: _start!,
          width: 40,
          height: 40,
          child: const Icon(Icons.play_arrow, size: 34),
        ),
      );
    }
    if (_end != null) {
      markers.add(
        Marker(
          point: _end!,
          width: 40,
          height: 40,
          child: const Icon(Icons.flag, size: 34),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin - Smart Route (OSRM)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.attach_money),
            tooltip: 'Pricing (perKm/baseFare)',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminPricingPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'اسم المسار',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),

                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _loadingRoute ? null : _generateRoute,
                        child: const Text('Generate Route'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : _saveRoute,
                        child: const Text('Save Route'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _clearAll,
                        child: const Text('Clear'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text(
                  _start == null
                      ? 'اضغط على الخريطة لتحديد Start'
                      : (_end == null
                            ? 'اضغط لتحديد End'
                            : 'اضغط Generate Route'),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: const LatLng(15.5000, 32.5600),
                initialZoom: 13,
                onTap: _onMapTap,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.project1',
                ),
                if (_routePoints.isNotEmpty)
                  PolylineLayer(
                    polylines: [Polyline(points: _routePoints, strokeWidth: 5)],
                  ),
                MarkerLayer(markers: markers),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
