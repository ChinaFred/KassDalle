import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/error_report_service.dart';
import '../services/error_reporting.dart';

/// Thème de l'application : suivre l'appareil, clair ou sombre.
///
/// Mémorisé sur l'appareil (`SharedPreferences`), pas dans le compte : le
/// choix dépend de l'écran et de la pièce où on le regarde, et une tablette de
/// cuisine peut rester claire quand le téléphone passe en sombre.

/// Clé du réglage dans les préférences de l'appareil.
const kThemeModePrefKey = 'theme_mode';

/// Valeur stockée pour chaque mode. `ThemeMode.name` suffirait, mais une
/// valeur écrite sur l'appareil ne doit pas dépendre d'un nom d'énumération
/// Flutter.
const _storedValues = <ThemeMode, String>{
  ThemeMode.system: 'system',
  ThemeMode.light: 'light',
  ThemeMode.dark: 'dark',
};

/// Ramène une valeur lue dans les préférences sur un mode connu. Une valeur
/// absente ou inconnue suit l'appareil.
ThemeMode themeModeFromStored(String? stored) {
  for (final entry in _storedValues.entries) {
    if (entry.value == stored) return entry.key;
  }
  return ThemeMode.system;
}

String themeModeToStored(ThemeMode mode) => _storedValues[mode]!;

/// Lecture et écriture du réglage sur l'appareil.
///
/// Abstraite pour les tests : les préférences y sont remplacées par une
/// mémoire.
abstract class ThemeModeStore {
  Future<String?> load();
  Future<void> save(String value);
}

class SharedPreferencesThemeModeStore implements ThemeModeStore {
  const SharedPreferencesThemeModeStore();

  @override
  Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(kThemeModePrefKey);
  }

  @override
  Future<void> save(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kThemeModePrefKey, value);
  }
}

final themeModeStoreProvider = Provider<ThemeModeStore>(
  (_) => const SharedPreferencesThemeModeStore(),
);

/// Le rapporteur d'erreurs, remplaçable dans les tests : `ErrorReportService`
/// lit `FirebaseAuth.instance` avant de créer sa `Future`, et lève hors
/// Firebase.
final themeModeErrorReportProvider = Provider<ErrorReportService>(
  (_) => ErrorReportService(),
);

/// Le thème choisi. Suit l'appareil tant que la préférence n'est pas lue, et
/// quand elle ne peut pas l'être.
final themeModeProvider = AsyncNotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends AsyncNotifier<ThemeMode> {
  @override
  Future<ThemeMode> build() async {
    try {
      final stored = await ref.read(themeModeStoreProvider).load();
      return themeModeFromStored(stored);
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'theme_mode_load',
        error: e,
        stackTrace: st,
        service: ref.read(themeModeErrorReportProvider),
      );
      return ThemeMode.system;
    }
  }

  Future<void> select(ThemeMode mode) async {
    if (mode == (state.value ?? ThemeMode.system)) return;
    // L'écran change tout de suite ; la mémorisation vient après, et son échec
    // ne reprend pas le thème affiché : il vaut pour cette session, il sera
    // seulement oublié à la prochaine.
    state = AsyncData(mode);
    try {
      await ref.read(themeModeStoreProvider).save(themeModeToStored(mode));
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'theme_mode_save',
        error: e,
        stackTrace: st,
        context: {'mode': themeModeToStored(mode)},
        service: ref.read(themeModeErrorReportProvider),
      );
    }
  }
}
