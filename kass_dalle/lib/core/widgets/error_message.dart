import 'dart:async';

import 'package:firebase_core/firebase_core.dart';

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
String _codeOf(Object error) {
  if (error is FirebaseException) return error.code.toLowerCase();
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

  if (code.contains('resource-exhausted') || code.contains('quota')) {
    return const ErrorMessage(
      title: 'Quota atteint',
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
    advice:
        'Réessayez. Si le problème persiste, transmettez les détails '
        'techniques ci-dessous à un administrateur.',
    retryable: true,
  );
}

/// Version courte, pour un SnackBar où il n'y a pas la place d'expliquer.
String shortErrorMessage(Object? error) => describeError(error).title;
