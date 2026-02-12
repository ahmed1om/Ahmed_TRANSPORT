import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'route_map_osm_page.dart';

class RoutesListPage extends StatelessWidget {
  const RoutesListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final routesRef = FirebaseFirestore.instance.collection('routes');

    return Scaffold(
      appBar: AppBar(title: const Text('Routes')),
      body: StreamBuilder<QuerySnapshot>(
        stream: routesRef.orderBy('createdAt', descending: true).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('No routes yet'));
          }

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;

              final name = (data['name'] ?? 'Route') as String;
              final price = data['price'] ?? 0;
              final active = data['active'] == true;

              return ListTile(
                title: Text(name),
                subtitle: Text('Price: $price • Active: $active'),
                trailing: const Icon(Icons.map),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RouteMapOsmPage(routeId: doc.id),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
