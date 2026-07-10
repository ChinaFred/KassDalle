import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';

class NutritionIngredientsScreen extends ConsumerStatefulWidget {
  const NutritionIngredientsScreen({super.key});

  @override
  ConsumerState<NutritionIngredientsScreen> createState() =>
      _NutritionIngredientsScreenState();
}

class _NutritionIngredientsScreenState
    extends ConsumerState<NutritionIngredientsScreen> {
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ingredientsAsync = ref.watch(allNutritionIngredientsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Nutrition Ingredients')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Rechercher par ID (ex: sucre, huile_olive)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _search = value.trim()),
            ),
          ),
          Expanded(
            child: ingredientsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Erreur: $e')),
              data: (items) {
                final query = _search.toLowerCase();
                final filtered = query.isEmpty
                    ? items
                    : items
                          .where((x) => x.id.toLowerCase().contains(query))
                          .toList(growable: false);

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text('Aucun ingredient nutrition trouve.'),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final doc = filtered[index];
                    final keys = doc.per100g.keys.toList()..sort();
                    final subtitle = keys.isEmpty
                        ? 'Aucune valeur per100g'
                        : keys
                              .take(8)
                              .map((k) {
                                final v = doc.per100g[k]!;
                                return '$k=${v.toStringAsFixed(2)}';
                              })
                              .join(' · ');

                    return Card(
                      child: ExpansionTile(
                        title: Text(doc.id),
                        subtitle: Text(
                          'source: ${doc.source.isEmpty ? 'n/a' : doc.source} · $subtitle',
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        children: [
                          if (keys.isEmpty)
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Aucune donnee nutritionnelle detaillee.'),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final key in keys)
                                  Chip(
                                    label: Text(
                                      '$key: ${doc.per100g[key]!.toStringAsFixed(2)}',
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
