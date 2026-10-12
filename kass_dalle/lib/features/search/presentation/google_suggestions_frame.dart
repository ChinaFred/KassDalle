// Le bloc « Suggestions de recherche » de Google, sur le web : une `iframe`
// `srcdoc` sans script. Ailleurs, le stub ne rend rien : l'appelant choisit
// la vue native (WebView) ou le repli.
export 'google_suggestions_frame_stub.dart'
    if (dart.library.js_interop) 'google_suggestions_frame_web.dart';
