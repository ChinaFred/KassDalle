// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;
import 'dart:js_util' as js_util;

/// Retourne true si Chrome a capturé un événement beforeinstallprompt
/// (l'app n'est pas encore installée et peut être ajoutée à l'écran d'accueil).
bool isPwaInstallAvailable() {
  return js.context['_pwaPrompt'] != null;
}

/// Déclenche le prompt PWA natif de Chrome.
/// Chrome affiche sa propre dialog "Ajouter à l'écran d'accueil".
/// Retourne true si l'utilisateur a accepté, false s'il a refusé ou en cas d'erreur.
Future<bool> triggerPwaInstall() async {
  final prompt = js.context['_pwaPrompt'] as js.JsObject?;
  if (prompt == null) return false;
  try {
    // Déclenche le prompt natif Chrome
    prompt.callMethod('prompt');

    // Attend la réponse de l'utilisateur (userChoice est une Promise)
    final outcomePromise = prompt['userChoice'];
    final outcome = await js_util.promiseToFuture<js.JsObject>(outcomePromise as Object);

    // Réinitialise : le prompt ne peut être affiché qu'une seule fois
    js.context['_pwaPrompt'] = null;
    return outcome['outcome'] == 'accepted';
  } catch (_) {
    return false;
  }
}
