/// Échelle des tailles d'icônes.
///
/// L'application en comptait dix-neuf : 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
/// 20, 22, 32, 36, 40, 48, 56, 64 — plus quelques valeurs cachées dans des
/// ternaires. Aucune n'était fausse ; c'est leur nombre qui l'était. Deux
/// icônes voisines à 13 et 14 pixels ne se distinguent pas, elles donnent
/// seulement l'impression que rien n'est aligné.
///
/// Cinq crans suffisent, et chacun répond à une question différente :
/// dans quoi l'icône est-elle posée ?
abstract final class AppIconSize {
  /// Dans une puce dense, un badge, un compteur : l'icône accompagne un
  /// chiffre plus qu'elle ne se lit seule.
  static const double badge = 12;

  /// Au fil d'une phrase ou dans une étiquette : l'icône a la hauteur du
  /// texte qu'elle borde.
  static const double inline = 16;

  /// Dans une barre d'outils resserrée, une ligne de liste compacte, un
  /// bouton dense.
  static const double small = 20;

  /// Taille par défaut d'une icône d'action — celle de Material quand on ne
  /// précise rien. À ne pas écrire : l'omission dit la même chose.
  static const double medium = 24;

  /// Vignette : l'icône remplace une image absente dans une carte.
  static const double large = 40;

  /// Illustration d'un écran vide, d'une erreur, d'une image cassée. C'est le
  /// seul cran où l'icône est le sujet et non l'accompagnement.
  static const double hero = 64;
}
