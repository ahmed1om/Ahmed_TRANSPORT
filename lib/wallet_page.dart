import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'wallet_service.dart';

class WalletPage extends StatelessWidget {
  final String uid;
  const WalletPage({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    final txnsQuery = FirebaseFirestore.instance
        .collection('wallets')
        .doc(uid)
        .collection('txns')
        .orderBy('createdAt', descending: true)
        .limit(20);

    return Scaffold(
      appBar: AppBar(title: const Text('المحفظة')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            StreamBuilder<double>(
              stream: WalletService.watchBalance(uid),
              builder: (context, snap) {
                final balance = snap.data ?? 0.0;
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: .5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'رصيدك',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        balance.toStringAsFixed(0),
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () => WalletService.topUp(
                                uid,
                                100,
                                note: 'test topup',
                              ),
                              child: const Text('شحن تجريبي +100'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerRight,
              child: Text(
                'آخر العمليات',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: txnsQuery.snapshots(),
                builder: (context, snap) {
                  if (!snap.hasData)
                    return const Center(child: CircularProgressIndicator());
                  final docs = snap.data!.docs;
                  if (docs.isEmpty)
                    return const Center(child: Text('لا توجد عمليات'));
                  return ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final d = docs[i].data();
                      return ListTile(
                        leading: Icon(
                          d['type'] == 'debit' ? Icons.remove : Icons.add,
                        ),
                        title: Text('${d['type']} • ${d['amount']}'),
                        subtitle: Text('tripId: ${d['tripId'] ?? '-'}'),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
