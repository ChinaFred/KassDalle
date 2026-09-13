/// Compte rendu d'un passage du backfill « Rôle des recettes dans un repas ».
///
/// Deux origines, une seule forme : la réponse de `backfillRecipeRolesFn`
/// quand le passage vient de finir, et `last_report` dans
/// `app_config/recipe_roles_backfill_checkpoint`, où la fonction le laisse à
/// côté de son curseur. Un passage dure plusieurs minutes et son résultat
/// affiché en fin de traitement se rate : relu depuis le point de contrôle,
/// il reste lisible jusqu'au passage suivant.
class RecipeRolesBackfillReport {
  /// Fin du passage. `null` quand le compte rendu n'en porte pas.
  final DateTime? finishedAt;
  final int examinees;
  final int classees;
  final int dejaClassees;
  final int horsRecette;
  final int sansRole;
  final int echouees;

  /// Recettes encore sans rôle après ce passage, sur toute la collection.
  /// `null` quand le serveur n'a pas pu les compter : un zéro à sa place
  /// dirait que tout est classé.
  final int? restantes;
  final bool completed;
  final bool stoppedByBudget;
  final bool stoppedByErrors;
  final bool stoppedByDeadline;

  const RecipeRolesBackfillReport({
    required this.finishedAt,
    required this.examinees,
    required this.classees,
    required this.dejaClassees,
    required this.horsRecette,
    required this.sansRole,
    required this.echouees,
    required this.restantes,
    required this.completed,
    required this.stoppedByBudget,
    required this.stoppedByErrors,
    required this.stoppedByDeadline,
  });

  /// Lit les compteurs tels que la fonction les rend. Un compteur absent vaut
  /// zéro ; `restantes` absent ou non numérique reste `null`.
  factory RecipeRolesBackfillReport.fromMap(
    Map<String, dynamic> map, {
    DateTime? finishedAt,
  }) {
    int count(String key) => (map[key] as num?)?.toInt() ?? 0;
    final restantes = map['restantes'];
    return RecipeRolesBackfillReport(
      finishedAt: finishedAt,
      examinees: count('examinees'),
      classees: count('classees'),
      dejaClassees: count('dejaClassees'),
      horsRecette: count('horsRecette'),
      sansRole: count('sansRole'),
      echouees: count('echouees'),
      restantes: restantes is num ? restantes.toInt() : null,
      completed: map['completed'] == true,
      stoppedByBudget: map['stoppedByBudget'] == true,
      stoppedByErrors: map['stoppedByErrors'] == true,
      stoppedByDeadline: map['stoppedByDeadline'] == true,
    );
  }

  /// « Reste à classer : 212 recettes. » — le chiffre que l'on cherche quand
  /// on relance pour la troisième fois. Ou l'aveu que le décompte a échoué.
  String get restantesSentence {
    final n = restantes;
    if (n == null) {
      return 'Reste à classer : décompte impossible '
          '(voir les rapports d\'erreurs).';
    }
    if (n == 0) return 'Plus rien à classer.';
    return 'Reste à classer : $n recette${n > 1 ? 's' : ''}.';
  }

  /// Les compteurs du passage, en une ligne, et pourquoi il s'est arrêté.
  String get passSummary =>
      'examinées=$examinees, classées=$classees, '
      'déjà classées=$dejaClassees, hors recette=$horsRecette, '
      'sans rôle=$sansRole, échecs=$echouees'
      '${completed ? ' — terminé' : ' — incomplet'}'
      '${stoppedByBudget ? ' (quota du passage atteint, relancer pour continuer)' : ''}'
      '${stoppedByErrors ? ' (trois échecs de suite : voir les rapports d\'erreurs)' : ''}'
      '${stoppedByDeadline ? ' (arrêt préventif, relancer pour continuer)' : ''}';
}
