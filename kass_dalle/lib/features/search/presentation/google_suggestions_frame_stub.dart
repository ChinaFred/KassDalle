import 'package:flutter/widgets.dart';

/// Hors du web : aucune `iframe`. Jamais appelé : `GoogleSearchSuggestions`
/// ne s'en sert qu'en mode `webFrame`, sur le web.
Widget buildGoogleSuggestionsFrame(String document) => const SizedBox.shrink();
