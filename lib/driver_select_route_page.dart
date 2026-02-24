// لسائق يختار route من routes

// بعدين Continue → يمشي DriverOnlinePage
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
  String? _selectedRouteName; // ✅ جديد

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

                // ✅ لو routeId الحالي ما بقى موجود (مثلاً اتعطل)، صفّره
                final currentExists = _selectedRouteId == null
                    ? true
                    : docs.any((d) => d.id == _selectedRouteId);

                if (!currentExists) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    setState(() {
                      _selectedRouteId = null;
                      _selectedRouteName = null;
                    });
                  });
                }

                return DropdownButtonFormField<String>(
                  initialValue: currentExists ? _selectedRouteId : null,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Route',
                  ),
                  items: docs.map((d) {
                    final data = d.data() as Map<String, dynamic>;
                    final name = (data['name'] ?? 'Route') as String;

                    return DropdownMenuItem<String>(
                      value: d.id,
                      child: Text(name),
                      onTap: () {
                        // ✅ نحفظ الاسم لحظة اختيار العنصر
                        _selectedRouteName = name;
                      },
                    );
                  }).toList(),
                  onChanged: (v) {
                    setState(() {
                      _selectedRouteId = v;

                      // احتياط: لو ما انحفظ الاسم بسبب onTap في بعض الأجهزة
                      if (v != null) {
                        final pickedDoc =
                            docs.firstWhere((d) => d.id == v).data()
                                as Map<String, dynamic>;
                        _selectedRouteName =
                            (pickedDoc['name'] ?? 'Route') as String;
                      } else {
                        _selectedRouteName = null;
                      }
                    });
                  },
                );
              },
            ),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _selectedRouteId == null
                    ? null
                    : () {
                        debugPrint(
                          "GO -> DriverOnlinePage routeId=$_selectedRouteId",
                        );

                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DriverOnlinePage(
                              routeId: _selectedRouteId!,
                              routeName: _selectedRouteName,
                            ),
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
