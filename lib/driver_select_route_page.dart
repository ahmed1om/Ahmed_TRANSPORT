import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'driver_online_page.dart';

class DriverSelectRoutePage extends StatefulWidget {
  const DriverSelectRoutePage({super.key});

  @override
  State<DriverSelectRoutePage> createState() => _DriverSelectRoutePageState();
}

class _DriverSelectRoutePageState extends State<DriverSelectRoutePage> {
  String? _selectedRouteId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver - Choose Route')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('اختار المسار عشان تظهر للركاب على نفس الخط'),
            const SizedBox(height: 12),

            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('routes')
                  .where('active', isEqualTo: true)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator();
                }
                if (snap.hasError) {
                  return Text('Error: ${snap.error}');
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Text('ما في Routes محفوظة في Firestore');
                }

                return DropdownButtonFormField<String>(
                  value: _selectedRouteId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Route',
                  ),
                  items: docs.map((d) {
                    final data = d.data() as Map<String, dynamic>;
                    final name = (data['name'] ?? 'Route') as String;
                    final price = data['price'] ?? 0;
                    return DropdownMenuItem(
                      value: d.id,
                      child: Text('$name (السعر: $price)'),
                    );
                  }).toList(),
                  onChanged: (v) => setState(() => _selectedRouteId = v),
                );
              },
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _selectedRouteId == null
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                DriverOnlinePage(routeId: _selectedRouteId!),
                          ),
                        );
                      },
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
