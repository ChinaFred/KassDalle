import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/error_report_service.dart';

/// Mémoire des plannings basculés par rapport au défaut du
/// rôle (voir `planning_visibility.dart`).
///
/// Une clé par compte et par rôle : un appareil partagé par la famille ne
/// mélange pas les choix de chacun, et un lecteur promu éditeur ne relit pas
/// des bascules qui disaient l'inverse.
///
/// Deux implémentations : l'appareil seul (`SharedPreferences`), et le compte
/// (`FirestorePlanningVisibilityStore`), qui suit le membre d'un appareil à
/// l'autre.
///
/// Abstraite pour les tests : les préférences y sont remplacées par une
/// mémoire.
abstract class PlanningVisibilityStore {
  Future<Set<String>> load({required String uid, required bool canPlan});
  Future<void> save(
    Set<String> toggled, {
    required String uid,
    required bool canPlan,
  });
}

/// Clé du réglage dans les préférences de l'appareil.
String planningVisibilityPrefKey({
  required String uid,
  required bool canPlan,
}) => 'planning_toggled.${canPlan ? 'editor' : 'reader'}.$uid';

class SharedPreferencesPlanningVisibilityStore
    implements PlanningVisibilityStore {
  const SharedPreferencesPlanningVisibilityStore();

  @override
  Future<Set<String>> load({required String uid, required bool canPlan}) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(
      planningVisibilityPrefKey(uid: uid, canPlan: canPlan),
    );
    return stored?.toSet() ?? <String>{};
  }

  @override
  Future<void> save(
    Set<String> toggled, {
    required String uid,
    required bool canPlan,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      planningVisibilityPrefKey(uid: uid, canPlan: canPlan),
      toggled.toList()..sort(),
    );
  }
}

/// Mémoire sur le compte : `users/{uid}/preferences/planning_visibility`,
/// `{ editor: [uid], reader: [uid], updated_at }`. Deux listes, une par rôle,
/// pour qu'un lecteur promu éditeur ne relise pas des bascules qui disaient
/// l'inverse. Une préférence de lecteur, sous son compte, jamais dans un
/// document partagé.
///
/// L'appareil garde une copie ([_local]) : elle sert hors ligne, et elle
/// reprend la sélection d'avant la v0.23.70 — sans valeur distante pour le
/// rôle, la copie locale est lue, puis envoyée.
class FirestorePlanningVisibilityStore implements PlanningVisibilityStore {
  /// Le plafond de la règle Firestore (`isPlanningVisibility`).
  static const maxEntries = 100;

  final FirebaseFirestore _firestore;
  final PlanningVisibilityStore _local;
  final ErrorReportService _errorReportService;

  FirestorePlanningVisibilityStore({
    FirebaseFirestore? firestore,
    PlanningVisibilityStore local =
        const SharedPreferencesPlanningVisibilityStore(),
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _local = local,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  DocumentReference<Map<String, dynamic>> _doc(String uid) => _firestore
      .collection('users')
      .doc(uid)
      .collection('preferences')
      .doc('planning_visibility');

  static String _field(bool canPlan) => canPlan ? 'editor' : 'reader';

  @override
  Future<Set<String>> load({required String uid, required bool canPlan}) async {
    final field = _field(canPlan);
    final Map<String, dynamic>? data;
    try {
      data = (await _doc(uid).get()).data();
    } catch (e, st) {
      _report('planning_visibility_remote_load', e, st, uid);
      return _local.load(uid: uid, canPlan: canPlan);
    }
    final remote = data?[field];
    if (remote is List) {
      final toggled = remote.whereType<String>().toSet();
      await _cache(toggled, uid: uid, canPlan: canPlan);
      return toggled;
    }
    // Rien pour ce rôle sur le compte : reprise de la sélection de l'appareil.
    final local = await _local.load(uid: uid, canPlan: canPlan);
    if (local.isNotEmpty) {
      await _push(local, uid: uid, canPlan: canPlan);
    }
    return local;
  }

  @override
  Future<void> save(
    Set<String> toggled, {
    required String uid,
    required bool canPlan,
  }) async {
    await _local.save(toggled, uid: uid, canPlan: canPlan);
    await _push(toggled, uid: uid, canPlan: canPlan);
  }

  Future<void> _cache(
    Set<String> toggled, {
    required String uid,
    required bool canPlan,
  }) async {
    try {
      await _local.save(toggled, uid: uid, canPlan: canPlan);
    } catch (e, st) {
      _report('planning_visibility_cache', e, st, uid);
    }
  }

  /// Écrit la liste du rôle seule : l'autre rôle garde la sienne (`merge`).
  Future<void> _push(
    Set<String> toggled, {
    required String uid,
    required bool canPlan,
  }) async {
    try {
      final sorted = toggled.toList()..sort();
      await _doc(uid).set({
        _field(canPlan): sorted.take(maxEntries).toList(),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e, st) {
      _report('planning_visibility_remote_save', e, st, uid);
    }
  }

  void _report(String feature, Object e, StackTrace st, String uid) {
    unawaited(
      _errorReportService.reportError(
        feature: feature,
        error: e,
        stackTrace: st,
        context: {'uid': uid},
      ),
    );
  }
}

/// Une mémoire, pour les tests et les plateformes sans préférences.
class InMemoryPlanningVisibilityStore implements PlanningVisibilityStore {
  InMemoryPlanningVisibilityStore([Map<String, Set<String>>? initial])
    : values = initial ?? {};

  final Map<String, Set<String>> values;

  @override
  Future<Set<String>> load({
    required String uid,
    required bool canPlan,
  }) async => {
    ...?values[planningVisibilityPrefKey(uid: uid, canPlan: canPlan)],
  };

  @override
  Future<void> save(
    Set<String> toggled, {
    required String uid,
    required bool canPlan,
  }) async {
    values[planningVisibilityPrefKey(uid: uid, canPlan: canPlan)] = {
      ...toggled,
    };
  }
}
