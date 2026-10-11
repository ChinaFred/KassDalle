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
