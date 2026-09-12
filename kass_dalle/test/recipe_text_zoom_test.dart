import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/recipes/presentation/cooklang_preview_steps.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/recipe_text_zoom.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mémoire à la place des préférences : ce qui a été lu, ce qui a été écrit.
class _MemoryStore implements RecipeTextZoomStore {
  _MemoryStore([this.stored]);

  double? stored;
  final saved = <double>[];

  @override
  Future<double?> load() async => stored;

  @override
  Future<void> save(double zoom) async {
    saved.add(zoom);
    stored = zoom;
  }
}

/// Une lecture qui échoue : préférences illisibles.
class _BrokenStore implements RecipeTextZoomStore {
  @override
  Future<double?> load() async => throw StateError('préférences illisibles');

  @override
  Future<void> save(double zoom) async {}
}

/// Une écriture qui échoue : préférences en lecture seule.
class _BrokenSaveStore implements RecipeTextZoomStore {
  @override
  Future<double?> load() async => null;

  @override
  Future<void> save(double zoom) async =>
      throw StateError('préférences en lecture seule');
}

/// Enregistre les postes signalés, sans Firebase.
class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'report';
  }
}

ProviderContainer _container(
  RecipeTextZoomStore store, {
  _RecordingErrorReportService? reports,
}) {
  final container = ProviderContainer(
    overrides: [
      recipeTextZoomStoreProvider.overrideWithValue(store),
      recipeTextZoomErrorReportProvider.overrideWithValue(
        reports ?? _RecordingErrorReportService(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('paliers', () {
    test('cinq paliers, de 100 % à 200 %', () {
      expect(kRecipeTextZoomLevels, [1.0, 1.25, 1.5, 1.75, 2.0]);
    });

    test('agrandir monte d un palier et s arrête en butée', () {
      expect(recipeTextZoomNext(1.0), 1.25);
      expect(recipeTextZoomNext(1.75), 2.0);
      expect(recipeTextZoomNext(2.0), 2.0);
    });

    test('réduire descend d un palier et s arrête en butée', () {
      expect(recipeTextZoomPrevious(2.0), 1.75);
      expect(recipeTextZoomPrevious(1.25), 1.0);
      expect(recipeTextZoomPrevious(1.0), 1.0);
    });

    test('une valeur absente ou altérée rejoint un palier connu', () {
      expect(recipeTextZoomNormalize(null), 1.0);
      expect(recipeTextZoomNormalize(double.nan), 1.0);
      expect(recipeTextZoomNormalize(1.5), 1.5);
      expect(recipeTextZoomNormalize(1.6), 1.5);
      expect(recipeTextZoomNormalize(3.7), 2.0);
      expect(recipeTextZoomNormalize(0.2), 1.0);
    });
  });

  group('ZoomedTextScaler', () {
    test('le zoom s applique après l échelle du système', () {
      const scaler = ZoomedTextScaler(TextScaler.linear(1.5), 2.0);
      expect(scaler.scale(12), 36);
    });

    test('deux enveloppes identiques sont égales', () {
      const a = ZoomedTextScaler(TextScaler.noScaling, 1.25);
      const b = ZoomedTextScaler(TextScaler.noScaling, 1.25);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const ZoomedTextScaler(TextScaler.noScaling, 1.5)));
    });
  });

  group('RecipeTextZoomNotifier', () {
    test('lit le palier mémorisé', () async {
      final container = _container(_MemoryStore(1.5));
      expect(await container.read(recipeTextZoomProvider.future), 1.5);
    });

    test('sans préférence, échelle normale', () async {
      final container = _container(_MemoryStore());
      expect(await container.read(recipeTextZoomProvider.future), 1.0);
    });

    test(
      'une préférence illisible vaut l échelle normale, et se signale',
      () async {
        final reports = _RecordingErrorReportService();
        final container = _container(_BrokenStore(), reports: reports);

        expect(await container.read(recipeTextZoomProvider.future), 1.0);
        expect(reports.features, ['recipe_text_zoom_load']);
      },
    );

    test('agrandir change l affichage et mémorise le palier', () async {
      final store = _MemoryStore();
      final container = _container(store);
      await container.read(recipeTextZoomProvider.future);

      await container.read(recipeTextZoomProvider.notifier).zoomIn();

      expect(container.read(recipeTextZoomProvider).value, 1.25);
      expect(store.saved, [1.25]);
    });

    test('en butée, rien ne change et rien n est écrit', () async {
      final store = _MemoryStore(2.0);
      final container = _container(store);
      await container.read(recipeTextZoomProvider.future);

      await container.read(recipeTextZoomProvider.notifier).zoomIn();

      expect(container.read(recipeTextZoomProvider).value, 2.0);
      expect(store.saved, isEmpty);
    });

    test('réduire redescend jusqu à l échelle normale', () async {
      final store = _MemoryStore(1.5);
      final container = _container(store);
      await container.read(recipeTextZoomProvider.future);
      final notifier = container.read(recipeTextZoomProvider.notifier);

      await notifier.zoomOut();
      await notifier.zoomOut();
      await notifier.zoomOut();

      expect(container.read(recipeTextZoomProvider).value, 1.0);
      expect(store.saved, [1.25, 1.0]);
    });

    test(
      'un enregistrement qui échoue garde l affichage, et se signale',
      () async {
        final reports = _RecordingErrorReportService();
        final container = _container(_BrokenSaveStore(), reports: reports);
        await container.read(recipeTextZoomProvider.future);

        await container.read(recipeTextZoomProvider.notifier).zoomIn();

        expect(container.read(recipeTextZoomProvider).value, 1.25);
        expect(reports.features, ['recipe_text_zoom_save']);
      },
    );
  });

  group('SharedPreferencesRecipeTextZoomStore', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('écrit et relit sous la même clé', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPreferencesRecipeTextZoomStore();

      expect(await store.load(), isNull);
      await store.save(1.75);

      expect(await store.load(), 1.75);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(kRecipeTextZoomPrefKey), 1.75);
    });
  });

  group('texte d une étape', () {
    testWidgets('suit l échelle de police du contexte', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(
              body: Builder(
                builder: (context) => cooklangBuildStepText(
                  context,
                  'Mélanger la @farine{200%g} et attendre ~{10%minutes}.',
                ),
              ),
            ),
          ),
        ),
      );

      // Le premier `Text` est celui de l'étape ; les puces d'ingrédient et de
      // minuteur sont des `Text` imbriqués dans ses spans.
      final rich = tester.widget<RichText>(
        find
            .descendant(
              of: find.byType(Text).first,
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(rich.textScaler, const TextScaler.linear(2.0));
    });
  });
}
