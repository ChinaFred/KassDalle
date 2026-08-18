import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';
import '../data/monthly_costs_repository.dart';
import 'ai_services_tab.dart';
import 'costs_format.dart';

/// Ce que coûte l'application, mois par mois.
///
/// Trois natures de dépense, présentées côte à côte et sous la même forme :
/// **Claude** et **Gemini**, que l'application mesure appel par appel et que
/// leurs fournisseurs facturent séparément, et l'**infrastructure** (Functions,
/// Storage, Tasks…), que seule la facturation Google connaît et qui ne se
/// ventile que par service.
///
/// Gemini arrive par la même facture que l'infrastructure sans en être : le
/// laisser noyé dans une liste de services rendait impossible la seule
/// comparaison qui compte, celle des deux moteurs entre eux.
///
/// Aucun montant n'est calculé ici. Ils viennent des agrégats mensuels, où le
/// coût a été figé au moment de l'appel.

final monthlyCostsRepositoryProvider = Provider<MonthlyCostsRepository>(
  (ref) => MonthlyCostsRepository(),
);

/// Profondeur d'historique demandée.
///
/// `null` signifie « depuis le début » : la série remonte alors au premier
/// appel jamais enregistré.
class CostsDepthNotifier extends Notifier<int?> {
  @override
  int? build() => 12;

  void set(int? months) => state = months;
}

final costsDepthProvider = NotifierProvider<CostsDepthNotifier, int?>(
  CostsDepthNotifier.new,
);

/// Regroupement de l'affichage : mois par mois, ou année par année.
enum CostsGrouping { month, year }

class CostsGroupingNotifier extends Notifier<CostsGrouping> {
  @override
  CostsGrouping build() => CostsGrouping.month;

  void set(CostsGrouping grouping) => state = grouping;
}

final costsGroupingProvider =
    NotifierProvider<CostsGroupingNotifier, CostsGrouping>(
      CostsGroupingNotifier.new,
    );

/// Le rapport, pour une profondeur donnée.
///
/// Indexé par la profondeur et non par un état global : chaque onglet choisit
/// la sienne. Deux onglets qui partageaient un même filtre obligeaient à
/// revenir sur le premier pour changer la période du second — et deux onglets
/// demandant la même profondeur se partagent tout de même une seule lecture.
final costsReportProvider = FutureProvider.autoDispose
    .family<MonthlyCostsReport, int?>((ref, months) async {
      return ref
          .watch(monthlyCostsRepositoryProvider)
          .fetch(months: months ?? 12, all: months == null);
    });

/// Taux à appliquer à un mois : le sien, ou le plus récent connu à défaut.
///
/// Un mois sans ligne de facturation Google n'a pas de taux propre. Le laisser
/// sans conversion afficherait des dollars au milieu d'euros ; le convertir au
/// dernier taux connu donne un ordre de grandeur juste et le dit.
double rateFor(MonthlyCost month, MonthlyCostsReport report) =>
    month.usdToEur > 0 ? month.usdToEur : report.latestRate;

/// Choix de la profondeur d'historique, en puces.
///
/// Partagé par les deux onglets, chacun avec son propre état : c'est le geste
/// le plus fréquent de l'écran, il doit rester sous la main là où on regarde.
class CostsDepthChips extends StatelessWidget {
  final int? depth;
  final ValueChanged<int?> onChanged;

  const CostsDepthChips({
    super.key,
    required this.depth,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final months in const [1, 3, 6, 12])
          ChoiceChip(
            label: Text(months == 1 ? 'Ce mois' : '$months mois'),
            selected: depth == months,
            onSelected: (_) => onChanged(months),
          ),
        ChoiceChip(
          label: const Text('Depuis le début'),
          selected: depth == null,
          onSelected: (_) => onChanged(null),
        ),
      ],
    );
  }
}

class MonthlyCostsScreen extends ConsumerWidget {
  const MonthlyCostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Deux onglets, pas trois. Le troisième — « Réconciliation » — ne
    // comparait que la part Gemini : on y cherchait Claude et l'infrastructure
    // sans les trouver, et un contrôle qui ne porte que sur la moitié de la
    // dépense se lit comme un contrôle sur la totalité. La confrontation à la
    // facture vit désormais dans « Mois par mois », où les deux moteurs ont la
    // même forme et l'infrastructure sa section.
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Coûts de l\'application'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Mois par mois'),
              Tab(text: 'Par service IA'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Rafraîchir',
              icon: const Icon(Icons.refresh),
              // Toute la famille : les deux onglets peuvent regarder des
              // profondeurs différentes, et n'en rafraîchir qu'une laisserait
              // l'autre sur des chiffres périmés sans le dire.
              onPressed: () => ref.invalidate(costsReportProvider),
            ),
          ],
        ),
        body: const TabBarView(children: [_MonthlyTab(), AiServicesTab()]),
      ),
    );
  }
}

class _MonthlyTab extends ConsumerWidget {
  const _MonthlyTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final depth = ref.watch(costsDepthProvider);
    final reportAsync = ref.watch(costsReportProvider(depth));

    return reportAsync.render(
      loadingLabel: 'Lecture des coûts…',
      onRetry: () => ref.invalidate(costsReportProvider),
      data: (report) {
        final grouping = ref.watch(costsGroupingProvider);
        final months = report.months.reversed.toList(growable: false);
        final maxTotal = months.fold<double>(
          0,
          (max, m) => m.totalCostUsd > max ? m.totalCostUsd : max,
        );

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Header(report: report, depth: depth, grouping: grouping),
            if (report.gcpQueryFailed) ...[
              const SizedBox(height: 12),
              _Warning(
                text:
                    'La facturation Google n\'a pas pu être lue : les montants '
                    'd\'infrastructure et le facturé Gemini de cet écran sont '
                    'incomplets.',
              ),
            ],
            if (report.gcpTruncated) ...[
              const SizedBox(height: 12),
              _Warning(
                text:
                    'L\'historique d\'IA remonte plus loin que la facturation '
                    'Google : les mois les plus anciens n\'affichent aucun coût '
                    'd\'infrastructure, faute d\'export disponible.',
              ),
            ],
            const SizedBox(height: 16),
            if (grouping == CostsGrouping.year)
              for (final entry in report.byYear.entries) ...[
                _YearCard(year: entry.key, months: entry.value, report: report),
                const SizedBox(height: 12),
              ]
            else
              for (final month in months) ...[
                _MonthCard(month: month, report: report, maxTotal: maxTotal),
                const SizedBox(height: 12),
              ],
            if (months.isEmpty)
              const AppEmptyState(
                icon: Icons.euro_outlined,
                title: 'Aucun coût enregistré',
                message:
                    'Aucun appel n\'a encore été comptabilisé sur la période. '
                    'Si l\'historique existe mais n\'apparaît pas, '
                    'reconstruisez les agrégats.',
              ),
          ],
        );
      },
    );
  }
}

class _Header extends ConsumerStatefulWidget {
  final MonthlyCostsReport report;
  final int? depth;
  final CostsGrouping grouping;

  const _Header({
    required this.report,
    required this.depth,
    required this.grouping,
  });

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  bool _rebuilding = false;

  Future<void> _rebuild() async {
    // Deux réparations différentes derrière un même bouton : recompter les
    // appels, ou les rechiffrer. La seconde réécrit des montants déjà publiés
    // et ne se justifie que si la grille tarifaire était fausse — elle mérite
    // donc un choix explicite, pas une case cochée d'avance.
    var recompute = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reconstruire les agrégats'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Les ${widget.depth ?? 24} derniers mois seront recalculés '
                'depuis les lignes d\'appel. Sert à rattraper un historique '
                'antérieur au suivi mensuel, ou à réparer un mois dont les '
                'compteurs ont dérivé. Aucun coût d\'IA n\'est engagé.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: recompute,
                onChanged: (value) =>
                    setDialogState(() => recompute = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Rechiffrer aussi les appels'),
                subtitle: const Text(
                  'Applique la grille tarifaire actuelle au lieu du coût figé '
                  'lors de l\'appel. À cocher seulement si la grille était '
                  'fausse : cela réécrit des montants déjà publiés.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reconstruire'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() => _rebuilding = true);
    try {
      // Sans profondeur choisie, on reconstruit deux ans : « depuis le début »
      // n'a de sens à la lecture que si les agrégats existent.
      final count = await ref
          .read(monthlyCostsRepositoryProvider)
          .rebuild(months: widget.depth ?? 24, recomputeCosts: recompute);
      if (!mounted) return;
      ref.invalidate(costsReportProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$count mois reconstruits ✓')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(shortErrorMessage(error))));
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = widget.report;

    // Chaque mois est converti à son propre taux avant d'être additionné :
    // appliquer le cours d'aujourd'hui à la dépense de l'an dernier donnerait
    // un total que personne n'a payé.
    var totalEur = 0.0;
    var tokens = 0;
    for (final month in report.months) {
      totalEur += month.totalCostUsd * rateFor(month, report);
      tokens += month.totalTokens;
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.depth == null
                  ? 'Total depuis le début'
                  : 'Total sur la période',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              report.latestRate > 0
                  ? formatEur(totalEur)
                  : formatMoney(report.totalCostUsd, 0),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            _ProviderSplit(report: report),
            const SizedBox(height: 12),
            _EnergyLine(tokens: tokens),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CostsDepthChips(
                  depth: widget.depth,
                  onChanged: (months) =>
                      ref.read(costsDepthProvider.notifier).set(months),
                ),
                const SizedBox(width: 8),
                // Le regroupement ne change que la lecture : les mêmes mois,
                // additionnés ou détaillés.
                SegmentedButton<CostsGrouping>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: CostsGrouping.month,
                      label: Text('Par mois'),
                    ),
                    ButtonSegment(
                      value: CostsGrouping.year,
                      label: Text('Par année'),
                    ),
                  ],
                  selected: {widget.grouping},
                  onSelectionChanged: (values) => ref
                      .read(costsGroupingProvider.notifier)
                      .set(values.first),
                ),
                const SizedBox(width: 8),
                if (_rebuilding)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _rebuild,
                    icon: const Icon(Icons.build_outlined, size: 18),
                    label: const Text('Reconstruire les agrégats'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Jetons consommés et énergie estimée.
///
/// Une consommation qu'aucun écran ne montre est une consommation qui ne
/// baisse jamais. Le chiffre est un ordre de grandeur, pas une mesure : aucun
/// fournisseur ne facture l'électricité au jeton.
class _EnergyLine extends StatelessWidget {
  final int tokens;

  const _EnergyLine({required this.tokens});

  @override
  Widget build(BuildContext context) {
    if (tokens == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          Icons.bolt_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${formatCount(tokens)} jetons · ${formatEnergy(tokens)} '
            '(estimation ~0,001 Wh / 1 000 jetons)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Répartition du total : Claude, Gemini, infrastructure.
class _ProviderSplit extends StatelessWidget {
  final MonthlyCostsReport report;

  const _ProviderSplit({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var claude = 0.0;
    var gemini = 0.0;
    var interne = 0.0;
    var infra = 0.0;
    for (final month in report.months) {
      final rate = rateFor(month, report);
      claude += month.anthropic.effectiveUsd * rate;
      gemini += month.gemini.effectiveUsd * rate;
      interne += month.internal.effectiveUsd * rate;
      infra += month.gcpCostUsd * rate;
    }

    final parts = <MapEntry<String, double>>[
      MapEntry('Claude', claude),
      MapEntry('Gemini', gemini),
      MapEntry('Infrastructure', infra),
      MapEntry('Interne', interne),
    ]..removeWhere((entry) => entry.value <= 0);

    if (parts.isEmpty || report.latestRate <= 0) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final part in parts)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(
              '${part.key} · ${formatEur(part.value)}',
              style: theme.textTheme.labelMedium,
            ),
          ),
      ],
    );
  }
}

/// Une année repliée : le total, puis ses mois au détail.
class _YearCard extends StatelessWidget {
  final String year;
  final List<MonthlyCost> months;
  final MonthlyCostsReport report;

  const _YearCard({
    required this.year,
    required this.months,
    required this.report,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var total = 0.0;
    var claude = 0.0;
    var gemini = 0.0;
    var infra = 0.0;
    var tokens = 0;
    for (final month in months) {
      final rate = rateFor(month, report);
      total += month.totalCostUsd * rate;
      claude += month.anthropic.effectiveUsd * rate;
      gemini += month.gemini.effectiveUsd * rate;
      infra += month.gcpCostUsd * rate;
      tokens += month.totalTokens;
    }
    final calls = months.fold<int>(0, (sum, m) => sum + m.aiCalls);
    final ordered = [...months]..sort((a, b) => b.period.compareTo(a.period));
    final maxTotal = months.fold<double>(
      0,
      (max, m) => m.totalCostUsd > max ? m.totalCostUsd : max,
    );

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                year,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(formatEur(total), style: theme.textTheme.titleMedium),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Claude ${formatEur(claude)} · Gemini ${formatEur(gemini)} · '
            'Infra ${formatEur(infra)}\n'
            '${formatCount(calls)} appels · ${months.length} mois · '
            '${formatCount(tokens)} jetons · ${formatEnergy(tokens)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        children: [
          for (final month in ordered) ...[
            _MonthCard(month: month, report: report, maxTotal: maxTotal),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  final MonthlyCost month;
  final MonthlyCostsReport report;
  final double maxTotal;

  const _MonthCard({
    required this.month,
    required this.report,
    required this.maxTotal,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = rateFor(month, report);
    final ratio = maxTotal > 0 ? (month.totalCostUsd / maxTotal) : 0.0;

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                month.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              formatMoney(month.totalCostUsd, rate),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Barre proportionnelle au mois le plus cher : la comparaison
              // d'un mois à l'autre se fait d'un coup d'œil, sans lire les
              // chiffres.
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Claude ${formatMoney(month.anthropic.effectiveUsd, rate)} · '
                'Gemini ${formatMoney(month.gemini.effectiveUsd, rate)} · '
                'Infra ${formatMoney(month.gcpCostUsd, rate)}\n'
                '${formatCount(month.aiCalls)} appels'
                '${month.failedCalls > 0 ? ' (dont ${formatCount(month.failedCalls)} en échec)' : ''} · '
                '${formatCount(month.totalTokens)} jetons · '
                '${formatEnergy(month.totalTokens)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          // Les deux moteurs, sous la même forme : estimé, facturé, écart.
          // C'est cette symétrie qui permet de juger une bascule de l'un vers
          // l'autre — l'ancien écran noyait Gemini dans la liste des services
          // Google, où il n'était comparable à rien.
          _ProviderSection(
            title: 'Claude',
            billedBy: 'Anthropic',
            cost: month.anthropic,
            usdToEur: rate,
            unavailableNote: _anthropicNote(report),
            // La relecture vit dans le mois, pas en tête d'écran : c'est ce
            // montant-là qu'on veut vérifier, et ne relire qu'un mois coûte
            // une requête là où relire l'année en coûte treize.
            refreshPeriod: month.period,
          ),
          const SizedBox(height: 16),
          _ProviderSection(
            title: 'Gemini',
            billedBy: 'Google',
            cost: month.gemini,
            usdToEur: rate,
            unavailableNote: report.gcpQueryFailed
                ? 'La facturation Google n\'a pas pu être lue : le montant '
                      'facturé est inconnu, pas nul.'
                : null,
            // Avant le 14 août, les jetons de raisonnement n'étaient pas
            // enregistrés. L'écart d'un mois antérieur est un fait acquis,
            // pas une piste à suivre.
            settledGap: month.predatesThinkingCount
                ? 'Ce mois est antérieur au comptage des jetons de '
                      'raisonnement : Gemini les facture au tarif de sortie, '
                      'et l\'application ne les lisait pas encore. L\'écart '
                      'est définitif — la donnée n\'a jamais été enregistrée, '
                      'aucune reconstruction ne la fera apparaître.'
                : month.spansThinkingCount
                ? 'Le comptage des jetons de raisonnement a commencé pendant '
                      'ce mois : les appels du début n\'en portent pas, ceux '
                      'de la fin oui. L\'écart se résorbera de lui-même le '
                      'mois prochain.'
                : null,
          ),
          if (!month.internal.isEmpty) ...[
            const SizedBox(height: 16),
            _SectionTitle(title: 'Interne'),
            _AmountRow(
              label:
                  '${formatCount(month.internal.calls)} appels hors inférence',
              value: formatMoney(month.internal.estimatedUsd, rate),
            ),
          ],
          const SizedBox(height: 16),
          _SectionTitle(title: 'Infrastructure'),
          if (month.services.isEmpty)
            Text(
              'Aucun coût d\'infrastructure sur ce mois.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            for (final service in month.services)
              _AmountRow(
                label: service.service,
                value: formatMoney(service.costUsd, rate),
              ),
            // Un total explicite, parce que « Invoice » ressemble à s'y
            // méprendre à une ligne de synthèse alors que c'en est une comme
            // les autres — celle des taxes et ajustements de facture. La
            // somme, elle, doit être nommée.
            const Divider(height: 16),
            _AmountRow(
              label: 'Total infrastructure',
              value: formatMoney(month.gcpCostUsd, rate),
              bold: true,
            ),
          ],
          // Pas de ventilation par poste ici : l'onglet « Par service IA » la
          // donne, en mieux — nombre d'appels et coût unitaire, moteur par
          // moteur — et il se filtre sur ce mois. Deux lectures du même
          // chiffre dans deux formats différents finissent par diverger, et
          // c'est toujours la plus pauvre qu'on lit en premier.
        ],
      ),
    );
  }
}

/// Âge d'un relevé, en français courant.
String _relativeAge(DateTime at) {
  final elapsed = DateTime.now().difference(at);
  if (elapsed.inMinutes < 1) return 'à l\'instant';
  if (elapsed.inMinutes < 60) return 'il y a ${elapsed.inMinutes} min';
  if (elapsed.inHours < 24) return 'il y a ${elapsed.inHours} h';
  return 'il y a ${elapsed.inDays} j';
}

/// Ce qu'il faut dire quand le facturé Anthropic manque ou date.
///
/// Trois situations que l'écran confondait en une phrase, alors qu'elles se
/// règlent à trois endroits différents : pas de clé (Secret Manager), clé
/// refusée (console Anthropic), et limite de débit atteinte (rien à faire,
/// sinon attendre). Une seule formulation pour les trois faisait chercher du
/// mauvais côté.
String? _anthropicNote(MonthlyCostsReport report) {
  final error = report.anthropicError;

  if (error != null && error.contains('429')) {
    // Une limite de débit n'est pas une panne : la lecture avance par
    // tranches, ce qui a été relevé est conservé, et la suite arrive d'un
    // affichage à l'autre. Le dire ainsi évite de faire chercher une cause
    // qui n'existe pas.
    return report.anthropicAvailable
        ? 'Anthropic limite le débit de son API d\'administration : les mois '
              'sont relevés par tranches, à chaque ouverture de cet écran. Ce '
              'qui est affiché est acquis ; le reste se complètera.'
        : 'Anthropic limite le débit de son API d\'administration et rien n\'a '
              'encore pu être relevé. Rouvrez l\'écran dans quelques minutes : '
              'la lecture reprendra là où elle s\'est arrêtée, et la clé, elle, '
              'fonctionne.';
  }

  if (error != null) {
    return 'La lecture du rapport de coûts Anthropic a échoué : $error';
  }

  if (report.anthropicPartial) {
    return 'Tous les mois n\'ont pas encore été relevés chez Anthropic : la '
        'lecture avance par tranches pour ménager la limite de débit de son '
        'API, et se complètera aux prochaines ouvertures de cet écran.';
  }

  if (report.anthropicStale) {
    return 'Les montants Anthropic viennent du dernier relevé réussi.';
  }

  if (!report.anthropicAvailable) {
    return 'Aucune clé d\'administration Anthropic n\'est posée dans Secret '
        'Manager (secret ANTHROPIC_ADMIN_KEY, valeur commençant par '
        'sk-ant-admin). L\'estimation reste affichée, elle n\'est simplement '
        'confrontée à rien.';
  }

  return null;
}

/// Un moteur d'IA sur un mois : estimé, facturé, écart.
class _ProviderSection extends StatelessWidget {
  final String title;
  final String billedBy;
  final ProviderCost cost;
  final double usdToEur;

  /// Précision affichée quand le facturé manque pour une raison connue.
  final String? unavailableNote;

  /// Période `AAAA-MM` à relire chez le fournisseur, quand c'est possible.
  final String? refreshPeriod;

  /// Explication d'un écart déjà connu et définitif.
  ///
  /// Renseignée, elle remplace l'alerte : un écart dont la cause est établie
  /// et irréparable n'est pas une anomalie à instruire, et le peindre en rouge
  /// à chaque affichage finit par masquer celui qui en serait une.
  final String? settledGap;

  const _ProviderSection({
    required this.title,
    required this.billedBy,
    required this.cost,
    required this.usdToEur,
    this.unavailableNote,
    this.refreshPeriod,
    this.settledGap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final billed = cost.billedUsd;
    final delta = cost.deltaUsd;
    final ratio = cost.deltaRatio;
    // Un relevé daté rend l'écart ininterprétable : les appels comptés depuis
    // n'y figurent pas, et l'écran accuserait la grille tarifaire d'une
    // différence qui n'est qu'un décalage d'horloge.
    final alerting =
        delta != null &&
        ratio != null &&
        ratio.abs() > 0.1 &&
        delta.abs() > 0.05 &&
        !cost.billedIsDated &&
        settledGap == null;
    final uncounted = cost.uncountedOutputTokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: title),
        _AmountRow(
          label: 'Estimé par l\'application',
          value: formatMoney(cost.estimatedUsd, usdToEur),
        ),
        _AmountRow(
          label: cost.billedAt == null
              ? 'Facturé par $billedBy'
              : 'Facturé par $billedBy — relevé ${_relativeAge(cost.billedAt!)}',
          value: billed == null ? '—' : formatMoney(billed, usdToEur),
          muted: billed == null,
        ),
        if (delta != null && settledGap != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              settledGap!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (delta != null && settledGap == null && cost.billedIsDated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Le relevé date : les appels comptés depuis n\'y figurent pas, '
              'et l\'écart ci-dessous ne mesure donc rien de fiable. '
              'Relisez le mois pour comparer deux chiffres du même instant.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (delta != null) ...[
          _AmountRow(
            label: ratio == null
                ? 'Écart'
                : 'Écart (${formatSignedPercent(ratio)})',
            value:
                '${delta >= 0 ? '+' : '−'}'
                '${formatMoney(delta.abs(), usdToEur)}',
            bold: true,
            // Un écart de quelques centimes est du bruit d'arrondi ; au-delà
            // d'un dixième de la facture, c'est la grille tarifaire ou un
            // appel non compté qui dérive.
            alert: alerting,
          ),
          if (alerting)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // Un écart se lit dans les deux sens, et les deux causes sont
                // opposées : facturé au-delà de l'estimé, c'est de la
                // consommation qu'on n'a pas vue ; estimé au-delà du facturé,
                // c'est la grille tarifaire qui est trop chère. Le message
                // précédent ne connaissait que le premier cas et envoyait
                // chercher des jetons manquants là où il n'en manquait aucun.
                delta > 0
                    ? (uncounted != null
                          ? '${formatCount(uncounted)} jetons de sortie '
                                'facturés que l\'application n\'a pas comptés '
                                '— presque toujours du raisonnement, facturé '
                                'au tarif de sortie. Les appels antérieurs à '
                                'son comptage resteront sous-estimés même '
                                'après reconstruction : la donnée n\'a pas été '
                                'enregistrée, il n\'y a rien à relire.'
                          : 'Le fournisseur facture plus que ce que '
                                'l\'application a compté : de la consommation '
                                'nous échappe.')
                    : 'L\'application compte plus que ce que le fournisseur '
                          'facture. Les jetons, eux, concordent : c\'est donc '
                          'la grille tarifaire qui est trop chère — un tarif '
                          'promotionnel en cours, ou un prix catalogue '
                          'périmé.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
        if (cost.calls > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${formatCount(cost.calls)} appels · '
              '${formatCount(cost.inputTokens)} jetons d\'entrée · '
              '${formatCount(cost.outputTokens)} de sortie'
              // Le raisonnement est facturé au prix de la sortie sans jamais
              // apparaître dans une réponse : le nommer est la seule façon de
              // comprendre une facture qui dépasse ce que l'écran montre.
              '${cost.thinkingTokens > 0 ? ' · ${formatCount(cost.thinkingTokens)} de raisonnement' : ''}'
              // Le cache n'apparaît que s'il existe. Aucun prompt du projet
              // n'en demande : une ligne non nulle ici veut dire qu'un prompt
              // en pose un — ce sont des jetons d'entrée facturés à un autre
              // tarif, invisibles tant qu'on ne lit que `input_tokens`.
              '${cost.cacheWriteTokens > 0 ? ' · ${formatCount(cost.cacheWriteTokens)} écrits en cache' : ''}'
              '${cost.cacheReadTokens > 0 ? ' · ${formatCount(cost.cacheReadTokens)} relus du cache' : ''}'
              ' · ${formatEnergy(cost.totalTokens)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (cost.billedLines.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Détail de la facture $billedBy',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (final line in cost.billedLines)
            _AmountRow(
              label: line.amount > 0 && line.unit.isNotEmpty
                  ? '${line.label} — ${formatCount(line.amount)} ${line.unit}'
                  : line.label,
              value: formatMoney(line.costUsd, usdToEur),
              muted: true,
            ),
        ],
        if (unavailableNote != null) ...[
          const SizedBox(height: 6),
          Text(
            unavailableNote!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (refreshPeriod != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: _RefreshBilledButton(
              period: refreshPeriod!,
              billedBy: billedBy,
            ),
          ),
        ],
      ],
    );
  }
}

/// Relit chez le fournisseur le montant facturé d'un mois précis.
///
/// Un mois clos est mémorisé une fois pour toutes — c'est ce qui évite le 429.
/// Reste le cas rare où il bouge quand même : une correction rétroactive, un
/// avoir. Sans ce bouton, le cache masquerait la correction indéfiniment.
class _RefreshBilledButton extends ConsumerStatefulWidget {
  final String period;
  final String billedBy;

  const _RefreshBilledButton({required this.period, required this.billedBy});

  @override
  ConsumerState<_RefreshBilledButton> createState() =>
      _RefreshBilledButtonState();
}

class _RefreshBilledButtonState extends ConsumerState<_RefreshBilledButton> {
  bool _running = false;

  Future<void> _refresh() async {
    setState(() => _running = true);
    try {
      // Une lecture forcée qui remplit le cache, puis une invalidation pour
      // que tous les onglets relisent ce cache — le montant corrigé apparaît
      // partout, sans seconde requête chez le fournisseur.
      final depth = ref.read(costsDepthProvider);
      await ref
          .read(monthlyCostsRepositoryProvider)
          .fetch(
            months: depth ?? 12,
            all: depth == null,
            refreshAnthropicPeriods: [widget.period],
          );
      if (!mounted) return;
      ref.invalidate(costsReportProvider);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(shortErrorMessage(error))));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_running) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return TextButton.icon(
      onPressed: _refresh,
      icon: const Icon(Icons.sync, size: 16),
      label: Text('Relire ce mois chez ${widget.billedBy}'),
    );
  }
}

class _AmountRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final bool muted;
  final bool alert;

  const _AmountRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.muted = false,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: bold ? FontWeight.w600 : null,
      color: alert
          ? theme.colorScheme.error
          : muted
          ? theme.colorScheme.onSurfaceVariant
          : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 12),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  final String text;

  const _Warning({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

String providerLabel(String provider) => switch (provider) {
  'anthropic' => 'Claude',
  'gemini' => 'Gemini',
  'internal' => 'Interne',
  _ => provider,
};
