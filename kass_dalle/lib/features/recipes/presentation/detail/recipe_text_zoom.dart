import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/services/error_report_service.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/utils/platform_utils.dart';

/// Zoom du texte de la recette — l'onglet « Préparer » : ingrédients, étapes,
/// puces.
///
/// Une tablette posée sur le plan de travail se lit à un mètre ; tenue en
/// main, à trente centimètres. Le réglage « Taille de police » du système
/// vaut pour toute la tablette et se change en quatre écrans : il ne sert pas
/// à passer de l'un à l'autre entre deux étapes. D'où deux boutons dans la
/// barre de la fiche, et un réglage propre à l'appareil.
///
/// Le zoom se compose avec l'échelle du système, il ne la remplace pas : une
/// police déjà agrandie dans les réglages Android reste agrandie, et le zoom
/// multiplie par-dessus.

/// Les paliers offerts, du plus petit au plus grand. Le premier est l'échelle
/// normale.
const kRecipeTextZoomLevels = <double>[1.0, 1.25, 1.5, 1.75, 2.0];

/// Clé du réglage dans les préférences de l'appareil.
const kRecipeTextZoomPrefKey = 'recipe_text_zoom';

const _epsilon = 1e-6;

/// Le palier au-dessus de [current], ou [current] lui-même en butée.
double recipeTextZoomNext(double current) {
  for (final level in kRecipeTextZoomLevels) {
    if (level > current + _epsilon) return level;
  }
  return current;
}

/// Le palier au-dessous de [current], ou [current] lui-même en butée.
double recipeTextZoomPrevious(double current) {
  for (final level in kRecipeTextZoomLevels.reversed) {
    if (level < current - _epsilon) return level;
  }
  return current;
}

/// Ramène une valeur lue dans les préférences sur un palier connu.
///
/// Une valeur absente vaut l'échelle normale. Une valeur hors liste — un
/// palier retiré d'une version à l'autre, une préférence altérée — rejoint le
/// palier le plus proche, plutôt que d'afficher une échelle que les boutons ne
/// savent pas quitter.
double recipeTextZoomNormalize(double? stored) {
  if (stored == null || !stored.isFinite) return kRecipeTextZoomLevels.first;
  var best = kRecipeTextZoomLevels.first;
  for (final level in kRecipeTextZoomLevels) {
    if ((level - stored).abs() < (best - stored).abs()) best = level;
  }
  return best;
}

/// Le zoom est-il proposé dans ce contexte : l'APK Android, en présentation
/// étendue. C'est la tablette. Le téléphone, en présentation compacte, garde
/// la fiche telle quelle ; le web et le bureau aussi.
bool recipeTextZoomAvailable(BuildContext context) =>
    PlatformUtils.isAndroidApp &&
    MediaQuery.sizeOf(context).width >= PlatformUtils.compactDetailBreakpoint;

/// Compose l'échelle du système avec le zoom de la recette.
///
/// `TextScaler.linear(système × zoom)` aurait suffi pour une échelle linéaire.
/// Depuis Android 14, l'échelle du système ne l'est plus — les grandes tailles
/// grossissent moins que les petites — et la réduire à un seul facteur
/// perdrait cette courbe. Ici le zoom s'applique après elle, taille par
/// taille.
class ZoomedTextScaler extends TextScaler {
  const ZoomedTextScaler(this.base, this.zoom) : assert(zoom > 0);

  final TextScaler base;
  final double zoom;

  @override
  double scale(double fontSize) => base.scale(fontSize) * zoom;

  @override
  double get textScaleFactor => base.scale(1.0) * zoom;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomedTextScaler && other.base == base && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(base, zoom);

  @override
  String toString() => 'zoom ×$zoom sur $base';
}

/// Lecture et écriture du réglage sur l'appareil.
///
/// Abstraite pour les tests : les préférences y sont remplacées par une
/// mémoire.
abstract class RecipeTextZoomStore {
  Future<double?> load();
  Future<void> save(double zoom);
}

class SharedPreferencesRecipeTextZoomStore implements RecipeTextZoomStore {
  const SharedPreferencesRecipeTextZoomStore();

  @override
  Future<double?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(kRecipeTextZoomPrefKey);
  }

  @override
  Future<void> save(double zoom) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kRecipeTextZoomPrefKey, zoom);
  }
}

final recipeTextZoomStoreProvider = Provider<RecipeTextZoomStore>(
  (_) => const SharedPreferencesRecipeTextZoomStore(),
);

/// Le rapporteur d'erreurs, remplaçable dans les tests : `ErrorReportService`
/// lit `FirebaseAuth.instance` avant de créer sa `Future`, et lève hors
/// Firebase.
final recipeTextZoomErrorReportProvider = Provider<ErrorReportService>(
  (_) => ErrorReportService(),
);

/// Le zoom courant. Vaut l'échelle normale tant que la préférence n'est pas
/// lue, et quand elle ne peut pas l'être.
final recipeTextZoomProvider =
    AsyncNotifierProvider<RecipeTextZoomNotifier, double>(
      RecipeTextZoomNotifier.new,
    );

class RecipeTextZoomNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    try {
      final stored = await ref.read(recipeTextZoomStoreProvider).load();
      return recipeTextZoomNormalize(stored);
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'recipe_text_zoom_load',
        error: e,
        stackTrace: st,
        service: ref.read(recipeTextZoomErrorReportProvider),
      );
      return kRecipeTextZoomLevels.first;
    }
  }

  double get _current => state.value ?? kRecipeTextZoomLevels.first;

  Future<void> zoomIn() => _apply(recipeTextZoomNext(_current));

  Future<void> zoomOut() => _apply(recipeTextZoomPrevious(_current));

  Future<void> _apply(double zoom) async {
    if (zoom == _current) return;
    // L'écran suit tout de suite ; la mémorisation vient après, et son échec
    // ne reprend pas ce qui est affiché : le zoom vaut pour cette session, il
    // sera seulement oublié à la prochaine.
    state = AsyncData(zoom);
    try {
      await ref.read(recipeTextZoomStoreProvider).save(zoom);
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'recipe_text_zoom_save',
        error: e,
        stackTrace: st,
        context: {'zoom': zoom},
        service: ref.read(recipeTextZoomErrorReportProvider),
      );
    }
  }
}

/// Les deux boutons de la barre : réduire, agrandir. Inertes en butée, et
/// absents là où le zoom n'est pas proposé.
class RecipeTextZoomButtons extends ConsumerWidget {
  const RecipeTextZoomButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!recipeTextZoomAvailable(context)) return const SizedBox.shrink();
    final zoom =
        ref.watch(recipeTextZoomProvider).value ?? kRecipeTextZoomLevels.first;
    final notifier = ref.read(recipeTextZoomProvider.notifier);
    final canZoomOut = recipeTextZoomPrevious(zoom) != zoom;
    final canZoomIn = recipeTextZoomNext(zoom) != zoom;
    final pourcent = '${(zoom * 100).round()} %';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.text_decrease),
          tooltip: 'Réduire le texte de la recette ($pourcent)',
          onPressed: canZoomOut ? notifier.zoomOut : null,
        ),
        IconButton(
          icon: const Icon(Icons.text_increase),
          tooltip: 'Agrandir le texte de la recette ($pourcent)',
          onPressed: canZoomIn ? notifier.zoomIn : null,
        ),
      ],
    );
  }
}

/// Applique le zoom à son enfant. Rend l'enfant tel quel là où le zoom n'est
/// pas proposé, et à l'échelle normale.
///
/// Seul le texte change : `MediaQuery.sizeOf` et le reste des mesures restent
/// ceux de l'écran. Les feuilles et dialogues ouverts depuis l'enfant se
/// construisent sous le navigateur, au-dessus de cette enveloppe : ils gardent
/// leur taille.
class RecipeTextZoomArea extends ConsumerWidget {
  const RecipeTextZoomArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!recipeTextZoomAvailable(context)) return child;
    final zoom =
        ref.watch(recipeTextZoomProvider).value ?? kRecipeTextZoomLevels.first;
    if (zoom == kRecipeTextZoomLevels.first) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: ZoomedTextScaler(media.textScaler, zoom),
      ),
      child: child,
    );
  }
}
