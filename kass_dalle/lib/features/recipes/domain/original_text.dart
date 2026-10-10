/// Texte d'une recette tel qu'il était écrit sur la page, avant traduction.
///
/// Lu dans `recipes/{id}/origine/texte`, écrit par le serveur à l'import et
/// jamais modifié ensuite : il ne suit pas les éditions de la recette.
class OriginalText {
  const OriginalText({
    required this.langue,
    required this.titre,
    this.introduction,
    this.ingredientSections = const [],
    this.stepSections = const [],
    this.notes = const [],
  });

  /// Code ISO 639-1 de la langue de la page.
  final String langue;
  final String titre;
  final String? introduction;
  final List<OriginalTextSection> ingredientSections;
  final List<OriginalTextSection> stepSections;
  final List<OriginalTextNote> notes;

  factory OriginalText.fromMap(Map<String, dynamic> data) {
    return OriginalText(
      langue: data['langue'] as String? ?? '',
      titre: data['titre'] as String? ?? '',
      introduction: _nonEmpty(data['introduction']),
      ingredientSections: _sections(data['sections_ingredients'], 'lignes'),
      stepSections: _sections(data['sections_etapes'], 'etapes'),
      notes: [
        for (final raw in data['notes'] as List? ?? const [])
          if (raw is Map)
            OriginalTextNote(
              genre: raw['genre'] as String? ?? '',
              texte: raw['texte'] as String? ?? '',
            ),
      ].where((n) => n.texte.isNotEmpty).toList(growable: false),
    );
  }

  static String? _nonEmpty(Object? value) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? null : text;
  }

  static List<OriginalTextSection> _sections(Object? raw, String linesKey) {
    return [
      for (final section in raw as List? ?? const [])
        if (section is Map)
          OriginalTextSection(
            titre: section['titre'] as String? ?? '',
            lignes: [
              for (final line in section[linesKey] as List? ?? const [])
                if (line is String && line.trim().isNotEmpty) line.trim(),
            ],
          ),
    ].where((s) => s.lignes.isNotEmpty).toList(growable: false);
  }
}

/// Un groupe d'ingrédients ou d'étapes, sous son intitulé (vide s'il n'en a pas).
class OriginalTextSection {
  const OriginalTextSection({required this.titre, required this.lignes});

  final String titre;
  final List<String> lignes;
}

/// Une astuce, une variante, un conseil du livre.
class OriginalTextNote {
  const OriginalTextNote({required this.genre, required this.texte});

  final String genre;
  final String texte;
}
