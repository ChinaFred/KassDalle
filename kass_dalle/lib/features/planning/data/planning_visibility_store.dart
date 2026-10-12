import 'package:shared_preferences/shared_preferences.dart';

/// Mémoire, sur l'appareil, des plannings basculés par rapport au défaut du
/// rôle (voir `planning_visibility.dart`).
///
/// Une clé par compte et par rôle : un appareil partagé par la famille ne
/// mélange pas les choix de chacun, et un lecteur promu éditeur ne relit pas
/// des bascules qui disaient l'inverse.
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
