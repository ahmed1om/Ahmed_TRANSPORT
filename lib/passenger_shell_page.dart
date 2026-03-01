import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'passenger_journey_page.dart';
import 'wallet_page.dart'; // ✅ ملف المحفظة عندك

class PassengerShellPage extends StatefulWidget {
  const PassengerShellPage({super.key});

  @override
  State<PassengerShellPage> createState() => _PassengerShellPageState();
}

class _PassengerShellPageState extends State<PassengerShellPage> {
  int _index = 0;

  final ValueNotifier<String?> selectedRouteId = ValueNotifier<String?>(null);

  late final Future<String> _uidFuture;

  @override
  void initState() {
    super.initState();
    _uidFuture = _ensureSignedIn();
  }

  Future<String> _ensureSignedIn() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser != null) return auth.currentUser!.uid;
    final cred = await auth.signInAnonymously();
    return cred.user!.uid;
  }

  @override
  void dispose() {
    selectedRouteId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _uidFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final uid = snap.data!;

        // ✅ لازم ترتيب الصفحات يطابق ترتيب الأزرار تحت
        final pages = <Widget>[
          PassengerJourneyPage(selectedRouteId: selectedRouteId), // 0 رحلتي
          const _StationsPage(), // 1 المحطات
          WalletPage(uid: uid), // 2 المحفظة ✅ (بدون const لأن فيها uid)
          const _RoutesPage(), // 3 المسارات
          const _MorePage(), // 4 المزيد
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
              NavigationDestination(
                icon: Icon(Icons.alt_route),
                label: 'المسارات',
              ),
              NavigationDestination(
                icon: Icon(Icons.more_horiz),
                label: 'المزيد',
              ),
            ],
          ),
        );
      },
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

class _RoutesPage extends StatelessWidget {
  const _RoutesPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('المسارات: حالياً اختيار المسار داخل صفحة رحلتي'),
      ),
    );
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('المزيد: الصفحة الشخصية/الإعدادات')),
    );
  }
}
