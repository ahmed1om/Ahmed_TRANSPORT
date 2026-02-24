import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class AdminPricingPage extends StatefulWidget {
  const AdminPricingPage({super.key});

  @override
  State<AdminPricingPage> createState() => _AdminPricingPageState();
}

class _AdminPricingPageState extends State<AdminPricingPage> {
  final _perKmCtrl = TextEditingController();
  final _baseFareCtrl = TextEditingController();
  bool _loading = true;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _perKmCtrl.dispose();
    _baseFareCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _msg = null;
    });

    final doc = await FirebaseFirestore.instance
        .collection('settings')
        .doc('pricing')
        .get();

    final data = doc.data() ?? {};
    final perKm = (data['perKm'] as num?)?.toDouble() ?? 0;
    final baseFare = (data['baseFare'] as num?)?.toDouble() ?? 0;

    _perKmCtrl.text = perKm.toString();
    _baseFareCtrl.text = baseFare.toString();

    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final perKm = double.tryParse(_perKmCtrl.text.trim()) ?? 0;
    final baseFare = double.tryParse(_baseFareCtrl.text.trim()) ?? 0;

    await FirebaseFirestore.instance.collection('settings').doc('pricing').set({
      'perKm': perKm,
      'baseFare': baseFare,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    setState(() => _msg = '✅ تم حفظ التسعير');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin • Pricing')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'حدد تكلفة الكيلو + رسوم ثابتة (تطبق على كل المسارات)',
                  ),
                  const SizedBox(height: 16),

                  TextField(
                    controller: _perKmCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'perKm (سعر الكيلو)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  TextField(
                    controller: _baseFareCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'baseFare (رسوم ثابتة)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                  ),

                  if (_msg != null) ...[
                    const SizedBox(height: 12),
                    Text(_msg!),
                  ],
                ],
              ),
      ),
    );
  }
}
