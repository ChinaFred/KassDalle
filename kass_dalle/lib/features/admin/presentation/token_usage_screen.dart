import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/token_usage_repository.dart';
import 'admin_providers.dart';
import '../../auth/presentation/auth_providers.dart';

/// Noms lisibles pour chaque feature Gemini.
const _featureLabels = <String, String>{
  'scan_extraction': 'Extraction de recettes',
  'text_extraction': 'Saisie texte libre',
  'detect_illustrations': 'Détection illustrations',
  'search': 'Recherche IA',
  'book_cover': 'Couverture de livre',
  'generate': 'Génération de recette',
  'refine': 'Amélioration IA',
  'web_search_query': 'Requête web',
  'classify_dish_types': 'Classification plats',
  'add_sections': 'Ajout de sections',
};

String _featureLabel(String feature) =>
    _featureLabels[feature] ?? feature;

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

class TokenUsageScreen extends ConsumerStatefulWidget {
  const TokenUsageScreen({super.key});

  @override
  ConsumerState<TokenUsageScreen> createState() => _TokenUsageScreenState();
}

class _TokenUsageScreenState extends ConsumerState<TokenUsageScreen> {
  String? _selectedUid; // null = tous les utilisateurs (admin)
  String? _selectedFeature; // null = toutes les features

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
        ],
      ),
      body: recordsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (records) {
          // Filtre côté admin
          final filterUid = isAdmin ? _selectedUid : myUid;
          var summaries = TokenUsageRepository.aggregate(
            records,
            filterUid: filterUid,
          );
          if (_selectedFeature != null) {
            summaries = summaries
                .where((s) => s.feature == _selectedFeature)
                .toList();
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
              ),
              if (isAdmin)
                _FiltersRow(
                  uids: allUids!,
                  selectedUid: _selectedUid,
                  features: _featureLabels.keys.toList(),
                  selectedFeature: _selectedFeature,
                  onUidChanged: (uid) => setState(() => _selectedUid = uid),
                  onFeatureChanged: (f) =>
                      setState(() => _selectedFeature = f),
                ),
              Expanded(
                child: _SummaryTable(
                  summaries: summaries,
                  isAdmin: isAdmin,
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

  const _SummaryBanner({
    required this.totalTokens,
    required this.totalCalls,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.secondaryContainer,
      child: Row(
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
            Icon(icon, size: 16,
                color: theme.colorScheme.onSecondaryContainer),
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
  final ValueChanged<String?> onUidChanged;
  final ValueChanged<String?> onFeatureChanged;

  const _FiltersRow({
    required this.uids,
    required this.selectedUid,
    required this.features,
    required this.selectedFeature,
    required this.onUidChanged,
    required this.onFeatureChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 8,
        children: [
          // Filtre utilisateur
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
          const SizedBox(width: 8),
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
                    child: Text(_featureLabel(f)),
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

class _SummaryTable extends ConsumerWidget {
  final List<TokenUsageSummary> summaries;
  final bool isAdmin;
  final ValueChanged<String>? onUidTap;
  final ValueChanged<String> onFeatureTap;

  const _SummaryTable({
    required this.summaries,
    required this.isAdmin,
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
            if (isAdmin) const DataColumn(label: Text('Utilisateur')),
            const DataColumn(label: Text('Feature')),
            const DataColumn(label: Text('Appels'), numeric: true),
            const DataColumn(label: Text('Tokens (in)'), numeric: true),
            const DataColumn(label: Text('Tokens (out)'), numeric: true),
            const DataColumn(label: Text('Total'), numeric: true),
          ],
          rows: summaries.map((s) {
            return DataRow(
              cells: [
                if (isAdmin)
                  DataCell(
                    InkWell(
                      onTap: () => onUidTap?.call(s.uid),
                      child: _UserNameText(uid: s.uid),
                    ),
                  ),
                DataCell(
                  InkWell(
                    onTap: () => onFeatureTap(s.feature),
                    child: Text(_featureLabel(s.feature)),
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
