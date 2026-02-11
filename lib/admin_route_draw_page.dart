import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminRouteDrawPage extends StatefulWidget {
  const AdminRouteDrawPage({super.key});

  @override
  State<AdminRouteDrawPage> createState() => _AdminRouteDrawPageState();
}

class _AdminRouteDrawPageState extends State<AdminRouteDrawPage> {
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController(text: "0");

  final List<LatLng> _points = [];
  bool _saving = false;
  String _status = '';

  void _addPoint(TapPosition tapPos, LatLng latlng) {
    setState(() {
      _points.add(latlng);
      _status = 'Points: ${_points.length}';
    });
  }

  void _undo() {
    if (_points.isEmpty) return;
    setState(() {
      _points.removeLast();
      _status = 'Points: ${_points.length}';
    });
  }

  void _clear() {
    setState(() {
      _points.clear();
      _status = 'Cleared';
    });
  }

  Future<void> _saveRoute() async {
    final name = _nameCtrl.text.trim();
    final priceText = _priceCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _status = 'اكتب اسم المسار');
      return;
    }
    if (_points.length < 2) {
      setState(() => _status = 'لازم نقطتين على الأقل');
      return;
    }

    final price = int.tryParse(priceText) ?? 0;

    setState(() {
      _saving = true;
      _status = 'Saving...';
    });

    try {
      final geoPoints = _points
          .map((p) => GeoPoint(p.latitude, p.longitude))
          .toList();

      await FirebaseFirestore.instance.collection('routes').add({
        'name': name,
        'price': price,
        'active': true,
        'points': geoPoints,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _saving = false;
        _status = 'Saved ✅';
        _points.clear();
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _status = 'Save failed: $e';
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin - Draw Route')),
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
                TextField(
                  controller: _priceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'السعر',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : _saveRoute,
                        child: const Text('Save Route'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(onPressed: _undo, child: const Text('Undo')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _clear,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(_status, textAlign: TextAlign.center),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              options: MapOptions(
                initialCenter: const LatLng(15.5000, 32.5600),
                initialZoom: 14,
                onTap: _addPoint,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.project1',
                ),
                PolylineLayer(
                  polylines: [Polyline(points: _points, strokeWidth: 5)],
                ),
                MarkerLayer(
                  markers: _points
                      .map(
                        (p) => Marker(
                          point: p,
                          width: 30,
                          height: 30,
                          child: const Icon(Icons.circle, size: 18),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
