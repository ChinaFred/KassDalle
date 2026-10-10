/// Compte rendu d'un passage du backfill « Protéine et féculent des plats ».
///
/// Deux origines, une seule forme : la réponse de `backfillRecipeProteinFn`
/// quand le passage vient de finir, et `last_report` dans
/// `app_config/recipe_protein_backfill_checkpoint`, où la fonction le laisse
/// à côté de son curseur.
class RecipeProteinBackfillReport {
  /// Fin du passage. `null` quand le compte rendu n'en porte pas.
  final DateTime? finishedAt;
  final int examinees;

  /// Plats et accompagnements examinés par le modèle et marqués, réponse
  /// hors liste comprise.
  final int traitees;

  /// Déjà marqués examinés, ou porteurs d'une protéine (marqueur posé sans
  /// appel de modèle).
  final int dejaTraitees;

  /// Pages non-recettes, recettes sans rôle, entrées, desserts, snacks.
  final int ignorees;

  /// Le modèle n'a pas répondu : réexaminées au tour suivant.
  final int sansReponse;
  final int echouees;

  /// Plats et accompagnements pas encore examinés, sur toute la collection.
  /// `null` quand le serveur n'a pas pu les compter.
  final int? restantes;
  final bool completed;
  final bool stoppedByBudget;
  final bool stoppedByErrors;
  final bool stoppedByDeadline;

  const RecipeProteinBackfillReport({
    required this.finishedAt,
    required this.examinees,
    required this.traitees,
    required this.dejaTraitees,
    required this.ignorees,
    required this.sansReponse,
    required this.echouees,
    required this.restantes,
    required this.completed,
    required this.stoppedByBudget,
    required this.stoppedByErrors,
    required this.stoppedByDeadline,
  });

  /// Lit les compteurs tels que la fonction les rend. Un compteur absent vaut
  /// zéro ; `restantes` absent ou non numérique reste `null`.
  factory RecipeProteinBackfillReport.fromMap(
    Map<String, dynamic> map, {
    DateTime? finishedAt,
  }) {
    int count(String key) => (map[key] as num?)?.toInt() ?? 0;
    final restantes = map['restantes'];
    return RecipeProteinBackfillReport(
      finishedAt: finishedAt,
      examinees: count('examinees'),
      traitees: count('traitees'),
      dejaTraitees: count('dejaTraitees'),
      ignorees: count('ignorees'),
      sansReponse: count('sansReponse'),
      echouees: count('echouees'),
      restantes: restantes is num ? restantes.toInt() : null,
      completed: map['completed'] == true,
      stoppedByBudget: map['stoppedByBudget'] == true,
      stoppedByErrors: map['stoppedByErrors'] == true,
      stoppedByDeadline: map['stoppedByDeadline'] == true,
    );
  }

  /// « Reste à traiter : 212 plats. », ou l'échec du décompte.
  String get restantesSentence {
    final n = restantes;
    if (n == null) {
      return 'Reste à traiter : décompte impossible '
          '(voir les rapports d\'erreurs).';
    }
    if (n == 0) return 'Plus rien à traiter.';
    return 'Reste à traiter : environ $n plat${n > 1 ? 's' : ''} '
        'ou accompagnement${n > 1 ? 's' : ''}.';
  }

  /// Les compteurs du passage, en une ligne, et pourquoi il s'est arrêté.
  String get passSummary =>
      'examinées=$examinees, traitées=$traitees, '
      'déjà traitées=$dejaTraitees, ignorées=$ignorees, '
      'sans réponse=$sansReponse, échecs=$echouees'
      '${completed ? ' — terminé' : ' — incomplet'}'
      '${stoppedByBudget ? ' (quota du passage atteint, relancer pour continuer)' : ''}'
      '${stoppedByErrors ? ' (trois échecs de suite : voir les rapports d\'erreurs)' : ''}'
      '${stoppedByDeadline ? ' (arrêt préventif, relancer pour continuer)' : ''}';
}
