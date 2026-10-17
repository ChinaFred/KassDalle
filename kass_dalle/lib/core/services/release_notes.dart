import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'error_reporting.dart';

/// Chemin de l'extrait du `CHANGELOG.md` embarqué dans l'application.
///
/// Généré par `.github/scripts/changelog-recent.mjs`, que `ci.yml`,
/// `deploy.yml` et `deploy.ps1` lancent avant les tests et le build : la
/// version installée connaît son propre historique. Le fichier versionné sert
/// à `flutter run` et aux tests locaux ; il peut dater de quelques versions.
const kReleaseNotesAsset = 'assets/changelog_recent.json';

/// Une version telle que l'écran « Nouveautés » l'affiche.
class ReleaseNote {
  /// Nom de version, sans le `v` ni le numéro de build : `0.23.98`.
  final String version;

  /// Date du titre `## AAAA-MM-JJ` du `CHANGELOG.md`. Absente si la version
  /// précède le premier titre daté.
  final DateTime? date;

  /// Texte Markdown des entrées « fonctionnel ».
  final String text;

  const ReleaseNote({
    required this.version,
    required this.date,
    required this.text,
  });
}

/// Lit l'extrait. Lève une [FormatException] si sa forme est inattendue :
/// aucune valeur de repli, l'écran affiche alors l'état d'erreur.
List<ReleaseNote> parseReleaseNotes(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Extrait du CHANGELOG : objet attendu.');
  }
  final versions = decoded['versions'];
  if (versions is! List || versions.isEmpty) {
    throw const FormatException(
      'Extrait du CHANGELOG : liste « versions » vide ou absente.',
    );
  }
  return [
    for (final entry in versions)
      if (entry case {
        'version': final String version,
        'date': final Object? date,
        'text': final String text,
      } when version.isNotEmpty && text.isNotEmpty)
        ReleaseNote(
          version: version,
          date: date is String ? DateTime.tryParse(date) : null,
          text: text,
        )
      else
        throw FormatException(
          'Extrait du CHANGELOG : entrée invalide.',
          entry.toString(),
        ),
  ];
}

/// Les dernières versions publiées, lues dans l'asset embarqué.
final releaseNotesProvider = FutureProvider.autoDispose<List<ReleaseNote>>((
  ref,
) async {
  try {
    return parseReleaseNotes(await rootBundle.loadString(kReleaseNotesAsset));
  } catch (error, stackTrace) {
    reportUnexpectedError(
      feature: 'releaseNotes.load',
      error: error,
      stackTrace: stackTrace,
      context: {'asset': kReleaseNotesAsset},
    );
    rethrow;
  }
});
