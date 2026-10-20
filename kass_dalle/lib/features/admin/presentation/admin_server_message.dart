import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/gemini_service.dart'
    show GeminiCallableException;
import '../../../core/widgets/error_message.dart';
import '../data/gcp_billing_repository.dart' show CallableFailure;

/// Le message qu'une Cloud Function a écrit pour l'écran d'administration,
/// ou null.
///
/// [codes] est la liste blanche de l'appelant : il n'y met que les codes dont
/// il a lu le texte dans `functions/src` (des phrases en français écrites pour
/// l'administrateur). `internal` et `unknown` recopient l'exception brute,
/// et sur mobile `unavailable` et `deadline-exceeded` arrivent avec le texte
/// anglais du SDK : ils sont refusés même s'ils sont passés dans [codes].
String? adminServerMessage(Object? error, Set<String> codes) {
  final String code;
  final String? message;
  if (error is FirebaseFunctionsException) {
    code = error.code;
    message = error.message;
  } else if (error is GeminiCallableException) {
    code = error.code;
    message = error.message;
  } else if (error is CallableFailure) {
    code = error.code;
    message = error.message;
  } else {
    return null;
  }
  final normalized = code.toLowerCase().replaceAll('_', '-');
  if (_neverShown.contains(normalized)) return null;
  if (!codes.contains(normalized)) return null;
  final text = message?.trim() ?? '';
  return text.isEmpty ? null : text;
}

const _neverShown = {'internal', 'unknown', 'unavailable', 'deadline-exceeded'};

/// L'échec d'une action d'administration en deux phrases : ce qui n'a pas eu
/// lieu ([what]), puis le message du serveur s'il est dans la liste blanche
/// [codes] (« Image non publiée. Cette image n'attend pas de décision. »),
/// sinon la cause lisible de [failureMessage].
String adminFailureMessage(
  String what,
  Object? error, {
  Set<String> codes = const {},
}) {
  final server = adminServerMessage(error, codes);
  if (server == null) return failureMessage(what, readableError(error));
  final head = what.trimRight();
  const endings = ['.', '!', '?', '…'];
  final sentence = endings.any(head.endsWith) ? head : '$head.';
  return '$sentence $server';
}

/// [error] sous une forme que [describeError] sait lire.
///
/// [CallableFailure] (dépôt de facturation, appel HTTP direct sur le web)
/// porte le code de la callable sans être une exception Firebase :
/// [describeError] n'y verrait qu'une « erreur inattendue ». Elle est
/// ramenée à une [FirebaseFunctionsException] de même code. Le texte affiché
/// reste le titre de [describeError], jamais le message.
Object? readableError(Object? error) => error is CallableFailure
    ? FirebaseFunctionsException(code: error.code, message: error.message)
    : error;
