import 'error_message.dart';

/// Politique de réessai des providers Riverpod.
///
/// Riverpod 3 réessaie **par défaut** dix fois toute exception levée par un
/// provider, en backoff exponentiel de 200 ms plafonné à 6,4 s. Tant qu'il
/// réessaie, l'état reste `AsyncLoading` : `AsyncValue.when` appelle donc
/// `loading`, pas `error`. Concrètement, une coupure réseau produisait environ
/// **38 secondes de roue qui tourne** avant que le message « Connexion perdue »
/// et son bouton Réessayer apparaissent — et un refus de droits, qui
/// n'aboutira jamais, subissait les dix tentatives lui aussi.
///
/// La règle appliquée ici :
///
/// * une erreur que réessayer ne corrigera pas (droits, session, document
///   absent) est rendue **immédiatement** ;
/// * une erreur transitoire (réseau, indisponibilité, délai) a droit à deux
///   tentatives rapprochées, puis la main repasse à l'utilisateur via le
///   bouton Réessayer.
///
/// Deux tentatives couvrent le micro-incident réseau sans transformer une
/// panne en attente aveugle : au-delà d'une seconde et demie, mieux vaut dire
/// ce qui se passe que continuer à faire tourner une roue.
Duration? appProviderRetry(int retryCount, Object error) {
  if (!describeError(error).retryable) return null;
  if (retryCount >= _delays.length) return null;
  return _delays[retryCount];
}

/// Délais explicites plutôt qu'une formule : la question posée est « combien de
/// temps la famille regarde un écran muet », et une liste y répond directement.
/// Total : une seconde.
const _delays = [Duration(milliseconds: 250), Duration(milliseconds: 750)];
