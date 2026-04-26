import 'package:cloud_firestore/cloud_firestore.dart';

// ── Seuils d'alerte ───────────────────────────────────────────────────────────
// Firebase Storage  : 5 Go gratuits sur Blaze → alerte à 4 Go (80 %)
// Gemini 1.5-flash  : 1 500 req/jour gratuites → alerte à 800 scans/mois
//                     (env. 27/jour, marge confortable avant quota)

class UsageLimits {
  static const int storageWarnBytes = 4 * 1024 * 1024 * 1024; // 4 Go
  static const int storageFreeBytes = 5 * 1024 * 1024 * 1024; // 5 Go
  static const int geminiWarnPerMonth = 800;
}

// ── Modèle de stats ───────────────────────────────────────────────────────────

class UsageStats {
  final int storageBytes;
  final int scansThisMonth;
  final DateTime? lastUpdated;

  const UsageStats({
    this.storageBytes = 0,
    this.scansThisMonth = 0,
    this.lastUpdated,
  });

  factory UsageStats.fromMap(Map<String, dynamic> map) {
    final key = _monthKey(DateTime.now());
    return UsageStats(
      storageBytes: (map['storage_bytes'] as int?) ?? 0,
      scansThisMonth: (map['scans_$key'] as int?) ?? 0,
      lastUpdated: (map['updated_at'] as Timestamp?)?.toDate(),
    );
  }

  bool get storageWarning => storageBytes >= UsageLimits.storageWarnBytes;
  bool get geminiWarning => scansThisMonth >= UsageLimits.geminiWarnPerMonth;
  bool get hasWarning => storageWarning || geminiWarning;

  double get storagePercent =>
      (storageBytes / UsageLimits.storageFreeBytes).clamp(0.0, 1.0);

  String get storageFmt {
    if (storageBytes < 1024 * 1024) {
      return '${(storageBytes / 1024).toStringAsFixed(1)} Ko';
    }
    if (storageBytes < 1024 * 1024 * 1024) {
      return '${(storageBytes / 1024 / 1024).toStringAsFixed(1)} Mo';
    }
    return '${(storageBytes / 1024 / 1024 / 1024).toStringAsFixed(2)} Go';
  }
}

String _monthKey(DateTime d) =>
    '${d.year}_${d.month.toString().padLeft(2, '0')}';

// ── Service ───────────────────────────────────────────────────────────────────

class UsageTracker {
  final FirebaseFirestore _db;

  UsageTracker({FirebaseFirestore? db})
    : _db = db ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _doc =>
      _db.collection('app_config').doc('usage');

  /// Stream des stats d'utilisation (lecture temps réel).
  Stream<UsageStats> watch() => _doc.snapshots().map(
    (s) => s.exists ? UsageStats.fromMap(s.data()!) : const UsageStats(),
  );

  /// Enregistre un scan : incrémente le compteur mensuel + les octets stockés.
  Future<void> recordScan({required int fileBytes}) async {
    final key = _monthKey(DateTime.now());
    await _doc.set({
      'scans_$key': FieldValue.increment(1),
      'storage_bytes': FieldValue.increment(fileBytes),
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
