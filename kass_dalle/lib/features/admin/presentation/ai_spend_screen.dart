import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_budget_repository.dart';
import '../data/feature_catalog.dart';
import '../../../core/theme/app_icon_size.dart';
import 'admin_providers.dart';
import 'ai_services_tab.dart' show ServicesGrouping;
import 'costs_format.dart';
import 'monthly_costs_screen.dart' show CostsDepthChips, costsDepthProvider;

/// Dépense par utilisateur, et plafonds.
///
/// Écran à part et non section d'un onglet : les coûts mensuels répondent à
/// « combien l'application coûte », celui-ci à « qui dépense, à quoi, et
/// jusqu'où il peut aller ». Ce sont deux questions qu'on ne se pose pas au
/// même moment, et la seconde a besoin de place — une ligne par compte, un
/// détail par poste.
///
/// Le sélecteur de période est celui des deux autres onglets, à l'état près :
/// c'est le même composant et le même provider, pour qu'un mois choisi ici se
/// retrouve là-bas.
class AiSpendScreen extends ConsumerStatefulWidget {
  const AiSpendScreen({super.key});

  @override
  ConsumerState<AiSpendScreen> createState() => _AiSpendScreenState();
}

/// Ce sur quoi le tableau se trie.
///
/// Trois clés, et pas de date : une ligne de ce tableau est un compte ou un
/// poste, pas un jour. La date est la PÉRIODE, et elle se choisit par les puces
/// au-dessus. Offrir un tri par date ici trierait sur une colonne qui n'existe
/// pas — voir la note en tête de `_SpendControls`.
enum SpendSort {
  cout('Coût'),
  appels('Appels'),
  nom('Nom');

  final String label;
  const SpendSort(this.label);
}

/// Une ligne du détail d'un compte : un poste, ou un processus et ses postes.
///
/// Un seul type pour les deux axes de lecture. Le tri et le filtre portent sur
/// `label`, `costUsd` et `calls` — trois champs que le poste et le processus
/// ont en commun —, ce qui évite d'écrire deux fois le même comparateur.
class SpendDetailRow {
  final String label;
  final double costUsd;
  final int calls;

  /// Les postes du processus. Vide quand la ligne EST un poste.
  final List<SpendDetailRow> enfants;

  /// Le groupe est déplié d'entrée parce que ce sont ses POSTES qui ont
  /// répondu au filtre. Chercher « sodium » et tomber sur six groupes fermés
  /// n'apprend rien : ce qui correspond doit être visible sans un clic de
  /// plus. Un groupe gardé pour son propre nom, lui, reste fermé.
  final bool ouvertParDefaut;

  const SpendDetailRow({
    required this.label,
    required this.costUsd,
    required this.calls,
    this.enfants = const [],
    this.ouvertParDefaut = false,
  });
}

/// Le filtre, appliqué à un libellé. [filtre] est attendu en minuscules.
bool spendMatches(String texte, String filtre) =>
    filtre.isEmpty || texte.toLowerCase().contains(filtre);

int compareSpendRows(
  SpendDetailRow a,
  SpendDetailRow b, {
  required SpendSort tri,
  required bool croissant,
}) {
  final ordre = switch (tri) {
    SpendSort.cout => a.costUsd.compareTo(b.costUsd),
    SpendSort.appels => a.calls.compareTo(b.calls),
    SpendSort.nom => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  };
  return croissant ? ordre : -ordre;
}

/// Le détail d'un compte, filtré, groupé et trié.
///
/// Sortie de l'écran pour être testable : elle additionne des montants, et une
/// somme fausse ne lève aucune erreur — elle s'affiche.
///
/// [tousGardes] vaut `true` quand c'est le NOM DU COMPTE qui a répondu au
/// filtre : ses postes sont alors tous montrés, sans quoi chercher un compte
/// rendrait une carte vide.
List<SpendDetailRow> spendDetail(
  UserSpend user, {
  required String filtre,
  required ServicesGrouping groupement,
  required SpendSort tri,
  required bool croissant,
  required bool tousGardes,
}) {
  int comparer(SpendDetailRow a, SpendDetailRow b) =>
      compareSpendRows(a, b, tri: tri, croissant: croissant);

  if (groupement == ServicesGrouping.feature) {
    final gardes = <SpendDetailRow>[];
    for (final f in user.byFeature) {
      final label = featureLabel(f.feature);
      if (!tousGardes && !spendMatches(label, filtre)) continue;
      gardes.add(
        SpendDetailRow(label: label, costUsd: f.costUsd, calls: f.calls),
      );
    }
    gardes.sort(comparer);
    return gardes;
  }

  final parProcessus = <String, List<FeatureSpend>>{};
  for (final f in user.byFeature) {
    parProcessus.putIfAbsent(featureProcess(f.feature), () => []).add(f);
  }

  final groupes = <SpendDetailRow>[];
  parProcessus.forEach((processus, postes) {
    final groupeCorrespond = tousGardes || spendMatches(processus, filtre);
    final gardes = groupeCorrespond
        ? postes
        : postes.where((f) => spendMatches(featureLabel(f.feature), filtre));
    final enfants = [
      for (final f in gardes)
        SpendDetailRow(
          label: featureLabel(f.feature),
          costUsd: f.costUsd,
          calls: f.calls,
        ),
    ]..sort(comparer);
    if (enfants.isEmpty) return;
    // Le total du groupe additionne les postes MONTRÉS, pas tous ceux qu'il
    // contient : un filtre qui cache trois postes sur huit et laisse le total
    // des huit ferait une ligne dont les enfants ne font pas la somme.
    groupes.add(
      SpendDetailRow(
        label: processus,
        costUsd: enfants.fold(0, (somme, e) => somme + e.costUsd),
        calls: enfants.fold(0, (somme, e) => somme + e.calls),
        enfants: enfants,
        ouvertParDefaut: !groupeCorrespond,
      ),
    );
  });
  groupes.sort(comparer);
  return groupes;
}

class _AiSpendScreenState extends ConsumerState<AiSpendScreen> {
  AiBudgetSnapshot? _snapshot;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  int? _loadedDepth;

  /// Le jour dont on regarde la dépense, `AAAA-MM-JJ`. `null` = aujourd'hui.
  ///
  /// Distinct de la profondeur : celle-ci choisit les mois du tableau par
  /// compte, celui-là la journée du plafond. Les deux se règlent séparément
  /// parce qu'on ne les regarde pas pour la même raison — « combien ce mois
  /// a coûté » et « qui a mangé son plafond ce jour-là ».
  String? _day;

  /// Filtre libre, appliqué aux noms de compte ET aux noms de poste.
  ///
  /// Un tableau de trente-cinq postes répartis sur plusieurs comptes ne se lit
  /// pas : on y cherche un nom, et on ne le trouve qu'en descendant. Le filtre
  /// garde un compte dès qu'il correspond lui-même ou qu'un de ses postes
  /// correspond, et ne montre alors que les postes qui correspondent.
  String _filtre = '';

  /// Le contrôleur vit ICI, et pas dans le widget de filtre.
  ///
  /// Créé dans `build`, il serait reconstruit à chaque frappe — le champ
  /// perdrait le focus après chaque lettre. Et il faut pouvoir vider le filtre
  /// depuis deux endroits : la croix du champ, et le bouton de la carte
  /// « aucun résultat ». Un seul contrôleur, tenu par l'écran, répond aux deux.
  final _filtreController = TextEditingController();

  SpendSort _tri = SpendSort.cout;

  /// Décroissant par défaut : la première question posée à ce tableau est
  /// « qu'est-ce qui coûte le plus », pas « qu'est-ce qui coûte le moins ».
  bool _croissant = false;

  /// Poste technique ou processus, le même axe que l'onglet « Postes ».
  ///
  /// Un compte peut porter trente-cinq postes ; déplié, il tient sur deux
  /// écrans et la question « ce compte, il numérise ou il planifie ? » ne se
  /// lit nulle part. Groupés, les mêmes chiffres tiennent en sept lignes, et
  /// le détail reste à un clic.
  ///
  /// L'état est local, pas partagé avec l'onglet « Postes » : là-bas on lit
  /// une facture globale, ici on lit un compte, et rien ne dit qu'on veut le
  /// même axe aux deux endroits.
  ServicesGrouping _groupement = ServicesGrouping.feature;

  void _setFiltre(String valeur) {
    if (_filtreController.text != valeur) _filtreController.text = valeur;
    setState(() => _filtre = valeur.trim().toLowerCase());
  }

  bool _correspond(String texte) => spendMatches(texte, _filtre);

  int _comparerComptes(UserSpend a, UserSpend b) {
    final ordre = switch (_tri) {
      SpendSort.cout => a.costUsd.compareTo(b.costUsd),
      SpendSort.appels => a.calls.compareTo(b.calls),
      SpendSort.nom => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    };
    return _croissant ? ordre : -ordre;
  }

  /// Les comptes à afficher, avec leur détail déjà filtré, groupé et trié.
  List<(UserSpend, List<SpendDetailRow>)> _lignes(AiBudgetSnapshot snapshot) {
    final lignes = <(UserSpend, List<SpendDetailRow>)>[];
    for (final user in snapshot.spends) {
      final compteCorrespond = _correspond(user.label);
      final detail = spendDetail(
        user,
        filtre: _filtre,
        groupement: _groupement,
        tri: _tri,
        croissant: _croissant,
        tousGardes: compteCorrespond,
      );
      if (!compteCorrespond && detail.isEmpty) continue;
      lignes.add((user, detail));
    }
    lignes.sort((a, b) => _comparerComptes(a.$1, b.$1));
    return lignes;
  }

  @override
  void dispose() {
    _filtreController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final depth = ref.read(costsDepthProvider);
    if (_loadedDepth != depth || _snapshot == null) _load(depth);
  }

  Future<void> _load(int? depth) async {
    setState(() {
      _loading = true;
      _loadedDepth = depth;
    });
    try {
      final snapshot = await ref
          .read(aiBudgetRepositoryProvider)
          .fetch(depth: depth, day: _day);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
        _loading = false;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchAiSpend',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Change le jour regardé, et relit.
  ///
  /// `null` revient à la journée en cours. Le jour demandé n'est pas forcément
  /// celui qui revient : le serveur refuse une date à venir ou impossible, et
  /// c'est son verdict qui s'affiche.
  Future<void> _setDay(String? day) async {
    setState(() => _day = day);
    await _load(ref.read(costsDepthProvider));
  }

  Future<void> _save(AiBudgetPolicy policy) async {
    setState(() => _saving = true);
    try {
      await ref.read(aiBudgetRepositoryProvider).save(policy);
      if (!mounted) return;
      context.showSuccessSnackBar('Plafonds enregistrés.');
      await _load(ref.read(costsDepthProvider));
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveAiBudget',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Enregistrement impossible : $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final depth = ref.watch(costsDepthProvider);
    final snapshot = _snapshot;
    // Calculées une fois : la liste et le message « aucun résultat » lisent le
    // même travail, qui groupe et trie le détail de chaque compte.
    final lignes = snapshot == null
        ? const <(UserSpend, List<SpendDetailRow>)>[]
        : _lignes(snapshot);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dépense par utilisateur'),
        actions: [
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(depth),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CostsDepthChips(
            depth: depth,
            onChanged: (months) {
              ref.read(costsDepthProvider.notifier).set(months);
              _load(months);
            },
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('Lecture impossible'),
                subtitle: Text('$_error'),
                trailing: IconButton(
                  tooltip: 'Actualiser les dépenses',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _load(depth),
                ),
              ),
            )
          else if (snapshot == null || (_loading && _snapshot == null))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _BudgetCard(
              snapshot: snapshot,
              saving: _saving,
              onSave: _save,
              onDayChanged: _setDay,
            ),
            const SizedBox(height: 16),
            _PeriodHeader(snapshot: snapshot, loading: _loading),
            const SizedBox(height: 8),
            if (snapshot.spends.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.person_off_outlined),
                  title: Text('Aucune dépense sur la période'),
                ),
              )
            else ...[
              _SpendControls(
                controller: _filtreController,
                filtre: _filtre,
                tri: _tri,
                croissant: _croissant,
                groupement: _groupement,
                onFiltre: (v) =>
                    setState(() => _filtre = v.trim().toLowerCase()),
                onTri: (v) => setState(() => _tri = v),
                onSens: () => setState(() => _croissant = !_croissant),
                onGroupement: (v) => setState(() => _groupement = v),
              ),
              const SizedBox(height: 8),
              for (final (user, detail) in lignes)
                _UserCard(
                  user: user,
                  detail: detail,
                  snapshot: snapshot,
                  filtre: _filtre,
                  groupement: _groupement,
                ),
              if (lignes.isEmpty)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.search_off),
                    title: const Text('Aucun compte ni poste ne correspond'),
                    subtitle: Text('Filtre : « $_filtre »'),
                    trailing: TextButton(
                      onPressed: () => _setFiltre(''),
                      child: const Text('Effacer'),
                    ),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Ce que la période couvre, et ce qu'elle ne peut pas montrer.
class _PeriodHeader extends StatelessWidget {
  final AiBudgetSnapshot snapshot;
  final bool loading;

  const _PeriodHeader({required this.snapshot, required this.loading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final periods = snapshot.periods;
    final total = snapshot.spends.fold<double>(0, (sum, u) => sum + u.costUsd);
    final calls = snapshot.spends.fold<int>(0, (sum, u) => sum + u.calls);

    final label = periods.isEmpty
        ? 'Aucun mois enregistré'
        : periods.length == 1
        ? periods.single
        : '${periods.first} → ${periods.last}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Période : $label',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                '${formatMoney(total, snapshot.usdToEur ?? 0)} · ${formatCount(calls)} appels',
                style: theme.textTheme.titleMedium,
              ),
          ],
        ),
        if (snapshot.periodsWithoutBreakdown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Le détail par service manque pour ${snapshot.periodsWithoutBreakdown.join(', ')} : '
              'ces mois sont antérieurs à sa mise en place. Leur total reste juste, et une '
              'reconstruction des agrégats les rattrape.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// Un compte, son total sur la période, et le détail par service.
/// Le filtre et les tris du tableau.
///
/// Trois clés de tri, et pas de date. Ce n'est pas un oubli : une ligne de ce
/// tableau est un compte ou un poste, agrégé sur toute la période. Aucune n'a
/// de date propre. La date se choisit au-dessus, par les puces de période, et
/// un tri par date ici porterait sur une colonne qui n'existe pas.
///
/// Le jour où l'agrégat rendra une ligne par mois, ce tri aura un sens et sa
/// place est ici.
class _SpendControls extends StatelessWidget {
  final TextEditingController controller;
  final String filtre;
  final SpendSort tri;
  final bool croissant;
  final ServicesGrouping groupement;
  final ValueChanged<String> onFiltre;
  final ValueChanged<SpendSort> onTri;
  final VoidCallback onSens;
  final ValueChanged<ServicesGrouping> onGroupement;

  const _SpendControls({
    required this.controller,
    required this.filtre,
    required this.tri,
    required this.croissant,
    required this.groupement,
    required this.onFiltre,
    required this.onTri,
    required this.onSens,
    required this.onGroupement,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: groupement == ServicesGrouping.process
                    ? 'Filtrer un compte, un processus ou un poste'
                    : 'Filtrer un compte ou un poste',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: filtre.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Effacer le filtre',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          controller.clear();
                          onFiltre('');
                        },
                      ),
              ),
              onChanged: onFiltre,
              controller: controller,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<ServicesGrouping>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ServicesGrouping.feature,
                    label: Text('Par poste'),
                  ),
                  ButtonSegment(
                    value: ServicesGrouping.process,
                    label: Text('Par processus'),
                  ),
                ],
                selected: {groupement},
                onSelectionChanged: (valeurs) => onGroupement(valeurs.first),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Trier par'),
                for (final valeur in SpendSort.values)
                  ChoiceChip(
                    label: Text(valeur.label),
                    selected: tri == valeur,
                    onSelected: (_) => onTri(valeur),
                  ),
                IconButton(
                  tooltip: croissant ? 'Ordre croissant' : 'Ordre décroissant',
                  icon: Icon(
                    croissant ? Icons.arrow_upward : Icons.arrow_downward,
                  ),
                  onPressed: onSens,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final UserSpend user;

  /// Le détail déjà filtré, groupé et trié par l'écran.
  ///
  /// La carte ne refait rien de tout cela : le filtre décide aussi si la carte
  /// existe, et les deux décisions doivent être prises au même endroit.
  final List<SpendDetailRow> detail;
  final AiBudgetSnapshot snapshot;

  /// Sert au message affiché quand le filtre ne laisse aucun poste visible.
  final String filtre;

  final ServicesGrouping groupement;

  const _UserCard({
    required this.user,
    required this.detail,
    required this.snapshot,
    required this.filtre,
    required this.groupement,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = snapshot.usdToEur ?? 0;
    final isFounder = user.uid == snapshot.founderUid;

    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.person_outline),
        title: Row(
          children: [
            Expanded(child: Text(user.label, overflow: TextOverflow.ellipsis)),
            if (isFounder)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Chip(
                  label: Text('×${snapshot.founderMultiplier}'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  labelStyle: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${formatMoney(user.costUsd, rate)} · ${formatCount(user.calls)} appels',
        ),
        children: [
          if (user.byFeature.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('Aucun détail par service sur cette période.'),
            )
          else if (detail.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('Aucun poste ne contient « $filtre ».'),
            )
          else if (groupement == ServicesGrouping.process)
            for (final groupe in detail)
              _ProcessGroup(
                // La clé suit le nom du processus : sans elle, un changement de
                // filtre laisserait l'état « déplié » sur la ligne qui occupe
                // la même position, qui n'est plus le même groupe.
                key: ValueKey(groupe.label),
                groupe: groupe,
                rate: rate,
              )
          else
            for (final ligne in detail) _SpendLine(ligne: ligne, rate: rate),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Une ligne de détail : un libellé, un montant, un nombre d'appels.
class _SpendLine extends StatelessWidget {
  final SpendDetailRow ligne;
  final double rate;

  /// Décalage à gauche. Il sépare un poste rangé sous son processus des lignes
  /// de premier niveau.
  final double retrait;

  const _SpendLine({required this.ligne, required this.rate, this.retrait = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16 + retrait, 2, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ligne.label,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${formatMoney(ligne.costUsd, rate)} · ${formatCount(ligne.calls)}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Un processus, son total pour ce compte, et ses postes une fois déplié.
class _ProcessGroup extends StatefulWidget {
  final SpendDetailRow groupe;
  final double rate;

  const _ProcessGroup({super.key, required this.groupe, required this.rate});

  @override
  State<_ProcessGroup> createState() => _ProcessGroupState();
}

class _ProcessGroupState extends State<_ProcessGroup> {
  /// `null` tant que la ligne n'a pas été touchée : c'est alors le filtre qui
  /// décide de l'ouverture. Un clic fixe le choix, et le filtre ne le défait
  /// plus.
  bool? _choix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupe = widget.groupe;
    final ouvert = _choix ?? groupe.ouvertParDefaut;
    final titre = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _choix = !ouvert),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Icon(
                  ouvert ? Icons.expand_less : Icons.expand_more,
                  size: AppIconSize.inline,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    groupe.label,
                    style: titre,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${formatMoney(groupe.costUsd, widget.rate)} · '
                  '${formatCount(groupe.calls)}',
                  style: titre,
                ),
              ],
            ),
          ),
        ),
        if (ouvert)
          for (final poste in groupe.enfants)
            _SpendLine(ligne: poste, rate: widget.rate, retrait: 22),
      ],
    );
  }
}

/// Les plafonds, et ce que la journée en cours a déjà consommé.
class _BudgetCard extends StatelessWidget {
  final AiBudgetSnapshot snapshot;
  final bool saving;
  final Future<void> Function(AiBudgetPolicy) onSave;

  /// Change le jour regardé. `null` revient à la journée en cours.
  final ValueChanged<String?> onDayChanged;

  const _BudgetCard({
    required this.snapshot,
    required this.saving,
    required this.onSave,
    required this.onDayChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = snapshot.policy;
    final today = snapshot.today;
    final unpriced = today.fold<int>(0, (sum, s) => sum + s.unpricedCalls);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              policy.enabled ? Icons.speed : Icons.speed_outlined,
              color: policy.enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
            title: const Text('Plafond quotidien'),
            subtitle: Text(
              policy.enabled
                  ? '${formatEur(policy.dailyCostEurPerUser)} et '
                        '${policy.dailyCallsPerUser} appels par compte et par jour. '
                        'Le compte fondateur en a ${snapshot.founderMultiplier} fois plus.'
                  : 'Désactivé : aucune limite ne s\'applique.',
            ),
          ),
          if (snapshot.usdToEur == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Aucun taux de change relevé : le plafond en euros ne peut pas être '
                'appliqué, et les montants restent en dollars. Seul le plafond en '
                'nombre d\'appels protège pour l\'instant.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (unpriced > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '$unpriced appel${unpriced > 1 ? 's' : ''} sans montant '
                '${snapshot.isToday ? 'aujourd\'hui' : 'ce jour-là'} : '
                'la grille tarifaire n\'était pas lisible. Le plafond en nombre '
                'd\'appels prend le relais.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const Divider(height: 1),
          _DaySelector(snapshot: snapshot, onChanged: onDayChanged),
          // Sur une journée close, le plafond affiché est celui d'aujourd'hui.
          // Il a pu changer depuis, et rien ne dirait que la barre se rapporte
          // à une limite qui n'était pas celle-là.
          if (!snapshot.isToday)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Journée close : les barres rapportent la dépense de ce jour au '
                'plafond en vigueur aujourd\'hui, qui n\'est pas forcément celui '
                'qui s\'appliquait alors.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (today.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                snapshot.isToday
                    ? 'Aucun appel d\'IA aujourd\'hui.'
                    : 'Aucun appel d\'IA ce jour-là.',
              ),
            )
          else
            for (final row in today) _TodayRow(row: row, snapshot: snapshot),
          const Divider(height: 1),
          _PolicyEditor(policy: policy, saving: saving, onSave: onSave),
        ],
      ),
    );
  }
}

/// Le jour regardé, et de quoi en changer.
///
/// Le plafond est quotidien, mais l'écran ne montrait que la journée en cours :
/// une coupure de la veille — la seule qu'on cherche à comprendre, puisqu'elle
/// a déjà eu lieu — n'était visible nulle part. Les documents de dépense sont
/// écrits un par compte et par jour ; l'historique était là, sans porte.
///
/// Trois gestes : reculer d'un jour, avancer d'un jour, ouvrir le calendrier.
/// Aucun ne va au-delà d'aujourd'hui : un jour à venir n'a rien dépensé, et
/// l'afficher vide se lirait « aucun appel ».
class _DaySelector extends StatelessWidget {
  final AiBudgetSnapshot snapshot;
  final ValueChanged<String?> onChanged;

  const _DaySelector({required this.snapshot, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jour = parseSpendDay(snapshot.day);
    final aujourdhui = parseSpendDay(snapshot.currentDay);
    final titre = snapshot.isToday
        ? 'Aujourd\'hui (jour UTC ${snapshot.day})'
        : 'Jour UTC ${snapshot.day}';

    // Sans date lisible — un serveur qui ne l'envoie pas encore —, le titre
    // reste, la navigation disparaît. Mieux vaut pas de flèches que des
    // flèches qui ne mènent nulle part.
    if (jour == null || aujourdhui == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(titre, style: theme.textTheme.titleSmall),
      );
    }

    final veille = jour.subtract(const Duration(days: 1));
    final lendemain = jour.add(const Duration(days: 1));
    final peutAvancer = !lendemain.isAfter(aujourdhui);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Jour précédent',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => onChanged(formatSpendDay(veille)),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft),
              icon: const Icon(
                Icons.calendar_month_outlined,
                size: AppIconSize.small,
              ),
              label: Text(
                titre,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: () => _choisir(context, jour, aujourdhui),
            ),
          ),
          IconButton(
            tooltip: peutAvancer ? 'Jour suivant' : 'Déjà au jour courant',
            icon: const Icon(Icons.chevron_right),
            onPressed: peutAvancer
                ? () => onChanged(formatSpendDay(lendemain))
                : null,
          ),
          if (!snapshot.isToday)
            TextButton(
              onPressed: () => onChanged(null),
              child: const Text('Aujourd\'hui'),
            ),
        ],
      ),
    );
  }

  Future<void> _choisir(
    BuildContext context,
    DateTime jour,
    DateTime aujourdhui,
  ) async {
    final choisi = await showDatePicker(
      context: context,
      initialDate: jour,
      // Deux ans en arrière : la dépense quotidienne n'est écrite que depuis
      // la v0.21, et une borne large ne coûte qu'un jour vide si on remonte
      // trop loin.
      firstDate: DateTime.utc(aujourdhui.year - 2, 1, 1),
      lastDate: aujourdhui,
      helpText: 'Jour à afficher (UTC)',
      cancelText: 'Annuler',
      confirmText: 'Afficher',
    );
    if (choisi == null) return;
    // Le calendrier rend une date locale : seuls l'année, le mois et le jour
    // sont repris. Convertir le fuseau ferait glisser d'un jour le choix fait
    // à l'écran.
    onChanged(
      formatSpendDay(DateTime.utc(choisi.year, choisi.month, choisi.day)),
    );
  }
}

/// Une ligne par compte, avec sa part de plafond déjà consommée.
class _TodayRow extends StatelessWidget {
  final DailySpendRow row;
  final AiBudgetSnapshot snapshot;

  const _TodayRow({required this.row, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = snapshot.usdToEur ?? 0;
    final costLimit = snapshot.costLimitEurFor(row.uid);
    final callsLimit = snapshot.callsLimitFor(row.uid);

    // La barre montre le plus contraignant des deux plafonds : c'est celui qui
    // fermera la porte, et afficher l'autre donnerait une marge qui n'existe
    // pas. Sans taux, le plafond en euros n'entre pas dans le calcul — il ne
    // s'applique pas non plus côté serveur.
    final costRatio = (costLimit > 0 && rate > 0)
        ? (row.costUsd * rate) / costLimit
        : 0.0;
    final callsRatio = callsLimit > 0 ? row.calls / callsLimit : 0.0;
    final ratio = (costRatio > callsRatio ? costRatio : callsRatio).clamp(
      0.0,
      1.0,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.uid == snapshot.founderUid
                      ? '${row.label}  (×${snapshot.founderMultiplier})'
                      : row.label,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${formatMoney(row.costUsd, rate)} · ${row.calls} appels',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              color: ratio >= 1
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Les quatre réglages, modifiables sans redéployer.
class _PolicyEditor extends StatefulWidget {
  final AiBudgetPolicy policy;
  final bool saving;
  final Future<void> Function(AiBudgetPolicy) onSave;

  const _PolicyEditor({
    required this.policy,
    required this.saving,
    required this.onSave,
  });

  @override
  State<_PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends State<_PolicyEditor> {
  late final TextEditingController _cost = TextEditingController(
    text: widget.policy.dailyCostEurPerUser.toString(),
  );
  late final TextEditingController _calls = TextEditingController(
    text: widget.policy.dailyCallsPerUser.toString(),
  );
  late final TextEditingController _alert = TextEditingController(
    text: widget.policy.monthlyAlertEur.toString(),
  );
  late bool _enabled = widget.policy.enabled;
  String? _error;

  @override
  void dispose() {
    _cost.dispose();
    _calls.dispose();
    _alert.dispose();
    super.dispose();
  }

  void _submit() {
    final cost = double.tryParse(_cost.text.replaceAll(',', '.'));
    final calls = int.tryParse(_calls.text);
    final alert = double.tryParse(_alert.text.replaceAll(',', '.'));

    // Une saisie invalide est refusée, jamais devinée : un plafond retombé à
    // zéro par accident se lirait « aucune limite ».
    if (cost == null || calls == null || alert == null) {
      setState(() => _error = 'Trois nombres sont attendus.');
      return;
    }
    if (cost < 0 || calls < 0 || alert < 0) {
      setState(() => _error = 'Aucune valeur ne peut être négative.');
      return;
    }

    setState(() => _error = null);
    widget.onSave(
      widget.policy.copyWith(
        dailyCostEurPerUser: cost,
        dailyCallsPerUser: calls,
        monthlyAlertEur: alert,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Un plafond atteint refuse les appels d\'IA de ce compte jusqu\'au '
            'lendemain — les autres comptes ne sont pas touchés. Le plafond en '
            'nombre d\'appels existe pour tenir quand la grille tarifaire ou le '
            'taux de change manquent, et qu\'aucun montant n\'est comparable. '
            'Zéro désactive un critère.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 190,
                child: TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Euros / compte / jour',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(
                width: 190,
                child: TextField(
                  controller: _calls,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Appels / compte / jour',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(
                width: 190,
                child: TextField(
                  controller: _alert,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Alerte mensuelle (€)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text('Plafonds actifs'),
            subtitle: const Text(
              'Les couper laisse la dépense libre — le temps d\'un import massif.',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: widget.saving ? null : _submit,
              icon: widget.saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Enregistrer'),
            ),
          ),
        ],
      ),
    );
  }
}
