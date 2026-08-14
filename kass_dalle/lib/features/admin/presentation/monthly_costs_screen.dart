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
        body: const TabBarView(
          children: [_MonthlyTab(), AiServicesTab()],
        ),
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
                _YearCard(
                  year: entry.key,
                  months: entry.value,
                  report: report,
                ),
                const SizedBox(height: 12),
              ]
            else
              for (final month in months) ...[
                _MonthCard(
                  month: month,
                  report: report,
                  maxTotal: maxTotal,
                ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reconstruire les agrégats'),
        content: Text(
          'Les ${widget.depth ?? 24} derniers mois seront recalculés depuis '
          'les lignes d\'appel. Sert à rattraper un historique antérieur au '
          'suivi mensuel, ou à réparer un mois dont les compteurs ont dérivé. '
          'Aucun coût d\'IA n\'est engagé.',
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
    );
    if (confirmed != true) return;

    setState(() => _rebuilding = true);
    try {
      // Sans profondeur choisie, on reconstruit deux ans : « depuis le début »
      // n'a de sens à la lecture que si les agrégats existent.
      final count = await ref
          .read(monthlyCostsRepositoryProvider)
          .rebuild(months: widget.depth ?? 24);
      if (!mounted) return;
      ref.invalidate(costsReportProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count mois reconstruits ✓')),
      );
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
          ),
          if (!month.internal.isEmpty) ...[
            const SizedBox(height: 16),
            _SectionTitle(title: 'Interne'),
            _AmountRow(
              label: '${formatCount(month.internal.calls)} appels hors inférence',
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
          else
            for (final service in month.services)
              _AmountRow(
                label: service.service,
                value: formatMoney(service.costUsd, rate),
              ),
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
    return report.anthropicAvailable
        ? 'L\'API d\'administration Anthropic a refusé une relecture pour '
              'limite de débit atteinte. Les montants affichés viennent du '
              'dernier relevé réussi : les mois clos restent justes, le mois '
              'en cours peut avoir augmenté depuis.'
        : 'L\'API d\'administration Anthropic a refusé la lecture pour limite '
              'de débit atteinte, et aucun relevé antérieur n\'est disponible. '
              'Réessayez dans quelques minutes : la clé, elle, fonctionne.';
  }

  if (error != null) {
    return 'La lecture du rapport de coûts Anthropic a échoué : $error';
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

  const _ProviderSection({
    required this.title,
    required this.billedBy,
    required this.cost,
    required this.usdToEur,
    this.unavailableNote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final billed = cost.billedUsd;
    final delta = cost.deltaUsd;
    final ratio = cost.deltaRatio;
    final alerting =
        delta != null && ratio != null && ratio.abs() > 0.1 && delta.abs() > 0.05;
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
          label: 'Facturé par $billedBy',
          value: billed == null ? '—' : formatMoney(billed, usdToEur),
          muted: billed == null,
        ),
        if (delta != null) ...[
          _AmountRow(
            label: ratio == null ? 'Écart' : 'Écart (${formatSignedPercent(ratio)})',
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
                // Nommer la quantité manquante plutôt que la deviner : un
                // écart en euros n'apprend rien, un écart en jetons désigne
                // le poste. La cause connue est le raisonnement, facturé au
                // tarif de sortie et compté seulement depuis peu.
                uncounted != null
                    ? '${formatCount(uncounted)} jetons de sortie facturés '
                          'que l\'application n\'a pas comptés — presque '
                          'toujours du raisonnement, facturé au tarif de '
                          'sortie. Les appels antérieurs à son comptage '
                          'resteront sous-estimés même après reconstruction : '
                          'la donnée n\'a pas été enregistrée, il n\'y a rien '
                          'à relire.'
                    : 'Un écart de cette ampleur vient de consommation non '
                          'comptée, pas d\'une erreur de tarif.',
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
      ],
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
