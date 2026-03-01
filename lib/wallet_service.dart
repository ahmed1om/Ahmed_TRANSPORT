import 'package:cloud_firestore/cloud_firestore.dart';

class WalletService {
  static final _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> walletRef(String uid) =>
      _db.collection('wallets').doc(uid);

  static CollectionReference<Map<String, dynamic>> txnsRef(String uid) =>
      _db.collection('wallets').doc(uid).collection('txns');

  static Future<void> ensureWallet(String uid) async {
    final ref = walletRef(uid);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        'balance': 0.0,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  static Stream<double> watchBalance(String uid) {
    return walletRef(uid).snapshots().map((doc) {
      final data = doc.data() ?? {};
      final b = (data['balance'] as num?)?.toDouble() ?? 0.0;
      return b;
    });
  }

  /// شحن تجريبي (اختياري)
  static Future<void> topUp(String uid, double amount, {String? note}) async {
    await ensureWallet(uid);

    await _db.runTransaction((tx) async {
      final wRef = walletRef(uid);
      final wSnap = await tx.get(wRef);
      final data = wSnap.data() ?? {};
      final current = (data['balance'] as num?)?.toDouble() ?? 0.0;

      final newBalance = current + amount;

      tx.set(wRef, {
        'balance': newBalance,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      tx.set(txnsRef(uid).doc(), {
        'type': 'topup',
        'amount': amount,
        'tripId': null,
        'note': note ?? 'topup',
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// دفع رحلة بالمحفظة + تحديث الرحلة في نفس Transaction
  static Future<void> payTripWithWallet({
    required String uid,
    required String tripId,
    required double amount,
  }) async {
    await ensureWallet(uid);

    await _db.runTransaction((tx) async {
      final wRef = walletRef(uid);
      final tRef = _db.collection('trip_requests').doc(tripId);

      final wSnap = await tx.get(wRef);
      final wData = wSnap.data() ?? {};
      final balance = (wData['balance'] as num?)?.toDouble() ?? 0.0;

      if (balance < amount) {
        throw Exception('رصيد غير كافي');
      }

      final newBalance = balance - amount;

      // 1) خصم الرصيد
      tx.set(wRef, {
        'balance': newBalance,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 2) سجل عملية
      tx.set(txnsRef(uid).doc(), {
        'type': 'debit',
        'amount': amount,
        'tripId': tripId,
        'note': 'trip payment',
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 3) تحديث الرحلة
      tx.set(tRef, {
        'paymentMethod': 'wallet',
        'paymentStatus': 'paid',
        'status': 'in_trip',
        'paidAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }
}
