import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class OsmPage extends StatelessWidget {
  const OsmPage({super.key});

  @override
  Widget build(BuildContext context) {
    const khartoum = LatLng(15.5007, 32.5599);
    return Scaffold(
      appBar: AppBar(title: const Text('OpenStreetMap')),
      body: FlutterMap(
        options: const MapOptions(
          initialCenter: khartoum,
          initialZoom: 13,
        ),
        children:[
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.project1',
          ),
        ],
      ),
    );
  }
}
