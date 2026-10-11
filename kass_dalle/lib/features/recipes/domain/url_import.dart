/// Import d'une recette depuis un lien : ce que la callable rend.
///
/// Les issues attendues — adresse mal formée, refusée, déjà importée, plafond
/// atteint — sont des réponses du serveur, pas des erreurs : la boîte
/// « Importer depuis un lien » les affiche sans rapport d'erreur.
library;

/// Issue d'une demande d'import (`importRecipeFromUrlFn`).
enum UrlImportStatus {
  /// Le job est créé : la recette arrivera dans « Brouillons & Traitements ».
  queued,

  /// Ce n'est pas un lien web (http ou https).
  invalidUrl,

  /// Lien refusé : adresse non publique, hôte interne, nom introuvable.
  refused,

  /// La même page est déjà dans les recettes du compte.
  duplicate,

  /// Le plafond du jour est atteint.
  quotaExceeded,
}

class UrlImportResult {
  const UrlImportResult({
    required this.status,
    this.jobId,
    this.recipeId,
    this.titre,
    this.limit,
    this.remaining,
  });

  final UrlImportStatus status;
  final String? jobId;

  /// Recette déjà importée, pour [UrlImportStatus.duplicate].
  final String? recipeId;
  final String? titre;

  /// Plafond du jour et imports restants, quand le serveur les rend.
  final int? limit;
  final int? remaining;

  factory UrlImportResult.fromMap(Map<String, dynamic> map) {
    final status = switch (map['status']) {
      'queued' => UrlImportStatus.queued,
      'invalid_url' => UrlImportStatus.invalidUrl,
      'duplicate' => UrlImportStatus.duplicate,
      'quota_exceeded' => UrlImportStatus.quotaExceeded,
      _ => UrlImportStatus.refused,
    };
    return UrlImportResult(
      status: status,
      jobId: map['jobId'] as String?,
      recipeId: map['recipeId'] as String?,
      titre: map['titre'] as String?,
      limit: (map['limit'] as num?)?.toInt(),
      remaining: (map['remaining'] as num?)?.toInt(),
    );
  }
}

/// Compteur du jour (`getUrlImportQuotaFn`).
class UrlImportQuota {
  const UrlImportQuota({
    required this.limit,
    required this.used,
    required this.remaining,
  });

  final int limit;
  final int used;
  final int remaining;

  factory UrlImportQuota.fromMap(Map<String, dynamic> map) => UrlImportQuota(
    limit: (map['limit'] as num?)?.toInt() ?? 0,
    used: (map['used'] as num?)?.toInt() ?? 0,
    remaining: (map['remaining'] as num?)?.toInt() ?? 0,
  );
}

/// Contrôle local avant tout appel : un lien web, http ou https, avec un hôte.
///
/// Le serveur refait le contrôle complet ; celui-ci évite un aller-retour pour
/// une saisie qui n'est pas une adresse.
bool looksLikeWebLink(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.length > 2048) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  return (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
}

/// Ponctuation collée à la fin d'une adresse dans un texte : « (voir
/// https://site.fr/recette). » ne garde que l'adresse.
final _trailingPunctuation = RegExp(r'''[.,;:!?)\]}»"'…]+$''');

/// La première adresse web (http ou https) trouvée dans [text], ou `null`.
///
/// Un partage depuis un navigateur envoie souvent « Titre de la page
/// https://… » ; le presse-papiers peut contenir une phrase entière.
Uri? firstWebLink(String? text) {
  if (text == null || text.isEmpty) return null;
  for (final m in RegExp(
    r'https?://[^\s<>"]+',
    caseSensitive: false,
  ).allMatches(text)) {
    final candidate = m.group(0)!.replaceAll(_trailingPunctuation, '');
    if (looksLikeWebLink(candidate)) return Uri.parse(candidate);
  }
  return null;
}

/// Une adresse lisible sur une ligne : le domaine sans « www. », puis le
/// début du chemin, coupé à [maxLength] caractères avec « … ».
///
/// `https://www.marmiton.org/recettes/blanquette-de-veau.aspx` donne
/// « marmiton.org/recettes/blanq… ».
String shortLinkLabel(Uri uri, {int maxLength = 27}) {
  final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final full = '$host$path';
  return full.length <= maxLength ? full : '${full.substring(0, maxLength)}…';
}

/// Ce que l'application fait d'un texte reçu par « Partager vers
/// Kass'Dalle ».
enum SharedTextOutcome {
  /// Éditeur ou administrateur, une adresse web : la boîte d'import s'ouvre,
  /// adresse posée.
  import,

  /// Lecteur : l'import lui est fermé, quel que soit le texte.
  editorsOnly,

  /// Éditeur ou administrateur, aucune adresse web dans le texte.
  noWebLink,
}

/// Décide du sort d'un partage reçu. [url] n'est rempli que pour
/// [SharedTextOutcome.import].
({SharedTextOutcome outcome, Uri? url}) resolveSharedText(
  String text, {
  required bool canEdit,
}) {
  if (!canEdit) return (outcome: SharedTextOutcome.editorsOnly, url: null);
  final url = firstWebLink(text);
  if (url == null) return (outcome: SharedTextOutcome.noWebLink, url: null);
  return (outcome: SharedTextOutcome.import, url: url);
}
