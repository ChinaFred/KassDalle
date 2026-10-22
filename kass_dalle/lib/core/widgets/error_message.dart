import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';

import '../services/gemini_service.dart' show GeminiCallableException;

/// Traduction d'une exception en phrase lisible par la famille.
///
/// Quatorze écrans affichaient `Center(child: Text('Erreur : $e'))`. Un cousin
/// qui perd le réseau lisait donc
/// `[cloud_firestore/unavailable] Failed to get document because the client is
/// offline`. Le texte technique n'est pas supprimé — il reste indispensable
/// pour comprendre une panne — il est seulement rangé derrière « Détails ».
///
/// Les exceptions Firebase (Firestore, Storage, Functions, Auth) héritent
/// toutes de [FirebaseException] : un seul aiguillage sur `code` les couvre.
/// Les callables d'IA passent par `GeminiService`, qui rend une
/// [GeminiCallableException] portant le même code.
class ErrorMessage {
  /// Titre court, affiché en gras.
  final String title;

  /// Ce que l'utilisateur peut faire, ou pourquoi il ne peut rien faire.
  final String advice;

  /// Vrai quand réessayer a une chance d'aboutir : réseau, indisponibilité,
  /// délai dépassé. Faux pour un refus de droits, qui ne changera pas en
  /// appuyant une deuxième fois.
  final bool retryable;

  const ErrorMessage({
    required this.title,
    required this.advice,
    required this.retryable,
  });
}

/// Le code d'erreur porté par l'exception, quel que soit le service Firebase.
///
/// Une [GeminiCallableException] venue de l'appel HTTP du web porte le code
/// en `resource_exhausted` : il est ramené à la forme du SDK.
String _codeOf(Object error) {
  if (error is FirebaseException) return error.code.toLowerCase();
  if (error is GeminiCallableException) {
    return error.code.toLowerCase().replaceAll('_', '-');
  }
  return '';
}

/// Certaines erreurs réseau ne portent pas de type commun entre le web et le
/// mobile (`SocketException` n'existe pas en web). On retombe sur le texte.
bool _looksLikeNetwork(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('socketexception') ||
      text.contains('failed host lookup') ||
      text.contains('network is unreachable') ||
      text.contains('clientexception') ||
      text.contains('connection refused') ||
      text.contains('connection closed');
}

/// Transforme n'importe quelle exception en message destiné à un lecteur.
ErrorMessage describeError(Object? error) {
  if (error == null) {
    return const ErrorMessage(
      title: 'Une erreur est survenue',
      advice: 'Réessayez dans un instant.',
      retryable: true,
    );
  }

  if (error is TimeoutException) {
    return const ErrorMessage(
      title: 'Le serveur met trop de temps à répondre',
      advice:
          'Le traitement est peut-être encore en cours. Réessayez dans une '
          'minute.',
      retryable: true,
    );
  }

  final code = _codeOf(error);

  if (code.contains('permission-denied') || code.contains('unauthorized')) {
    return const ErrorMessage(
      title: 'Accès refusé',
      advice:
          'Votre rôle ne permet pas de consulter ce contenu. Demandez à un '
          'administrateur du livre de vous ouvrir l\'accès.',
      retryable: false,
    );
  }

  if (code.contains('unauthenticated')) {
    return const ErrorMessage(
      title: 'Session expirée',
      advice: 'Déconnectez-vous puis reconnectez-vous pour continuer.',
      retryable: false,
    );
  }

  if (code.contains('not-found') || code.contains('object-not-found')) {
    return const ErrorMessage(
      title: 'Contenu introuvable',
      advice:
          'Cette recette ou cette page a peut-être été supprimée depuis que '
          'le lien a été partagé.',
      retryable: false,
    );
  }

  if (code.contains('unavailable') ||
      code.contains('network-request-failed') ||
      code.contains('deadline-exceeded') ||
      _looksLikeNetwork(error)) {
    return const ErrorMessage(
      title: 'Connexion perdue',
      // Rien sur la lecture hors ligne : la persistance Firestore est active
      // par défaut sur Android natif, et désactivée par défaut sur le web —
      // qui est la plateforme la plus utilisée, et la seule dont dispose un
      // iPhone. La phrase était donc fausse la moitié du temps, et fausse
      // précisément au moment où la panne survient.
      advice: 'Vérifiez votre connexion internet, puis réessayez.',
      retryable: true,
    );
  }

  // Fournisseur d'IA saturé : une callable d'IA qui rend `resource-exhausted`
  // sans `details` (`GeminiQuotaExceededError`, `toHttpsError`). Les autres
  // plafonds portent une raison (plafond du compte, d'une génération de
  // planning, des tickets) ou ont leur propre traduction (recherche web,
  // recherche de membres, groupes).
  if (error is GeminiCallableException &&
      code == 'resource-exhausted' &&
      error.details == null) {
    return const ErrorMessage(
      title: 'Service d\'IA saturé',
      advice: 'Réessayez plus tard.',
      retryable: true,
    );
  }

  if (code.contains('resource-exhausted') || code.contains('quota')) {
    return const ErrorMessage(
      title: 'Limite du jour atteinte',
      advice:
          'Le service a atteint sa limite pour aujourd\'hui. Réessayez plus '
          'tard.',
      retryable: true,
    );
  }

  if (code.contains('cancelled')) {
    return const ErrorMessage(
      title: 'Opération interrompue',
      advice: 'La demande a été annulée avant d\'aboutir. Réessayez.',
      retryable: true,
    );
  }

  return const ErrorMessage(
    title: 'Une erreur inattendue est survenue',
    advice: kUnexpectedErrorAdvice,
    retryable: true,
  );
}

/// Conseil d'une erreur inattendue. Il renvoie aux « Détails » de
/// `AppErrorState`, que seul un administrateur voit.
const kUnexpectedErrorAdvice =
    'Réessayez. Si le problème persiste, transmettez les détails '
    'techniques ci-dessous à un administrateur.';

/// Conseil d'une erreur inattendue pour un membre qui n'est pas
/// administrateur : il n'a pas de « Détails » à transmettre, il signale le
/// problème par un ticket (menu du compte › « Signaler ou proposer »).
const kReportProblemAdvice =
    'Si le problème persiste, signalez-le depuis le menu du compte.';

/// `details.scope` d'un refus du plafond d'IA du compte, posé par le serveur
/// (`AI_BUDGET_SCOPE`, `functions/src/callable/_callableErrors.ts`).
const kAiBudgetScope = 'ai_budget';

/// Raisons d'un refus du plafond d'IA dont le message, rédigé par le serveur
/// pour le membre, dit quand réessayer : plafond du jour en euros (`cost`) ou
/// en appels (`calls`), trop d'appels en cours (`concurrency`). Le plafond d'un
/// livre (`import`) n'arrive pas par une callable.
const _aiBudgetMessageReasons = {'cost', 'calls', 'concurrency'};

/// Le message du serveur quand [error] est un refus du plafond d'IA du
/// compte, ou `null`.
///
/// Reconnu au code `resource-exhausted`, à `details.scope` = [kAiBudgetScope]
/// et à `details.reason` = `cost`, `calls` ou `concurrency`. Le même code sert
/// au fournisseur d'IA saturé, qui ne porte pas de `details` (« Service d'IA
/// saturé », [describeError]). `details.reason` seul ne suffit pas : le
/// plafond d'une génération de planning porte aussi `reason: cost`, sans
/// `scope`.
String? aiBudgetRefusalMessage(Object? error) {
  if (error == null) return null;
  final Object? details;
  final String message;
  if (error is GeminiCallableException) {
    details = error.details;
    message = error.message;
  } else if (error is FirebaseFunctionsException) {
    details = error.details;
    message = error.message ?? '';
  } else {
    return null;
  }
  if (_codeOf(error) != 'resource-exhausted') return null;
  if (details is! Map) return null;
  if (details['scope'] != kAiBudgetScope) return null;
  if (!_aiBudgetMessageReasons.contains(details['reason'])) return null;
  final text = message.trim();
  return text.isEmpty ? null : text;
}

/// Version courte, pour un SnackBar où il n'y a pas la place d'expliquer.
String shortErrorMessage(Object? error) => describeError(error).title;

/// Le texte d'un échec, pour un SnackBar (`showFailureSnackBar` de
/// `context_extensions.dart`) ou le message d'erreur d'un écran : deux
/// phrases, ce qui n'a pas eu lieu ([what]) puis le titre de
/// [describeError]. Exemple : « Photo non enregistrée. Connexion perdue. »
///
/// Un [what] qui finit déjà par un point n'en reçoit pas un second. Le texte
/// brut de l'exception n'y figure jamais : il reste dans le rapport d'erreur.
///
/// Seule exception : un refus du plafond d'IA du compte
/// ([aiBudgetRefusalMessage]). Sa seconde phrase est le message du serveur,
/// écrit pour le membre, qui dit quand réessayer : « Recette non conçue.
/// Limite d'utilisation de l'IA atteinte pour aujourd'hui. Réessayez demain,
/// … ». Tout autre `resource-exhausted` garde le titre de [describeError].
String failureMessage(String what, Object? error) =>
    '${_sentence(what.trimRight())} '
    '${_sentence(aiBudgetRefusalMessage(error) ?? describeError(error).title)}';

/// Un refus de droits : règle Firestore ou Storage, ou callable
/// `permission-denied`.
bool isPermissionRefusal(Object? error) {
  if (error == null) return false;
  final code = _codeOf(error);
  return code.contains('permission-denied') || code.contains('unauthorized');
}

/// Refus d'un envoi de photo ou de couverture reçu en cours de session : le
/// compte n'est plus éditeur (tickets #162 et #163). Pas de « Réessayer » : le
/// rôle ne changera pas d'un appui à l'autre.
const kPhotoEditorOnlyRefusal =
    'Photo non envoyée. Ajouter des photos est réservé aux éditeurs.';

/// Refus d'une action d'IA reçu en cours de session : [what] garde le
/// préfixe de l'écran (« Recette non corrigée », « Recette non améliorée »).
String aiEditorOnlyRefusal(String what) =>
    '${_sentence(what.trimRight())} L\'IA est réservée aux éditeurs.';

/// Le message d'un échec d'envoi de photo : [kPhotoEditorOnlyRefusal] pour un
/// refus de droits, [failureMessage] sinon.
String photoFailureMessage(String what, Object? error) =>
    isPermissionRefusal(error)
    ? kPhotoEditorOnlyRefusal
    : failureMessage(what, error);

/// Le message d'un échec d'action d'IA : [aiEditorOnlyRefusal] pour un refus
/// de droits, [failureMessage] sinon.
String aiFailureMessage(String what, Object? error) =>
    isPermissionRefusal(error)
    ? aiEditorOnlyRefusal(what)
    : failureMessage(what, error);

/// Termine [text] par un point, sauf s'il finit déjà par une ponctuation.
String _sentence(String text) {
  const endings = ['.', '!', '?', '…'];
  return endings.any(text.endsWith) ? text : '$text.';
}
