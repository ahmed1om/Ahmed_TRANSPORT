import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'passenger_journey_page.dart';

class PassengerShellPage extends StatefulWidget {
  const PassengerShellPage({super.key});

  @override
  State<PassengerShellPage> createState() => _PassengerShellPageState();
}

class _PassengerShellPageState extends State<PassengerShellPage> {
  int _index = 0;

  // ✅ مشاركة المسار المختار بين التابات بدون Navigator
  final ValueNotifier<String?> selectedRouteId = ValueNotifier<String?>(null);

  @override
  void dispose() {
    selectedRouteId.dispose();
    super.dispose();
  }

  void _goToJourneyWithRoute(String routeId) {
    selectedRouteId.value = routeId;
    setState(() => _index = 0); // يرجع لرحلتي
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      PassengerJourneyPage(selectedRouteId: selectedRouteId),
      const _StationsPage(),
      const _WalletPage(),
      _RoutesTab(onPickRoute: _goToJourneyWithRoute),
      const _MorePage(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.directions_transit),
            label: 'رحلتي',
          ),
          NavigationDestination(
            icon: Icon(Icons.location_on_outlined),
            label: 'المحطات',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: 'محفظة',
          ),
          NavigationDestination(icon: Icon(Icons.alt_route), label: 'المسارات'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'المزيد'),
        ],
      ),
    );
  }
}

class _RoutesTab extends StatelessWidget {
  final void Function(String routeId) onPickRoute;
  const _RoutesTab({required this.onPickRoute});

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('routes')
        .where('active', isEqualTo: true)
        .orderBy('createdAt', descending: true);

    return Scaffold(
      appBar: AppBar(title: const Text('المسارات')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('لا توجد مسارات فعّالة'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data();
              final name = (data['name'] ?? 'Route') as String;
              final price = data['price'] ?? 0;

              return InkWell(
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
                            Text('Price (قديم): $price'),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StationsPage extends StatelessWidget {
  const _StationsPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('المحطات: بنجهزها بعدين')));
  }
}

class _WalletPage extends StatelessWidget {
  const _WalletPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('محفظة افتراضية (لاحقاً نضيف transactions)')),
    );
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('المزيد: الصفحة الشخصية/البيانات')),
    );
  }
}
