import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Garde des messages d'erreur : le texte brut d'une exception ne s'affiche
/// pas.
///
/// L'audit #151 (tickets #170 et #171) a relevé une soixantaine de messages
/// de la forme `showErrorSnackBar('Enregistrement impossible : $e')` ou
/// `Text('Politique illisible : $error')`. Un membre y lisait
/// `[cloud_firestore/unavailable] Failed to get document…`. Les lots 8a à 8d
/// les ont remplacés par `failureMessage` / `showFailureSnackBar` (deux
/// phrases : ce qui n'a pas eu lieu, puis le titre de `describeError`) et par
/// `AppErrorState`, dont « Détails » est réservé à l'administrateur.
///
/// Ce test lit les `.dart` de `lib/features/**/presentation` et de
/// `lib/core/presentation`. Il échoue si l'argument d'un appel
/// `show…SnackBar(`, `showFailureSnackBar(` ou `…Text(` interpole `$e`,
/// `${e}`, `$error`, `${error}` ou `$_error`, ou appelle `e.toString()`.
///
/// Un cas conforme qui reste se déclare dans [_exceptions] : fichier, motif
/// présent dans l'appel, et la raison. Une exception qui ne sert plus fait
/// échouer le second test : elle sort de la liste.
const _exceptions = <({String file, String pattern, String reason})>[
  // Aucune exception à ce jour. Forme attendue :
  // (
  //   file: 'lib/features/x/presentation/y.dart',
  //   pattern: "Text('… \$error')",
  //   reason: 'texte de domaine écrit pour l\'écran, pas une exception',
  // ),
];

final _forbidden = RegExp(
  r'\$e(?![\w])|\$\{e\}|\$error(?![\w])|\$\{error\}|\$_error(?![\w])'
  r'|(?<![\w.$])e\.toString\(\)',
);

final _callStart = RegExp(r'(?<![\w$])(show\w*SnackBar|\w*Text)\(');

/// Les appels surveillés de [source] dont l'argument contient un motif
/// interdit, avec leur numéro de ligne.
List<({int line, String call})> offendingCalls(String source) {
  final found = <({int line, String call})>[];
  for (final match in _callStart.allMatches(source)) {
    final lineStart = source.lastIndexOf('\n', match.start) + 1;
    // Un appel cité dans un commentaire n'est pas du code.
    if (source.substring(lineStart, match.start).contains('//')) continue;
    final end = _argumentsEnd(source, match.end);
    if (end == null) continue;
    final call = source.substring(match.start, end);
    if (!_forbidden.hasMatch(call)) continue;
    final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
    found.add((line: line, call: call));
  }
  return found;
}

/// Position juste après la parenthèse qui ferme l'appel ouvert en [from].
///
/// Les parenthèses des chaînes ne comptent pas ; celles d'une interpolation
/// `${…}` comptent. Null si l'appel n'est pas fermé.
int? _argumentsEnd(String s, int from) {
  var depth = 1;
  // Pile des contextes : null = code, sinon le délimiteur de la chaîne
  // ouverte (`'`, `"`, `'''`, `"""`), précédé de `r` pour une chaîne brute.
  final stack = <String?>[null];
  // Accolades ouvertes dans chaque interpolation en cours.
  final braces = <int>[];
  var i = from;
  while (i < s.length) {
    final mode = stack.last;
    if (mode == null) {
      if (s.startsWith('//', i)) {
        final eol = s.indexOf('\n', i);
        if (eol < 0) return null;
        i = eol + 1;
        continue;
      }
      final c = s[i];
      if (c == "'" || c == '"') {
        final triple = s.startsWith(c * 3, i);
        final raw = i > 0 && s[i - 1] == 'r';
        final delimiter = triple ? c * 3 : c;
        stack.add(raw ? 'r$delimiter' : delimiter);
        i += delimiter.length;
        continue;
      }
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) return i + 1;
      }
      if (braces.isNotEmpty && stack.length > 1) {
        if (c == '{') braces[braces.length - 1]++;
        if (c == '}') {
          if (braces.last == 0) {
            braces.removeLast();
            stack.removeLast();
            i++;
            continue;
          }
          braces[braces.length - 1]--;
        }
      }
      i++;
      continue;
    }
    final raw = mode.startsWith('r');
    final delimiter = raw ? mode.substring(1) : mode;
    if (!raw && s[i] == r'\') {
      i += 2;
      continue;
    }
    if (s.startsWith(delimiter, i)) {
      stack.removeLast();
      i += delimiter.length;
      continue;
    }
    if (!raw && s.startsWith(r'${', i)) {
      stack.add(null);
      braces.add(0);
      i += 2;
      continue;
    }
    i++;
  }
  return null;
}

Iterable<File> _scannedFiles() sync* {
  final roots = [
    Directory('lib/core/presentation'),
    ...Directory('lib/features')
        .listSync(recursive: true)
        .whereType<Directory>()
        .where((d) => d.path.replaceAll('\\', '/').endsWith('/presentation')),
  ];
  for (final root in roots) {
    yield* root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
  }
}

void main() {
  test('aucun texte brut d\'exception dans un message affiché', () {
    final offenders = <String>[];
    for (final file in _scannedFiles()) {
      final path = file.path.replaceAll('\\', '/');
      for (final hit in offendingCalls(file.readAsStringSync())) {
        final allowed = _exceptions.any(
          (x) => path == x.file && hit.call.contains(x.pattern),
        );
        if (!allowed) {
          offenders.add('$path:${hit.line}: ${hit.call.split('\n').first}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('chaque exception de la garde sert encore', () {
    final stale = <String>[];
    for (final x in _exceptions) {
      final file = File(x.file);
      final used =
          file.existsSync() &&
          offendingCalls(
            file.readAsStringSync(),
          ).any((hit) => hit.call.contains(x.pattern));
      if (!used) stale.add('${x.file} : ${x.pattern}');
    }
    expect(stale, isEmpty, reason: stale.join('\n'));
  });

  group('la garde', () {
    bool flags(String source) => offendingCalls(source).isNotEmpty;

    test('détecte les formes interdites', () {
      expect(flags(r"context.showErrorSnackBar('Erreur : $e');"), isTrue);
      expect(flags(r"context.showSnackBar('Relance : ${e}');"), isTrue);
      expect(flags(r"Text('Politique illisible : $error')"), isTrue);
      expect(flags(r"Text('${error}')"), isTrue);
      expect(flags(r"subtitle: Text('$_error'),"), isTrue);
      expect(flags('SelectableText(e.toString())'), isTrue);
      expect(
        flags(
          r"messenger.showSnackBar(SnackBar(content: Text('Erreur: $e')));",
        ),
        isTrue,
      );
      expect(
        flags(r"""context.showErrorSnackBar(
          'Échec de la relance : '
          '$e',
        );"""),
        isTrue,
      );
    });

    test('laisse passer les formes conformes', () {
      expect(
        flags("context.showFailureSnackBar('Unité non créée', e);"),
        isFalse,
      );
      expect(flags(r"Text('$errorCount erreurs')"), isFalse);
      expect(flags(r"Text('${dt.minute.toString()}')"), isFalse);
      expect(flags(r"Text('Bonjour $name')"), isFalse);
      expect(flags(r"// Text('Erreur : $e')"), isFalse);
      // Une parenthèse dans une chaîne ne ferme pas l'appel.
      expect(flags(r"Text('Coût (HTTP $status)') + f($e)"), isFalse);
    });
  });
}
