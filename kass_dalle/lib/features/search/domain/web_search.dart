/// « Chercher sur le web » : ce que rend `searchWebRecipesFn`, et l'état de la
/// section « Sur le web » de l'Explorer.
///
/// Rien n'est stocké : la recherche vit en mémoire, avec l'écran. Le cache
/// partagé est côté serveur, jamais lu par le client.
library;

/// Une page de recette trouvée sur le web. Son adresse est en https.
///
/// Aucune vignette : la carte montre une icône. Une image tierce chargée par
/// l'appareil donnerait l'adresse IP du lecteur au site, et afficherait une
/// image que la modération n'a pas vue.
class WebRecipeResult {
  final Uri url;
  final String title;

  /// Le domaine réel de la page, sans « www. ».
  final String site;
  final String? snippet;

  /// Vrai quand la page décrit sa recette en `schema.org/Recipe` complet :
  /// l'import la projette sans relecture par le modèle.
  final bool directImport;

  const WebRecipeResult({
    required this.url,
    required this.title,
    required this.site,
    this.snippet,
    this.directImport = false,
  });

  /// Lit une carte du serveur ; `null` si son adresse n'est pas en https.
  ///
  /// Le serveur ne rend que de l'https. Le client le revérifie : une adresse
  /// `javascript:` ou `http:` ne doit jamais atteindre `launchUrl`.
  static WebRecipeResult? fromMap(Map<String, dynamic> map) {
    final url = httpsUriOrNull(map['url']);
    if (url == null) return null;
    final title = (map['title'] as String? ?? '').trim();
    final site = (map['site'] as String? ?? '').trim();
    final snippet = (map['snippet'] as String? ?? '').trim();
    return WebRecipeResult(
      url: url,
      title: title.isEmpty ? url.host : title,
      site: site.isEmpty ? url.host.replaceFirst(RegExp(r'^www\.'), '') : site,
      snippet: snippet.isEmpty ? null : snippet,
      directImport: map['directImport'] == true,
    );
  }

  /// Ce que lit un lecteur d'écran : « titre, site[, import direct] ». Le
  /// badge n'est annoncé qu'à qui peut importer.
  String semanticLabel({required bool canImport}) =>
      '$title, $site${canImport && directImport ? ', import direct' : ''}';
}

/// Une adresse https absolue, ou `null`.
Uri? httpsUriOrNull(Object? raw) {
  if (raw is! String) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

/// La réponse de `searchWebRecipesFn`.
class WebSearchResponse {
  final String query;
  final List<WebRecipeResult> results;

  /// Bloc « Suggestions de recherche » de Google, affiché tel quel.
  final String? searchEntryPointHtml;
  final List<String> webSearchQueries;

  /// Servie par le cache partagé : non décomptée.
  final bool fromCache;
  final int? limit;
  final int? remaining;

  const WebSearchResponse({
    required this.query,
    required this.results,
    this.searchEntryPointHtml,
    this.webSearchQueries = const [],
    this.fromCache = false,
    this.limit,
    this.remaining,
  });

  factory WebSearchResponse.fromMap(Map<String, dynamic> map) {
    final html = (map['searchEntryPointHtml'] as String? ?? '').trim();
    return WebSearchResponse(
      query: map['query'] as String? ?? '',
      results: [
        for (final raw in map['results'] as List? ?? const [])
          if (raw is Map)
            ?WebRecipeResult.fromMap(Map<String, dynamic>.from(raw)),
      ],
      searchEntryPointHtml: html.isEmpty ? null : html,
      webSearchQueries: [
        for (final q in map['webSearchQueries'] as List? ?? const [])
          if (q is String && q.trim().isNotEmpty) q.trim(),
      ],
      fromCache: map['fromCache'] == true,
      limit: (map['limit'] as num?)?.toInt(),
      remaining: (map['remaining'] as num?)?.toInt(),
    );
  }
}

/// Le plafond du jour est atteint. [limit] vient du serveur ; `null` s'il ne
/// l'a pas dit.
class WebSearchQuotaExceeded implements Exception {
  final int? limit;
  const WebSearchQuotaExceeded({this.limit});

  @override
  String toString() => 'WebSearchQuotaExceeded(limit: $limit)';
}

/// Raison portée par le refus de plafond du serveur.
const webSearchQuotaReason = 'web_search_daily_quota';

/// Raison portée par le refus du plafond de dépense d'IA du jour.
const webSearchAiBudgetReason = 'ai_daily_budget';

/// Raison portée par une panne du moteur de recherche, côté serveur.
const webSearchEngineReason = 'web_search_engine';

/// Raison portée par le refus d'une requête (vide, trop longue).
const webSearchQueryReason = 'web_search_query';

/// Le plafond de dépense d'IA du jour est atteint : ce n'est pas une panne,
/// rien à réessayer avant demain.
class WebSearchAiBudgetExceeded implements Exception {
  final String message;
  const WebSearchAiBudgetExceeded(this.message);

  @override
  String toString() => 'WebSearchAiBudgetExceeded: $message';
}

/// Le serveur refuse la requête (vide, trop longue). [message] est écrit pour
/// l'utilisateur ; la même requête serait refusée de nouveau.
class WebSearchQueryRefused implements Exception {
  final String message;
  const WebSearchQueryRefused(this.message);

  @override
  String toString() => 'WebSearchQueryRefused: $message';
}

/// Le moteur de recherche est en panne ou saturé, côté serveur. [message] est
/// écrit pour l'utilisateur ; réessayer peut aboutir.
class WebSearchEngineUnavailable implements Exception {
  final String message;
  const WebSearchEngineUnavailable(this.message);

  @override
  String toString() => 'WebSearchEngineUnavailable: $message';
}

/// État de la section « Sur le web ».
///
/// [remaining] suit les recherches restantes du jour, connues après la
/// première réponse : `null` tant que le serveur ne l'a pas dit.
sealed class WebSearchState {
  final int? remaining;
  const WebSearchState({this.remaining});
}

class WebSearchIdle extends WebSearchState {
  const WebSearchIdle({super.remaining});
}

class WebSearchLoading extends WebSearchState {
  final String query;
  const WebSearchLoading(this.query, {super.remaining});
}

class WebSearchSuccess extends WebSearchState {
  final WebSearchResponse response;
  WebSearchSuccess(this.response) : super(remaining: response.remaining);

  String get query => response.query;
}

class WebSearchError extends WebSearchState {
  final String query;
  final Object error;
  const WebSearchError(this.query, this.error, {super.remaining});
}

class WebSearchQuotaReached extends WebSearchState {
  final String query;
  final int? limit;
  const WebSearchQuotaReached(this.query, {this.limit}) : super(remaining: 0);
}

/// Plafond de dépense d'IA du jour atteint. Le nombre de recherches restantes
/// ne change pas : une recherche déjà en cache peut encore servir.
class WebSearchBudgetReached extends WebSearchState {
  final String query;
  const WebSearchBudgetReached(this.query, {super.remaining});
}

/// La requête de la section, quel que soit son état ; `null` au repos.
String? webSearchQueryOf(WebSearchState state) => switch (state) {
  WebSearchIdle() => null,
  WebSearchLoading(:final query) => query,
  WebSearchSuccess(:final query) => query,
  WebSearchError(:final query) => query,
  WebSearchQuotaReached(:final query) => query,
  WebSearchBudgetReached(:final query) => query,
};

/// « Il vous reste N recherches aujourd'hui. », accordé ; `null` si N est
/// inconnu.
String? remainingSearchesLine(int? remaining) {
  if (remaining == null) return null;
  return switch (remaining) {
    0 => 'Il ne vous reste aucune recherche aujourd\'hui.',
    1 => 'Il vous reste 1 recherche aujourd\'hui.',
    _ => 'Il vous reste $remaining recherches aujourd\'hui.',
  };
}

/// « N pages trouvées », accordé.
String webPagesFoundLabel(int count) => switch (count) {
  0 => 'Aucune page trouvée',
  1 => '1 page trouvée',
  _ => '$count pages trouvées',
};
