import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Types de vue déjà enregistrés : un par document, enregistré une fois.
final Set<String> _registered = {};

/// Le bloc de Google dans une `iframe` `srcdoc`, sans script.
///
/// `sandbox="allow-popups allow-popups-to-escape-sandbox"` : le document ne
/// peut ni exécuter de script, ni lire l'application, ni naviguer la page qui
/// le porte. Un clic sur une suggestion ouvre Google dans un nouvel onglet
/// (`<base target="_blank">` posé par `wrapGoogleSuggestions`).
Widget buildGoogleSuggestionsFrame(String document) {
  final viewType = 'kassdalle-google-suggestions-${document.hashCode}';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final frame =
          web.document.createElement('iframe') as web.HTMLIFrameElement
            ..setAttribute('srcdoc', document)
            ..setAttribute(
              'sandbox',
              'allow-popups allow-popups-to-escape-sandbox',
            )
            ..setAttribute('referrerpolicy', 'no-referrer')
            ..setAttribute('title', 'Suggestions de recherche Google');
      frame.style
        ..border = 'none'
        ..width = '100%'
        ..height = '100%';
      return frame;
    });
  }
  return HtmlElementView(viewType: viewType);
}
