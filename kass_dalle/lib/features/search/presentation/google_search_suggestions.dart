import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win;

import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/platform_utils.dart';
import 'google_suggestions_frame.dart';
import 'web_page_opener.dart';

/// Hauteur du bloc « Suggestions de recherche » de Google.
const double googleSuggestionsHeight = 56;

/// Le document affiché : le bloc de Google tel quel, dans une page minimale.
///
/// Rien du bloc n'est modifié. La page ajoute la mise à l'échelle mobile,
/// `<base target="_blank">` pour qu'un lien s'ouvre hors du cadre, et une
/// politique de sécurité `script-src 'none'` : aucun script ne s'exécute dans
/// le document, y compris là où la vue ne permet pas de couper JavaScript
/// (WebView2 sous Windows).
String wrapGoogleSuggestions(String html) =>
    '<!DOCTYPE html><html><head><meta charset="utf-8">'
    '<meta http-equiv="Content-Security-Policy" content="script-src \'none\'">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<base target="_blank"></head>'
    '<body style="margin:0">$html</body></html>';

/// Comment le bloc s'affiche sur une plateforme.
enum GoogleSuggestionsMode {
  /// `iframe` `srcdoc` sans script.
  webFrame,

  /// `webview_flutter` : Android, iOS, macOS.
  webView,

  /// `webview_windows` (WebView2), avec repli en puces si WebView2 manque.
  windowsWebView,

  /// Puces des requêtes de Google : Linux.
  chips,
}

/// Le mode d'affichage pour le système [platform] ; `null` : le web.
GoogleSuggestionsMode googleSuggestionsModeFor(TargetPlatform? platform) {
  return switch (platform) {
    null => GoogleSuggestionsMode.webFrame,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => GoogleSuggestionsMode.webView,
    TargetPlatform.windows => GoogleSuggestionsMode.windowsWebView,
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => GoogleSuggestionsMode.chips,
  };
}

/// Le bloc « Suggestions de recherche » que Google impose d'afficher avec les
/// résultats d'une recherche ancrée, tel qu'il le rend.
///
/// - Web : une `iframe` `srcdoc` sans script (voir
///   `google_suggestions_frame_web.dart`).
/// - Android, iOS, macOS : `webview_flutter`, JavaScript coupé ; toute
///   navigation est bloquée dans la vue et l'adresse (https seulement)
///   s'ouvre dans le navigateur intégré (voir [openWebPage]).
/// - Windows : `webview_windows` (WebView2). Le paquet n'a ni réglage
///   JavaScript ni délégué de navigation : la page interdit les scripts par
///   sa politique de sécurité, et une navigation est défaite dès qu'elle est
///   signalée — le bloc est rechargé, l'adresse ouverte dans le navigateur.
///   Sans WebView2 installé, repli en puces.
/// - Linux : pas de WebView. Les requêtes lancées par Google ([queries])
///   s'affichent en puces qui ouvrent Google.
class GoogleSearchSuggestions extends StatelessWidget {
  final String html;
  final List<String> queries;

  const GoogleSearchSuggestions({
    super.key,
    required this.html,
    required this.queries,
  });

  @override
  Widget build(BuildContext context) {
    final document = wrapGoogleSuggestions(html);
    return switch (googleSuggestionsModeFor(PlatformUtils.hostPlatform)) {
      GoogleSuggestionsMode.webFrame => _framed(
        buildGoogleSuggestionsFrame(document),
      ),
      GoogleSuggestionsMode.webView => _framed(
        _SuggestionsWebView(document: document),
      ),
      GoogleSuggestionsMode.windowsWebView => _WindowsSuggestionsView(
        document: document,
        queries: queries,
      ),
      GoogleSuggestionsMode.chips => GoogleSuggestionChips(queries: queries),
    };
  }
}

/// Le cadre d'une vue embarquée : hauteur fixe, libellé pour les lecteurs
/// d'écran.
Widget _framed(Widget view) => Semantics(
  container: true,
  label: 'Suggestions de recherche Google',
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: SizedBox(height: googleSuggestionsHeight, child: view),
  ),
);

/// Ouvre une adresse https, et rien d'autre : navigateur intégré sur
/// téléphone, navigateur ailleurs (voir [openWebPage]).
Future<void> _openPage(Uri uri, String trigger) async {
  if (uri.scheme != 'https') return;
  try {
    await openWebPage(uri);
  } catch (error, stackTrace) {
    reportUnexpectedError(
      feature: 'search.web.suggestions',
      error: error,
      stackTrace: stackTrace,
      context: {'trigger': trigger, 'host': uri.host},
    );
  }
}

/// Laisse passer une ouverture externe, puis aucune tant que les appels se
/// suivent à moins de [window].
///
/// Sous Windows, un lien suivi dans WebView2 signale chaque étape de ses
/// redirections (`google.com` → `consent.google.com` → `/search`) : sans ce
/// filtre, un appui ouvrirait un onglet par étape.
class ExternalOpenGate {
  final Duration window;
  final DateTime Function() _now;
  DateTime? _lastOpen;

  ExternalOpenGate({
    this.window = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Vrai si l'ouverture peut partir. Chaque appel, refusé ou non, repousse
  /// la fenêtre : une chaîne de redirections lentes n'ouvre qu'un onglet.
  bool tryOpen() {
    final now = _now();
    final last = _lastOpen;
    _lastOpen = now;
    if (last != null && now.difference(last) < window) return false;
    return true;
  }
}

/// Vrai pour le chargement du document lui-même (`about:`, `data:`).
bool _isOwnDocument(Uri? uri) =>
    uri == null || uri.scheme == 'about' || uri.scheme == 'data';

class _SuggestionsWebView extends StatefulWidget {
  final String document;
  const _SuggestionsWebView({required this.document});

  @override
  State<_SuggestionsWebView> createState() => _SuggestionsWebViewState();
}

class _SuggestionsWebViewState extends State<_SuggestionsWebView> {
  final WebViewController _controller = WebViewController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.disabled);
      // WKWebView sous macOS n'a pas de fond réglable : le canal n'existe pas.
      if (PlatformUtils.hostPlatform != TargetPlatform.macOS) {
        await _controller.setBackgroundColor(Colors.transparent);
      }
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (_isOwnDocument(uri)) return NavigationDecision.navigate;
            // Toute autre navigation quitte le bloc pour le navigateur.
            unawaited(_openPage(uri!, 'webview'));
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) => reportUnexpectedError(
            feature: 'search.web.suggestions',
            error: error.description,
            context: {'code': error.errorCode, 'type': '${error.errorType}'},
          ),
        ),
      );
      await _controller.loadHtmlString(widget.document);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'search.web.suggestions',
        error: error,
        stackTrace: stackTrace,
        context: const {'trigger': 'load'},
      );
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}

/// Windows : WebView2 par `webview_windows`, repli en puces sans WebView2.
class _WindowsSuggestionsView extends StatefulWidget {
  final String document;
  final List<String> queries;

  const _WindowsSuggestionsView({
    required this.document,
    required this.queries,
  });

  @override
  State<_WindowsSuggestionsView> createState() =>
      _WindowsSuggestionsViewState();
}

class _WindowsSuggestionsViewState extends State<_WindowsSuggestionsView> {
  /// WebView2 absent : signalé une fois par session, pas à chaque recherche.
  static bool _runtimeMissingReported = false;

  final win.WebviewController _controller = win.WebviewController();
  final ExternalOpenGate _openGate = ExternalOpenGate();
  StreamSubscription<String>? _urlSubscription;
  bool _initStarted = false;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final version = await win.WebviewController.getWebViewVersion();
      if (version == null) {
        if (!_runtimeMissingReported) {
          _runtimeMissingReported = true;
          reportUnexpectedError(
            feature: 'search.web.suggestions',
            error: StateError('WebView2 Runtime absent'),
            context: const {'trigger': 'windows_runtime', 'fallback': 'chips'},
          );
        }
        _fallBack();
        return;
      }
      _initStarted = true;
      await _controller.initialize();
      // Une fenêtre surgissante (`<base target="_blank">`) s'ouvre dans la
      // vue : l'adresse arrive par `url`, où elle est défaite.
      await _controller.setPopupWindowPolicy(
        win.WebviewPopupWindowPolicy.sameWindow,
      );
      await _controller.setBackgroundColor(Colors.transparent);
      _urlSubscription = _controller.url.listen(_onUrl);
      await _controller.loadStringContent(widget.document);
      if (mounted) setState(() => _ready = true);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'search.web.suggestions',
        error: error,
        stackTrace: stackTrace,
        context: const {'trigger': 'windows_init', 'fallback': 'chips'},
      );
      _fallBack();
    }
  }

  void _fallBack() {
    if (mounted) setState(() => _failed = true);
  }

  /// Une navigation hors du document : le bloc est rechargé, l'adresse part
  /// dans le navigateur. Les étapes de redirection qui suivent, dans la
  /// seconde, rechargent encore le bloc sans ouvrir d'autre onglet.
  void _onUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (_isOwnDocument(uri)) return;
    unawaited(_reload());
    if (!_openGate.tryOpen()) return;
    unawaited(_openPage(uri!, 'webview_windows'));
  }

  Future<void> _reload() async {
    try {
      await _controller.loadStringContent(widget.document);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'search.web.suggestions',
        error: error,
        stackTrace: stackTrace,
        context: const {'trigger': 'windows_reload'},
      );
    }
  }

  @override
  void dispose() {
    unawaited(_urlSubscription?.cancel());
    // `dispose` du contrôleur attend `initialize` : il n'est appelé que si
    // l'initialisation a commencé.
    if (_initStarted) {
      unawaited(
        _controller.dispose().catchError((Object error, StackTrace stack) {
          reportUnexpectedError(
            feature: 'search.web.suggestions',
            error: error,
            stackTrace: stack,
            context: const {'trigger': 'windows_dispose'},
          );
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return GoogleSuggestionChips(queries: widget.queries);
    // Rien tant que WebView2 s'initialise : pas de bande vide de 56 px.
    if (!_ready) return const SizedBox.shrink();
    return _framed(win.Webview(_controller));
  }
}

/// Repli sans WebView : une puce par requête lancée par Google.
///
/// Rien du tout, marges comprises, quand Google n'a rendu aucune requête.
class GoogleSuggestionChips extends StatelessWidget {
  final List<String> queries;
  const GoogleSuggestionChips({super.key, required this.queries});

  @override
  Widget build(BuildContext context) {
    if (queries.isEmpty) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: 'Suggestions de recherche Google',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final q in queries)
              ActionChip(
                avatar: const Icon(Icons.search, size: AppIconSize.inline),
                label: Text(q),
                tooltip: 'Chercher « $q » sur Google',
                onPressed: () => unawaited(
                  _openPage(
                    Uri.https('www.google.com', '/search', {'q': q}),
                    'chip',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
