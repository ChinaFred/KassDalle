import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'admin_providers.dart';
import 'billing_providers.dart';
import '../domain/recipe_roles_backfill_report.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../books/presentation/book_providers.dart';
import '../../planning/domain/meal_staple.dart';
import '../../planning/presentation/meal_staples_providers.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';

/// Écran d'administration : backfill unique d'enrichissement des référentiels.
///
/// Estime par IA les poids d'unités manquants et les valeurs nutritionnelles
/// (per100g) des ingrédients manquants. Idempotent, avec reprise sur checkpoint.
class AdminBackfillsScreen extends ConsumerStatefulWidget {
  const AdminBackfillsScreen({super.key});

  @override
  ConsumerState<AdminBackfillsScreen> createState() =>
      _AdminBackfillsScreenState();
}

class _AdminBackfillsScreenState extends ConsumerState<AdminBackfillsScreen> {
  bool _busy = false;
  String _busyLabel = '';
  String? _resultMessage;
  String? _errorMessage;
  bool _resultIsError = false;

  Future<T?> _runBackfill<T>({
    required String label,
    required String feature,
    required Future<T> Function() run,
    required String Function(T) format,
    Map<String, dynamic> context = const {},
  }) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _resultMessage = null;
      _errorMessage = null;
      _resultIsError = false;
    });
    try {
      final result = await run();
      if (!mounted) return null;
      ref.invalidate(referentialKpisProvider);
      setState(() {
        _busy = false;
        _resultMessage = format(result);
        _resultIsError = false;
      });
      return result;
    } catch (e, st) {
      try {
        await ref
            .read(errorReportServiceProvider)
            .reportError(
              feature: feature,
              error: e,
              stackTrace: st,
              context: {'label': label, ...context},
            );
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'adminBackfillsScreen.runBackfill',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _errorMessage = '$e';
        _resultIsError = true;
      });
      return null;
    }
  }

  /// Rattache les recettes sans livre au livre des recettes libres.
  ///
  /// L'opération tourne déjà toute seule à chaque ouverture de la
  /// bibliothèque. Elle est ici parce qu'un traitement automatique et muet ne
  /// se vérifie pas : on ne sait ni s'il a tourné, ni combien il a déplacé.
  /// Lancée à la main, elle rend un compte.
  Future<void> _runAttachOrphanRecipes() async {
    final user = ref.read(appUserProvider).value;
    if (user == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rattacher les recettes sans livre'),
        content: const Text(
          'Les recettes qui n\'ont aucun livre rejoignent « Mes recettes '
          'libres ».\n\n'
          'Ne concerne que vos propres recettes, et ne touche à aucune recette '
          'déjà rangée dans un livre. Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<({int moved, String bookTitre})>(
      label: 'Rattachement des recettes sans livre...',
      feature: 'admin_attach_orphan_recipes',
      run: () => ref
          .read(bookRepositoryProvider)
          .attachOrphanRecipesToLibres(user.uid, user.displayName),
      format: (r) => r.moved == 0
          ? 'Aucune recette sans livre : tout est déjà rangé.'
          : '${r.moved} recette(s) rattachée(s) à « ${r.bookTitre} ».',
    );
  }

  Future<void> _runBackfillEnrichReferentials() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enrichir les référentiels'),
        content: const Text(
          'Cette opération estime par IA :\n'
          '• le poids des unités sans conversion (poignée, brin, petit…) ;\n'
          '• les valeurs nutritionnelles (per100g) des ingrédients manquants.\n\n'
          'Le traitement est idempotent et reprend depuis le checkpoint serveur. '
          'Relancez si le résultat indique « incomplet ». Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Enrichissement des référentiels en cours...',
      feature: 'admin_backfill_enrich_referentials',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).backfillEnrichReferentials(),
      format: (r) =>
          'Unités: scannées=${r['scannedUnits']}, enrichies=${r['enrichedUnits']}, '
          'restantes=${r['remainingUnitsWithoutWeight']} | '
          'Ingrédients: scannés=${r['scannedIngredients']}, '
          'enrichis=${r['enrichedIngredients']}, échecs=${r['failedIngredients']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  /// Réparation du sel compté deux fois.
  ///
  /// Séparée de l'enrichissement courant, et pas seulement par prudence : elle
  /// redemande au modèle des profils qu'on possède déjà, ce que le rattrapage
  /// normal ne fait jamais. Le dialogue dit ce que ça coûte — mille cent
  /// soixante-sept ingrédients — parce qu'une dépense qu'on lance sans la
  /// chiffrer est une dépense qu'on ne peut pas arbitrer.
  Future<void> _runBackfillRefreshSodium() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reprendre le sel des ingrédients'),
        content: const Text(
          'Le sel et le sodium d\'un ingrédient décrivent la même chose dans '
          'deux unités. Ils étaient additionnés au lieu d\'être réconciliés : '
          'tout ingrédient salé porte un sel deux fois trop élevé.\n\n'
          'Le code est corrigé, mais les valeurs déjà écrites ne se réparent '
          'pas toutes seules — un profil doublé est indistinguable d\'un '
          'profil juste. Cette passe les fait réestimer par l\'IA.\n\n'
          'Elle porte sur les ingrédients porteurs de sodium, soit la grande '
          'majorité du référentiel, et coûte donc autant qu\'un premier '
          'remplissage. Idempotente, avec reprise sur point de contrôle : '
          'relancez tant que le résultat indique « incomplet ». Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Reprise du sel des ingrédients en cours...',
      feature: 'admin_backfill_refresh_sodium',
      run: () => ref
          .read(gcpBillingRepositoryProvider)
          .backfillEnrichReferentials(refreshSodium: true),
      format: (r) =>
          'Ingrédients: scannés=${r['scannedIngredients']}, '
          'repris=${r['refreshedIngredients']}, échecs=${r['failedIngredients']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  Future<void> _runBackfillNutrition() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reprendre la nutrition'),
        content: const Text(
          'Reprend le calcul des recettes dont la nutrition manque, a échoué, '
          'ou reste incomplète.\n\n'
          'Un passage automatique le fait déjà chaque nuit à 5 h, avec deux '
          'garde-fous : il attend vingt heures entre deux tentatives, et '
          'renonce après cinq essais. Cette reprise-ci lève les deux — '
          'utile juste après une correction de référentiel.\n\n'
          'Idempotent, avec reprise sur point de contrôle. Relancez tant que le '
          'résultat indique « incomplet ». Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Reprise de la nutrition en cours...',
      feature: 'admin_backfill_nutrition',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillNutrition(),
      format: (r) =>
          'Recettes: examinées=${r['examinees']}, reprises=${r['reprises']}, '
          'complétées=${r['completees']}, encore incomplètes=${r['echouees']}, '
          'laissées=${r['laissees']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByBudget'] ?? 0) == 1 ? ' (plafond de dépense atteint)' : ''}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  Future<void> _runBackfillRecipePrivacy() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reprendre la confidentialité'),
        content: const Text(
          'Pose « privé » ou « partagé » sur chaque recette, d\'après le livre '
          'qui la porte.\n\n'
          'À lancer une fois, après la mise en service du champ. Les recettes '
          'écrites avant ne le portent pas, et Firestore n\'assimile pas un '
          'champ absent à « partagé » : sans cette passe, elles disparaîtraient '
          'de la recherche et du planning de la famille.\n\n'
          'Aucun appel d\'IA, aucun coût de modèle. Idempotent, avec reprise sur '
          'point de contrôle : relancez tant que le résultat indique '
          '« incomplet ». Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Reprise de la confidentialité en cours...',
      feature: 'admin_backfill_recipe_privacy',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillRecipePrivacy(),
      format: (r) =>
          'Recettes: examinées=${r['examinees']}, corrigées=${r['corrigees']}, '
          'passées en privé=${r['passeesEnPrive']} '
          '(${r['livresPrives']} livre(s) privé(s))'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  /// Sème le référentiel des garnitures simples.
  ///
  /// Une écriture ponctuelle, donc ici et non dans l'écran du référentiel :
  /// c'est là qu'on cherche ce genre de bouton, et là qu'on attend un compte.
  /// Aucun appel d'IA. Ne remplace jamais une entrée existante.
  Future<void> _runSeedMealStaples() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Semer les garnitures simples'),
        content: Text(
          'Crée les ${kDefaultMealStaples.length} garnitures de base qui '
          'manquent — riz, pâtes, salade verte, yaourt… — avec la part par '
          'personne. Celles qui existent déjà ne sont pas touchées : une '
          'valeur corrigée dans Admin › Référentiels fait foi.\n\n'
          'Aucun appel d\'IA, aucun coût de modèle. Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Semer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<({int created, int skipped})>(
      label: 'Semis des garnitures simples...',
      feature: 'admin_backfill_seed_meal_staples',
      run: () => ref.read(mealStaplesRepositoryProvider).seedDefaults(),
      format: (r) => r.created == 0
          ? 'Tout était déjà en place (${r.skipped} garnitures).'
          : '${r.created} garniture(s) créée(s), ${r.skipped} déjà en place.',
    );
  }

  /// Classe les recettes par leur rôle dans un repas.
  ///
  /// Le planning ne compose un plat et son accompagnement que pour une
  /// recette classée. La passe 2 de l'import classe ce qui arrive ; cette
  /// reprise classe l'existant, quarante recettes par passage.
  Future<void> _runBackfillRecipeRoles() async {
    // Ce qu'il reste à classer, d'après le dernier passage : on sait avant de
    // lancer si un passage de quarante suffira.
    final lastReport = ref.read(recipeRolesBackfillReportProvider).value;
    final reste = lastReport == null ? '' : ' ${lastReport.restantesSentence}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rôle des recettes dans un repas'),
        content: Text(
          'Demande au modèle, pour chaque recette qui ne l\'a pas encore, son '
          'rôle dans un repas — plat, accompagnement, entrée, dessert, snack —, '
          'ce qu\'elle apporte déjà (protéine, féculent, légume) et ses '
          'accompagnements classiques. C\'est ce qui permet au planning de '
          'composer un plat et son accompagnement.\n\n'
          'Un appel de modèle par recette, quarante recettes par passage. '
          'Idempotent, avec reprise sur point de contrôle : relancez tant que '
          'le résultat indique « incomplet ».$reste Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<RecipeRolesBackfillReport>(
      label: 'Classement des recettes en cours...',
      feature: 'admin_backfill_recipe_roles',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillRecipeRoles(),
      format: (r) => '${r.restantesSentence}\nCe passage : ${r.passSummary}',
    );
  }

  Future<void> _runBackfillShoppingAliases() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Produit acheté des ingrédients'),
        content: const Text(
          'Rattrape le passé : un ingrédient neuf reçoit désormais son '
          'produit acheté tout seul, dès son import. Ce backfill traite ce '
          'qui existait déjà avant ce changement — pour chaque ingrédient du '
          'référentiel qui n\'a pas encore le champ, le modèle dit ce qu\'on '
          'achète : « beurre fondu » s\'achète en beurre, « jaune d\'œuf » en '
          'œufs. Un ingrédient qui est déjà le produit reçoit un champ vide '
          'et n\'est pas redemandé.\n\n'
          'Un appel de modèle par lot de quarante ingrédients, quatre cents '
          'ingrédients par passage. Idempotent, avec reprise sur point de '
          'contrôle : relancez tant que le résultat indique « incomplet ». '
          'Ensuite, lancez « Recalculer les produits d\'achat » pour que les '
          'recettes existantes s\'en servent. Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Produit acheté des ingrédients en cours...',
      feature: 'admin_backfill_shopping_aliases',
      run: () => ref
          .read(gcpBillingRepositoryProvider)
          .backfillShopping(mode: 'aliases'),
      format: (r) =>
          'Ingrédients : examinés=${r['examinees']}, '
          'déjà renseignés=${r['dejaRenseignes']}, '
          'produit posé=${r['renseignes']}, déjà le produit=${r['inchanges']}, '
          'sans réponse=${r['sansReponse']}, échecs=${r['echouees']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByBudget'] ?? 0) == 1 ? ' (quota du passage atteint, relancer pour continuer)' : ''}'
          '${(r['stoppedByErrors'] ?? 0) == 1 ? ' (trois échecs de suite : voir les rapports d\'erreurs)' : ''}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  Future<void> _runBackfillShoppingProducts() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recalculer les produits d\'achat'),
        content: const Text(
          'Recalcule la liste de courses de toutes les recettes : une ligne '
          'par produit et famille d\'unité, kilo et grammes additionnés, '
          'produit acheté du référentiel appliqué. Le déclencheur d\'écriture '
          'ne le fait que quand les ingrédients changent ; les recettes '
          'existantes gardent sinon leurs anciennes lignes.\n\n'
          'Aucun appel de modèle. Une recette dont le résultat ne change pas '
          'n\'est pas réécrite. Cinq cents recettes par passage, avec reprise '
          'sur point de contrôle : relancez tant que le résultat indique '
          '« incomplet ». Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Recalcul des produits d\'achat en cours...',
      feature: 'admin_backfill_shopping_products',
      run: () => ref
          .read(gcpBillingRepositoryProvider)
          .backfillShopping(mode: 'products'),
      format: (r) =>
          'Recettes : examinées=${r['examinees']}, '
          'recalculées=${r['recalculees']}, identiques=${r['identiques']}, '
          'sans ingrédients=${r['sansIngredients']}, '
          'hors recette=${r['horsRecette']}, échecs=${r['echouees']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByBudget'] ?? 0) == 1 ? ' (quota du passage atteint, relancer pour continuer)' : ''}'
          '${(r['stoppedByErrors'] ?? 0) == 1 ? ' (trois échecs de suite : voir les rapports d\'erreurs)' : ''}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  /// Dernier compte rendu du backfill, tel que la fonction l'a laissé à côté
  /// de son curseur. Pour qui a quitté l'écran avant la fin du passage.
  String _rolesReportLine(AsyncValue<RecipeRolesBackfillReport?> report) {
    return report.when(
      data: (r) {
        if (r == null) return '';
        final at = r.finishedAt;
        final quand = at == null
            ? ''
            : ' le ${DateFormat('dd/MM/yy HH:mm').format(at.toLocal())}';
        return '\n\nDernier passage$quand : ${r.classees} classée'
            '${r.classees > 1 ? 's' : ''}, ${r.echouees} en échec. '
            '${r.restantesSentence}';
      },
      loading: () => '',
      error: (_, _) => '\n\nDernier compte rendu illisible.',
    );
  }

  // Trois opérations ont quitté cet écran, et le code derrière elles avec.
  //
  // « Amorcer les droits utilisateurs » rattrapait les comptes créés avant que
  // le déclencheur `syncUserClaims` n'existe. Ce déclencheur écrit désormais les
  // claims à chaque écriture d'un document utilisateur, création comprise : il
  // ne reste aucun compte à rattraper, et un compte qui en aurait besoin se
  // répare en changeant son rôle depuis l'écran Utilisateurs.
  //
  // « Amorcer les poids à la pièce » versait la table intégrée dans le
  // référentiel. Le versement a eu lieu ; la table reste consultée comme filet
  // par `pieceWeightForIngredient`, donc son retrait de cet écran ne fait rien
  // disparaître du calcul.
  //
  // « Auditer les identifiants d'ingrédients » réparait les documents rendus
  // inatteignables par un changement de la règle de normalisation — celui des
  // ligatures, où « œuf » produisait « uf ». La règle n'a pas rebougé, et les
  // écritures passent toutes par le même normalisateur : l'audit n'a plus rien
  // à constater. Si la règle change à nouveau, l'outil se retrouve dans
  // l'historique git, écrit pour cette occasion-là.
  //
  // Reste ici la seule opération qui ait encore du travail à chaque exécution :
  // les référentiels reçoivent de nouveaux ingrédients à chaque recette.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rolesReport = ref.watch(recipeRolesBackfillReportProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Backfills')),
      body: Stack(
        children: [
          Column(
            children: [
              // Hors de la liste, pour rester visible. L'opération la plus
              // récente est la dernière tuile : un compte rendu inséré en tête
              // d'une liste défilée jusqu'en bas s'affichait hors de l'écran,
              // et trois passages du rôle des recettes ont été lancés sans
              // que leur résultat soit lu.
              if (_resultMessage != null || _errorMessage != null)
                _OperationBanner(
                  isError: _resultIsError,
                  message: _errorMessage ?? _resultMessage ?? '',
                  onClose: () => setState(() {
                    _resultMessage = null;
                    _errorMessage = null;
                  }),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Enrichissement des référentiels',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Complète automatiquement, via IA, les données manquantes '
                              'des référentiels : poids des unités et valeurs '
                              'nutritionnelles (per100g) des ingrédients.',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _BackfillTile(
                      icon: Icons.auto_awesome_outlined,
                      title: 'Enrichir unités + ingrédients',
                      subtitle:
                          'Estime les poids d\'unités manquants et les per100g des '
                          'ingrédients. Idempotent, reprise sur checkpoint.',
                      onTap: _busy ? null : _runBackfillEnrichReferentials,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.science_outlined,
                      title: 'Reprendre le sel des ingrédients',
                      subtitle:
                          'Réparation : le sel et le sodium étaient additionnés au '
                          'lieu d\'être réconciliés, et tout ingrédient salé en porte '
                          'le double. Réestime les profils concernés — dépense '
                          'importante, à ne lancer qu\'une fois.',
                      onTap: _busy ? null : _runBackfillRefreshSodium,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.restore_outlined,
                      title: 'Reprendre la nutrition',
                      subtitle:
                          'Recalcule les recettes dont la nutrition manque, a échoué '
                          'ou reste incomplète. Le passage de 5 h le fait déjà ; '
                          'ici, sans attendre vingt heures.',
                      onTap: _busy ? null : _runBackfillNutrition,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.menu_book_outlined,
                      title: 'Rattacher les recettes sans livre',
                      subtitle:
                          'Range dans « Mes recettes libres » les recettes qui n\'ont '
                          'aucun livre. Tourne déjà à chaque ouverture de la '
                          'bibliothèque ; ici, elle rend un compte.',
                      onTap: _busy ? null : _runAttachOrphanRecipes,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.lock_outline,
                      title: 'Reprendre la confidentialité',
                      subtitle:
                          'Pose « privé » ou « partagé » sur chaque recette, d\'après '
                          'son livre. À lancer une fois : les recettes antérieures ne '
                          'portent pas le champ, et un champ absent les exclut des '
                          'écrans de la famille.',
                      onTap: _busy ? null : _runBackfillRecipePrivacy,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.rice_bowl_outlined,
                      title: 'Semer les garnitures simples',
                      subtitle:
                          'Crée les garnitures de base — riz, pâtes, salade verte, '
                          'yaourt… — avec la part par personne. Ne touche pas à '
                          'celles qui existent. Aucun appel d\'IA.',
                      onTap: _busy ? null : _runSeedMealStaples,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.restaurant_outlined,
                      title: 'Rôle des recettes dans un repas',
                      subtitle:
                          'Classe les recettes non classées : plat, accompagnement, '
                          'entrée, dessert ou snack, ce qu\'elles apportent déjà et '
                          'leurs accompagnements classiques. Un appel par recette, '
                          'quarante par passage.'
                          '${_rolesReportLine(rolesReport)}',
                      onTap: _busy ? null : _runBackfillRecipeRoles,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.shopping_basket_outlined,
                      title: 'Produit acheté des ingrédients',
                      subtitle:
                          'Rattrape le passé : un ingrédient neuf le reçoit '
                          'déjà tout seul à l\'import. Demande au modèle, '
                          'pour chaque ingrédient antérieur du référentiel, '
                          'le produit qu\'on achète : beurre fondu → beurre, '
                          'jaune d\'œuf → œuf. Se corrige aussi à la main '
                          'dans Référentiels › Ingrédients.',
                      onTap: _busy ? null : _runBackfillShoppingAliases,
                    ),
                    const SizedBox(height: 8),
                    _BackfillTile(
                      icon: Icons.shopping_cart_outlined,
                      title: 'Recalculer les produits d\'achat',
                      subtitle:
                          'Refait la liste de courses de toutes les recettes '
                          'avec la règle du jour et les produits achetés du '
                          'référentiel. Aucun appel d\'IA. À lancer après '
                          '« Produit acheté des ingrédients ».',
                      onTap: _busy ? null : _runBackfillShoppingProducts,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: Center(
                    child: Card(
                      margin: const EdgeInsets.all(24),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              _busyLabel,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BackfillTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _BackfillTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.play_arrow_outlined),
        onTap: onTap,
      ),
    );
  }
}

class _OperationBanner extends StatelessWidget {
  final bool isError;
  final String message;
  final VoidCallback onClose;

  const _OperationBanner({
    required this.isError,
    required this.message,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final fg = isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                color: fg,
                size: AppIconSize.small,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
              ),
              IconButton(
                tooltip: 'Fermer',
                onPressed: onClose,
                icon: Icon(Icons.close, color: fg, size: AppIconSize.small),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
