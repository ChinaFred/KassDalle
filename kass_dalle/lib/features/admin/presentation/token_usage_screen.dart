import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/feature_catalog.dart';
import '../data/token_usage_repository.dart';
import 'admin_providers.dart';
import '../../auth/presentation/auth_providers.dart';



/// Formate un grand nombre de tokens de manière lisible (ex : 1 234 567).
String _fmt(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202f');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// Clé de période "YYYY-MM" pour un DateTime.
String _periodKey(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}';

/// Label lisible pour une clé "YYYY-MM".
String _periodLabel(String key) {
  const monthNames = [
    'Janvier',
    'Février',
    'Mars',
    'Avril',
    'Mai',
    'Juin',
    'Juillet',
    'Août',
    'Septembre',
    'Octobre',
    'Novembre',
    'Décembre',
  ];
  final parts = key.split('-');
  final year = parts[0];
  final month = int.parse(parts[1]);
  return '${monthNames[month - 1]} $year';
}

/// Estimation énergétique : ~0,001 Wh / 1 000 tokens (LLM type Gemini).
/// Source : estimations publiées pour les modèles de langage génératifs.
double _estimateWh(int tokens) => tokens * 0.000001;

/// Formate une valeur en Wh avec l'unité adaptée.
String _fmtEnergy(int tokens) {
  final wh = _estimateWh(tokens);
  if (wh < 0.001) return '≈ ${(wh * 1000000).toStringAsFixed(1)} µWh';
  if (wh < 1) return '≈ ${(wh * 1000).toStringAsFixed(2)} mWh';
  if (wh < 1000) return '≈ ${wh.toStringAsFixed(3)} Wh';
  return '≈ ${(wh / 1000).toStringAsFixed(4)} kWh';
}

class TokenUsageScreen extends ConsumerStatefulWidget {
  const TokenUsageScreen({super.key});

  @override
  ConsumerState<TokenUsageScreen> createState() => _TokenUsageScreenState();
}

class _TokenUsageScreenState extends ConsumerState<TokenUsageScreen> {
  String? _selectedUid; // null = tous les utilisateurs (admin)
  String? _selectedFeature; // null = toutes les features
  String? _selectedPeriod; // null = toutes les périodes, format "YYYY-MM"
  String? _selectedProvider; // null = tous les moteurs

  /// Ventiler par moteur, ou globaliser.
  ///
  /// Globalisé par défaut : la question courante reste « que consomme ce
  /// poste ». La ventilation sert le jour où l'on compare deux moteurs sur le
  /// même poste — c'est un mode d'analyse, pas la vue de tous les jours.
  bool _splitByProvider = false;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final myUid = ref.watch(appUserProvider).value?.uid;

    final recordsAsync = isAdmin
        ? ref.watch(allTokenUsageProvider)
        : ref.watch(myTokenUsageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Usage des tokens IA'),
        actions: [
          if (isAdmin && _selectedUid != null)
            IconButton(
              tooltip: 'Tous les utilisateurs',
              icon: const Icon(Icons.person_off_outlined),
              onPressed: () => setState(() => _selectedUid = null),
            ),
          if (_selectedFeature != null)
            IconButton(
              tooltip: 'Toutes les features',
              icon: const Icon(Icons.filter_alt_off_outlined),
              onPressed: () => setState(() => _selectedFeature = null),
            ),
          if (_selectedPeriod != null)
            IconButton(
              tooltip: 'Toutes les périodes',
              icon: const Icon(Icons.calendar_today_outlined),
              onPressed: () => setState(() => _selectedPeriod = null),
            ),
        ],
      ),
      body: recordsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (records) {
          // Filtre par période
          final periodRecords = _selectedPeriod == null
              ? records
              : records
                    .where((r) => _periodKey(r.timestamp) == _selectedPeriod)
                    .toList();

          // Périodes disponibles (tri décroissant)
          final allPeriods =
              records.map((r) => _periodKey(r.timestamp)).toSet().toList()
                ..sort((a, b) => b.compareTo(a));

          // Filtre côté admin
          final filterUid = isAdmin ? _selectedUid : myUid;
          var summaries = TokenUsageRepository.aggregate(
            periodRecords,
            filterUid: filterUid,
            filterProvider: _selectedProvider,
            splitByProvider: _splitByProvider,
          );
          if (_selectedFeature != null) {
            summaries = summaries
                .where((s) => s.feature == _selectedFeature)
                .toList();
          }

          // Répartition par moteur sur le périmètre courant — la lecture que
          // l'écran ne permettait pas : combien de cette consommation vient de
          // quel fournisseur.
          final perProvider = <String, int>{};
          for (final r in periodRecords) {
            if (filterUid != null && r.uid != filterUid) continue;
            if (_selectedFeature != null && r.feature != _selectedFeature) {
              continue;
            }
            perProvider[r.provider] =
                (perProvider[r.provider] ?? 0) + r.totalTokens;
          }

          if (records.isEmpty) {
            return const Center(
              child: Text(
                'Aucun appel IA enregistré pour le moment.',
                textAlign: TextAlign.center,
              ),
            );
          }

          // Totaux globaux
          final totalTokens = summaries.fold(0, (s, e) => s + e.totalTokens);
          final totalCalls = summaries.fold(0, (s, e) => s + e.callCount);

          // Liste des uids distincts (admin)
          final allUids = isAdmin
              ? records.map((r) => r.uid).toSet().toList()
              : null;

          return Column(
            children: [
              _SummaryBanner(
                totalTokens: totalTokens,
                totalCalls: totalCalls,
                selectedPeriod: _selectedPeriod,
                perProvider: perProvider,
              ),
              _ProviderControls(
                perProvider: perProvider,
                selectedProvider: _selectedProvider,
                splitByProvider: _splitByProvider,
                onProviderChanged: (p) =>
                    setState(() => _selectedProvider = p),
                onSplitChanged: (v) => setState(() => _splitByProvider = v),
              ),
              _FiltersRow(
                uids: isAdmin ? allUids! : [],
                selectedUid: _selectedUid,
                features: kFeatureCatalog.keys.toList(),
                selectedFeature: _selectedFeature,
                periods: allPeriods,
                selectedPeriod: _selectedPeriod,
                isAdmin: isAdmin,
                onUidChanged: (uid) => setState(() => _selectedUid = uid),
                onFeatureChanged: (f) => setState(() => _selectedFeature = f),
                onPeriodChanged: (p) => setState(() => _selectedPeriod = p),
              ),
              Expanded(
                child: _SummaryTable(
                  summaries: summaries,
                  isAdmin: isAdmin,
                  showPeriod: _selectedPeriod == null,
                  showProvider: _splitByProvider,
                  onUidTap: isAdmin
                      ? (uid) => setState(() => _selectedUid = uid)
                      : null,
                  onFeatureTap: (f) => setState(() => _selectedFeature = f),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Bannière récapitulative ────────────────────────────────────────────────────

class _SummaryBanner extends StatelessWidget {
  final int totalTokens;
  final int totalCalls;
  final String? selectedPeriod;

  /// Tokens par fournisseur sur le périmètre courant.
  final Map<String, int> perProvider;

  const _SummaryBanner({
    required this.totalTokens,
    required this.totalCalls,
    required this.perProvider,
    this.selectedPeriod,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.secondaryContainer,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatChip(
                icon: Icons.token_outlined,
                label: _fmt(totalTokens),
                sublabel: 'tokens total',
              ),
              _StatChip(
                icon: Icons.call_outlined,
                label: _fmt(totalCalls),
                sublabel: 'appels API',
              ),
              _StatChip(
                icon: Icons.bolt_outlined,
                label: _fmtEnergy(totalTokens),
                sublabel: 'énergie estimée',
              ),
            ],
          ),
          if (perProvider.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                for (final entry
                    in (perProvider.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value))))
                  Text(
                    '${providerLabel(entry.key)} : ${_fmt(entry.value)} '
                    '(${totalTokens == 0 ? 0 : (entry.value * 100 / totalTokens).round()} %)',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Text(
            selectedPeriod != null
                ? 'Période : ${_periodLabel(selectedPeriod!)}  •  Énergie ~0,001 Wh / 1k tokens'
                : 'Énergie : estimation ~0,001 Wh / 1k tokens (LLM Gemini)',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer.withValues(
                alpha: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Text(
          sublabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ],
    );
  }
}

// ── Filtres admin ─────────────────────────────────────────────────────────────

class _FiltersRow extends ConsumerWidget {
  final List<String> uids;
  final String? selectedUid;
  final List<String> features;
  final String? selectedFeature;
  final List<String> periods;
  final String? selectedPeriod;
  final bool isAdmin;
  final ValueChanged<String?> onUidChanged;
  final ValueChanged<String?> onFeatureChanged;
  final ValueChanged<String?> onPeriodChanged;

  const _FiltersRow({
    required this.uids,
    required this.selectedUid,
    required this.features,
    required this.selectedFeature,
    required this.periods,
    required this.selectedPeriod,
    required this.isAdmin,
    required this.onUidChanged,
    required this.onFeatureChanged,
    required this.onPeriodChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          // Filtre période
          DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: selectedPeriod,
              hint: const Text('Toutes les périodes'),
              isDense: true,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Toutes les périodes'),
                ),
                ...periods.map(
                  (p) => DropdownMenuItem<String?>(
                    value: p,
                    child: Text(_periodLabel(p)),
                  ),
                ),
              ],
              onChanged: onPeriodChanged,
            ),
          ),
          // Filtre utilisateur (admin seulement)
          if (isAdmin)
            DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: selectedUid,
                hint: const Text('Tous les utilisateurs'),
                isDense: true,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Tous les utilisateurs'),
                  ),
                  ...uids.map(
                    (uid) => DropdownMenuItem<String?>(
                      value: uid,
                      child: _UserNameText(uid: uid),
                    ),
                  ),
                ],
                onChanged: onUidChanged,
              ),
            ),
          // Filtre feature
          DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: selectedFeature,
              hint: const Text('Toutes les features'),
              isDense: true,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Toutes les features'),
                ),
                ...features.map(
                  (f) => DropdownMenuItem<String?>(
                    value: f,
                    child: Text(featureLabel(f)),
                  ),
                ),
              ],
              onChanged: onFeatureChanged,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tableau des agrégats ──────────────────────────────────────────────────────

/// Contrôles propres au moteur : filtrer sur l'un, ou ventiler les lignes.
///
/// Deux gestes distincts, volontairement séparés. Filtrer répond à « que
/// consomme Claude » ; ventiler répond à « sur ce poste, qu'est-ce que chacun
/// consomme » — et c'est la seconde qui permet de juger une bascule.
class _ProviderControls extends StatelessWidget {
  final Map<String, int> perProvider;
  final String? selectedProvider;
  final bool splitByProvider;
  final ValueChanged<String?> onProviderChanged;
  final ValueChanged<bool> onSplitChanged;

  const _ProviderControls({
    required this.perProvider,
    required this.selectedProvider,
    required this.splitByProvider,
    required this.onProviderChanged,
    required this.onSplitChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providers = perProvider.keys.toList()..sort();
    // Un seul moteur dans les données : ces contrôles n'auraient rien à régler.
    if (providers.length < 2 && selectedProvider == null && !splitByProvider) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: selectedProvider,
              hint: const Text('Tous les moteurs'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Tous les moteurs'),
                ),
                ...providers.map(
                  (p) => DropdownMenuItem(
                    value: p,
                    child: Text(providerLabel(p)),
                  ),
                ),
              ],
              onChanged: onProviderChanged,
            ),
          ),
          FilterChip(
            selected: splitByProvider,
            onSelected: onSplitChanged,
            avatar: const Icon(Icons.call_split_outlined, size: 18),
            label: const Text('Ventiler par moteur'),
            tooltip: splitByProvider
                ? 'Une ligne par moteur : comparez ce que chacun consomme sur le même poste.'
                : 'Lignes globalisées, tous moteurs confondus.',
          ),
          if (!splitByProvider)
            Text(
              'Totaux globalisés',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryTable extends ConsumerWidget {
  final List<TokenUsageSummary> summaries;
  final bool isAdmin;
  final bool showPeriod;

  /// La colonne Moteur n'apparaît qu'en vue ventilée : globalisée, chaque
  /// ligne agrège plusieurs fournisseurs et la colonne n'aurait rien à dire.
  final bool showProvider;
  final ValueChanged<String>? onUidTap;
  final ValueChanged<String> onFeatureTap;

  const _SummaryTable({
    required this.summaries,
    required this.isAdmin,
    required this.showPeriod,
    required this.showProvider,
    required this.onUidTap,
    required this.onFeatureTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (summaries.isEmpty) {
      return const Center(child: Text('Aucun résultat pour ce filtre.'));
    }
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 20,
          headingRowColor: WidgetStatePropertyAll(
            theme.colorScheme.surfaceContainerHighest,
          ),
          columns: [
            if (showPeriod) const DataColumn(label: Text('Période')),
            if (isAdmin) const DataColumn(label: Text('Utilisateur')),
            if (showProvider) const DataColumn(label: Text('Moteur')),
            const DataColumn(label: Text('Feature')),
            const DataColumn(label: Text('Appels'), numeric: true),
            const DataColumn(label: Text('Tokens (in)'), numeric: true),
            const DataColumn(label: Text('Tokens (out)'), numeric: true),
            const DataColumn(label: Text('Total'), numeric: true),
          ],
          rows: summaries.map((s) {
            return DataRow(
              cells: [
                if (showPeriod) DataCell(Text(_periodLabel(s.period))),
                if (isAdmin)
                  DataCell(
                    InkWell(
                      onTap: () => onUidTap?.call(s.uid),
                      child: _UserNameText(uid: s.uid),
                    ),
                  ),
                if (showProvider)
                  DataCell(
                    Text(
                      s.provider == null ? '—' : providerLabel(s.provider!),
                      style: TextStyle(
                        color: s.provider == 'anthropic'
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                DataCell(
                  InkWell(
                    onTap: () => onFeatureTap(s.feature),
                    child: Tooltip(
                      message: featureDescription(s.feature),
                      child: Text(featureLabel(s.feature)),
                    ),
                  ),
                ),
                DataCell(Text(_fmt(s.callCount))),
                DataCell(Text(_fmt(s.totalInputTokens))),
                DataCell(Text(_fmt(s.totalOutputTokens))),
                DataCell(
                  Text(
                    _fmt(s.totalTokens),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ── Nom d'utilisateur depuis UID ──────────────────────────────────────────────

class _UserNameText extends ConsumerWidget {
  final String uid;
  const _UserNameText({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userByUidProvider(uid));
    final name = userAsync.value?.displayName ?? uid.substring(0, 8);
    return Text(name, overflow: TextOverflow.ellipsis);
  }
}