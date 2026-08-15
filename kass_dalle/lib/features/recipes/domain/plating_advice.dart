/// Conseil de dressage produit par l'IA pour une recette précise.
///
/// Stocké sur le document recette (`plating_advice`) : il coûte un appel de
/// modèle, il est le même pour tous les lecteurs, et l'onglet ne doit pas le
/// repayer à chaque ouverture.
library;

/// Modèle qui fabrique les visuels de montage, côté Functions.
///
/// Répété ici pour une seule raison : annoncer le coût d'une série de visuels
/// avant de la lancer. Toute divergence avec `GEMINI_IMAGE_MODEL`
/// (`functions/src/config.ts`) ferait mentir ce chiffre sans rien casser
/// d'autre.
const String kPlatingImageModel = 'gemini-3.1-flash-lite-image';

enum PlatingComplexity {
  simple,
  intermediaire,
  complexe;

  String get label => switch (this) {
    PlatingComplexity.simple => 'Dressage simple',
    PlatingComplexity.intermediaire => 'Dressage à composer',
    PlatingComplexity.complexe => 'Montage complexe',
  };
}

class PlatingStep {
  final String titre;
  final String geste;
  final List<String> elements;

  /// Description du visuel à générer, ou null si l'étape se passe d'image.
  final String? imagePrompt;

  /// URL du visuel déjà généré, ou null.
  final String? imageUrl;

  const PlatingStep({
    required this.titre,
    required this.geste,
    this.elements = const [],
    this.imagePrompt,
    this.imageUrl,
  });

  /// Toute étape peut être illustrée tant qu'elle ne l'est pas.
  ///
  /// La restriction précédente — seules les étapes portant une description
  /// visuelle — privait d'image les dernières étapes, celles où le dressage se
  /// joue vraiment.
  bool get canGenerateImage => imageUrl == null;

  factory PlatingStep.fromMap(Map<String, dynamic> data) {
    return PlatingStep(
      titre: (data['titre'] as String?)?.trim() ?? '',
      geste: (data['geste'] as String?)?.trim() ?? '',
      elements: (data['elements'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      imagePrompt: _nullIfBlank(data['image_prompt'] as String?),
      imageUrl: _nullIfBlank(data['image_url'] as String?),
    );
  }

  PlatingStep copyWith({String? imageUrl}) {
    return PlatingStep(
      titre: titre,
      geste: geste,
      elements: elements,
      imagePrompt: imagePrompt,
      imageUrl: imageUrl ?? this.imageUrl,
    );
  }

  /// L'étape sans son visuel — `copyWith` ne peut pas rendre un champ nul.
  PlatingStep withoutImage() {
    return PlatingStep(
      titre: titre,
      geste: geste,
      elements: elements,
      imagePrompt: imagePrompt,
    );
  }
}

class PlatingAdvice {
  final PlatingComplexity complexite;
  final String resume;
  final String contenant;
  final List<PlatingStep> etapes;
  final List<String> pieges;
  final List<String> derniereMinute;

  /// Contrainte de service saisie par l'utilisateur lors de la génération.
  final String? userInstruction;

  /// Moteur qui a répondu — nommé en label dans l'onglet, jamais dans le texte.
  final String provider;
  final String model;
  final int promptVersion;
  final DateTime? generatedAt;

  const PlatingAdvice({
    required this.complexite,
    required this.resume,
    required this.contenant,
    required this.etapes,
    required this.pieges,
    required this.derniereMinute,
    this.userInstruction,
    this.provider = '',
    this.model = '',
    this.promptVersion = 0,
    this.generatedAt,
  });

  bool get hasImages => etapes.any((step) => step.imageUrl != null);

  /// Index du dernier visuel produit, ou -1 si la série est vide.
  ///
  /// C'est la seule étape qu'on puisse refaire : les visuels s'enchaînent, et
  /// reprendre une étape du milieu laisserait derrière elle des images nées
  /// d'une assiette qui n'existe plus.
  int get lastIllustratedIndex {
    for (var i = etapes.length - 1; i >= 0; i--) {
      if (etapes[i].imageUrl != null) return i;
    }
    return -1;
  }

  /// Étapes à illustrer, dans l'ordre, pour que [index] ait un visuel.
  ///
  /// Chaque image se construit sur la précédente : demander l'étape 3 sans
  /// avoir les deux premières suppose de les produire d'abord, sans quoi la
  /// troisième naîtrait d'une assiette vide et n'aurait aucun rapport avec
  /// celles qu'on générerait ensuite.
  List<int> missingImageIndexesUpTo(int index) {
    if (index < 0 || index >= etapes.length) return const [];
    return [
      for (var i = 0; i <= index; i++)
        if (etapes[i].imageUrl == null) i,
    ];
  }

  factory PlatingAdvice.fromMap(Map<String, dynamic> data) {
    return PlatingAdvice(
      complexite: _parseComplexity(data['complexite'] as String?),
      resume: (data['resume'] as String?)?.trim() ?? '',
      contenant: (data['contenant'] as String?)?.trim() ?? '',
      etapes: (data['etapes'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => PlatingStep.fromMap(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      pieges: (data['pieges'] as List? ?? const []).whereType<String>().toList(
        growable: false,
      ),
      derniereMinute: (data['derniere_minute'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      userInstruction: _nullIfBlank(data['user_instruction'] as String?),
      provider: (data['provider'] as String?) ?? '',
      model: (data['model'] as String?) ?? '',
      promptVersion: (data['prompt_version'] as num?)?.toInt() ?? 0,
      generatedAt: _parseDate(data['generated_at']),
    );
  }

  PlatingAdvice copyWith({List<PlatingStep>? etapes}) {
    return PlatingAdvice(
      complexite: complexite,
      resume: resume,
      contenant: contenant,
      etapes: etapes ?? this.etapes,
      pieges: pieges,
      derniereMinute: derniereMinute,
      userInstruction: userInstruction,
      provider: provider,
      model: model,
      promptVersion: promptVersion,
      generatedAt: generatedAt,
    );
  }

  PlatingAdvice copyWithStep(int index, PlatingStep step) {
    if (index < 0 || index >= etapes.length) return this;
    final next = [...etapes];
    next[index] = step;
    return copyWith(etapes: next);
  }
}

PlatingComplexity _parseComplexity(String? raw) {
  return switch (raw) {
    'simple' => PlatingComplexity.simple,
    'complexe' => PlatingComplexity.complexe,
    _ => PlatingComplexity.intermediaire,
  };
}

String? _nullIfBlank(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// La date arrive en `Timestamp` depuis Firestore et en ISO depuis la callable :
/// les deux chemins alimentent le même écran.
DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  // Timestamp Firestore — même conversion que le reste du domaine.
  return (value as dynamic).toDate() as DateTime?;
}
