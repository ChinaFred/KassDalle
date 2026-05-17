// ignore_for_file: deprecated_member_use
import 'dart:html' as html;

Future<void> clearBrowserCacheAndReload() async {
  try {
    // Désenregistrer les service workers
    final sw = html.window.navigator.serviceWorker;
    if (sw != null) {
      final registrations = await sw.getRegistrations();
      for (final reg in registrations) {
        await reg.unregister();
      }
    }

    // Vider les caches du Cache API (service worker cache)
    final cacheStorage = html.window.caches;
    if (cacheStorage != null) {
      final keys = await cacheStorage.keys();
      for (final key in keys) {
        await cacheStorage.delete(key);
      }
    }

    // Vider localStorage et sessionStorage
    html.window.localStorage.clear();
    html.window.sessionStorage.clear();
  } finally {
    // Rechargement forcé (contourne le cache navigateur)
    html.window.location.reload();
  }
}
