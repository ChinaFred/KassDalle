import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/theme/theme_mode_preference.dart';

/// Mémoire à la place des préférences : ce qui a été lu, ce qui a été écrit.
class _MemoryStore implements ThemeModeStore {
  _MemoryStore([this.stored]);

  String? stored;
  final saved = <String>[];

  @override
  Future<String?> load() async => stored;

  @override
  Future<void> save(String value) async {
    saved.add(value);
    stored = value;
  }
}

/// Une lecture qui échoue : préférences illisibles.
class _BrokenStore implements ThemeModeStore {
  @override
  Future<String?> load() async => throw StateError('préférences illisibles');

  @override
  Future<void> save(String value) async {}
}

/// Une écriture qui échoue : préférences en lecture seule.
class _BrokenSaveStore implements ThemeModeStore {
  @override
  Future<String?> load() async => null;

  @override
  Future<void> save(String value) async =>
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
  ThemeModeStore store, {
  _RecordingErrorReportService? reports,
}) {
  final container = ProviderContainer(
    overrides: [
      themeModeStoreProvider.overrideWithValue(store),
      themeModeErrorReportProvider.overrideWithValue(
        reports ?? _RecordingErrorReportService(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('valeur stockée', () {
    test('chaque mode fait l aller-retour', () {
      for (final mode in ThemeMode.values) {
        expect(themeModeFromStored(themeModeToStored(mode)), mode);
      }
    });

    test('une valeur absente ou inconnue suit l appareil', () {
      expect(themeModeFromStored(null), ThemeMode.system);
      expect(themeModeFromStored('bleu'), ThemeMode.system);
    });
  });

  group('ThemeModeNotifier', () {
    test('lit le mode mémorisé', () async {
      final container = _container(_MemoryStore('dark'));
      expect(await container.read(themeModeProvider.future), ThemeMode.dark);
    });

    test('sans préférence, suit l appareil', () async {
      final container = _container(_MemoryStore());
      expect(await container.read(themeModeProvider.future), ThemeMode.system);
    });

    test('une préférence illisible suit l appareil, et se signale', () async {
      final reports = _RecordingErrorReportService();
      final container = _container(_BrokenStore(), reports: reports);

      expect(await container.read(themeModeProvider.future), ThemeMode.system);
      expect(reports.features, ['theme_mode_load']);
    });

    test('choisir un mode l applique et le mémorise', () async {
      final store = _MemoryStore();
      final container = _container(store);
      await container.read(themeModeProvider.future);

      await container.read(themeModeProvider.notifier).select(ThemeMode.light);

      expect(container.read(themeModeProvider).value, ThemeMode.light);
      expect(store.saved, ['light']);
    });

    test('rechoisir le mode courant n écrit rien', () async {
      final store = _MemoryStore('dark');
      final container = _container(store);
      await container.read(themeModeProvider.future);

      await container.read(themeModeProvider.notifier).select(ThemeMode.dark);

      expect(store.saved, isEmpty);
    });

    test('un échec d écriture garde le mode affiché, et se signale', () async {
      final reports = _RecordingErrorReportService();
      final container = _container(_BrokenSaveStore(), reports: reports);
      await container.read(themeModeProvider.future);

      await container.read(themeModeProvider.notifier).select(ThemeMode.dark);

      expect(container.read(themeModeProvider).value, ThemeMode.dark);
      expect(reports.features, ['theme_mode_save']);
    });
  });
}
