import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

import 'error_report_service.dart';

/// Clé de site reCAPTCHA Enterprise, pour l'attestation du client **web**.
///
/// Publique par nature : une clé de site s'affiche dans la page, comme celle de
/// n'importe quel formulaire protégé par reCAPTCHA. Elle n'a donc rien à faire
/// dans Secret Manager, et la poser ici évite d'ajouter un `--dart-define` au
/// script de déploiement pour une donnée que le navigateur reçoit de toute façon.
///
/// Tant qu'elle est vide, **l'attestation web n'est pas activée** : la clé se
/// crée dans la console Firebase (App Check → application web → reCAPTCHA
/// Enterprise), et elle ne peut pas être devinée depuis le code.
const String kAppCheckRecaptchaSiteKey = '';

/// Vrai si la plateforme courante sait produire une **vraie** attestation.
///
/// Web, Android, iOS et macOS ont un fournisseur d'attestation réel : reCAPTCHA
/// Enterprise, Play Integrity, DeviceCheck.
///
/// Windows en est exclu délibérément. Le plugin couvre bien cette plateforme,
/// mais avec un seul fournisseur : `WindowsDebugProvider`, qui exige un jeton de
/// débogage inscrit dans la console. Un tel jeton est un secret partagé — dans
/// un binaire distribué, quiconque l'extrait contourne App Check —, et la
/// documentation du plugin dit elle-même de ne pas l'embarquer en production.
/// Le client `Release/desktop` reste donc non attesté : c'est le fait dont
/// dépend le choix du mode `enforce` côté serveur. Le jour où l'on voudra
/// l'attester, la voie propre est la variable d'environnement
/// `APP_CHECK_DEBUG_TOKEN` posée sur la machine, jamais une constante ici.
bool get appCheckSupportedHere {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

/// Active App Check quand la plateforme le permet.
///
/// Ne relance jamais : une attestation impossible ne doit pas empêcher
/// l'application de démarrer. C'est la politique serveur — `off`, `monitor` ou
/// `enforce` — qui décide des conséquences d'un appel non attesté, et elle est
/// modifiable en une minute. Un client qui refuserait de démarrer, non.
///
/// L'échec est rapporté : un jeton absent se traduit sinon par des refus côté
/// serveur dont la cause serait invisible d'ici.
Future<void> activateAppCheck({ErrorReportService? errorReportService}) async {
  if (!appCheckSupportedHere) {
    debugPrint(
      '[AppCheck] plateforme sans fournisseur d\'attestation — activation ignorée',
    );
    return;
  }

  if (kIsWeb && kAppCheckRecaptchaSiteKey.isEmpty) {
    // Silence volontairement bruyant côté journal : sans clé, tous les appels
    // web partiront non attestés, et personne ne saurait pourquoi.
    debugPrint(
      '[AppCheck] clé reCAPTCHA absente — attestation web non activée. '
      'Voir kAppCheckRecaptchaSiteKey.',
    );
    return;
  }

  try {
    await FirebaseAppCheck.instance.activate(
      // reCAPTCHA Enterprise : la variante recommandée aujourd'hui, et la seule
      // que la console propose pour une nouvelle application web.
      providerWeb: kIsWeb
          ? ReCaptchaEnterpriseProvider(kAppCheckRecaptchaSiteKey)
          : null,
      providerAndroid: const AndroidPlayIntegrityProvider(),
      providerApple: const AppleDeviceCheckProvider(),
    );
    debugPrint('[AppCheck] attestation activée');
  } catch (error, stackTrace) {
    await (errorReportService ?? ErrorReportService()).reportError(
      feature: 'app_check_activate',
      error: error,
      stackTrace: stackTrace,
      context: {
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'has_site_key': kAppCheckRecaptchaSiteKey.isNotEmpty.toString(),
      },
    );
  }
}
