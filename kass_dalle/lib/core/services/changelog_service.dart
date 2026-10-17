import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/admin/presentation/admin_providers.dart';

/// Chemin de l'asset généré par `.github/scripts/changelog-recent.mjs`.
const kChangelogAsset = 'assets/changelog_recent.json';

/// Une version de l'historique, avec son texte « fonctionnel ».
class ChangelogEntry {
  final String version;
  final DateTime date;

  /// Markdown tel qu'écrit dans `documentation/CHANGELOG.md`.
  final String text;

  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.text,
  });

  factory ChangelogEntry.fromMap(Map<String, dynamic> map) => ChangelogEntry(
    version: map['version'] as String,
    date: DateTime.parse(map['date'] as String),
    text: map['text'] as String,
  );
}

/// Lit les entrées de l'asset, de la plus récente à la plus ancienne.
///
/// Un contenu illisible lève : l'écran affiche l'erreur, il n'y a pas de liste
/// de repli dans le code.
List<ChangelogEntry> parseChangelog(String source) {
  final decoded = jsonDecode(source) as Map<String, dynamic>;
  return (decoded['versions'] as List<dynamic>)
      .map((e) => ChangelogEntry.fromMap(e as Map<String, dynamic>))
      .toList(growable: false);
}

/// Source du JSON, remplaçable dans les tests.
final changelogLoaderProvider = Provider<Future<String> Function()>(
  (ref) =>
      () => rootBundle.loadString(kChangelogAsset),
);

final changelogProvider = FutureProvider.autoDispose<List<ChangelogEntry>>((
  ref,
) async {
  final load = ref.watch(changelogLoaderProvider);
  try {
    return parseChangelog(await load());
  } catch (error, stackTrace) {
    await ref
        .read(errorReportServiceProvider)
        .reportError(
          feature: 'changelog.load',
          error: error,
          stackTrace: stackTrace,
        );
    rethrow;
  }
});
