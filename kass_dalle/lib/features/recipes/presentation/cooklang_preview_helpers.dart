import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../../core/utils/ingredient_display.dart';

/// Groupe d'étapes de préparation (correspondant à une section == ... ==).
class CooklangStepGroup {
  final String? name; // null = étapes sans section
  final List<String> steps;
  CooklangStepGroup(this.name, this.steps);
}

/// Normalise les timers mal formés dans une étape CookLang :
/// - Timers écrits en texte brut : "3%minutes" → "~{3%minutes}"
/// - Timers avec nom : "~cuisson{3%minutes}" → déjà gérés par la regex étendue
///
/// N'affecte pas les contenus déjà dans des accolades `{}`.
String cooklangNormalizeStepTimers(String step) {
  return step.replaceAllMapped(
    RegExp(
      r'(?<![{@#~\d])([1-9]\d*(?:[,./]\d+)?(?:\s+à\s+\d+)?)\s*%\s*(minutes?|min\b|heures?|h(?![a-zA-Z])|secondes?|sec\b)',
      caseSensitive: false,
    ),
    (m) => '~{${m.group(1)!.trim()}%${m.group(2)!.trim()}}',
  );
}

/// Formate un timer CookLang en texte lisible.
/// Supporte deux formats :
/// - hh:mm:ss → "0:30:00" → "30 minutes", "1:30:00" → "1h30"
/// - qty%unité → "30%minutes" → "30 min", "5 à 8%min" → "5 à 8 min"
String cooklangFormatTimer(String raw) {
  final trimmed = raw.trim();

  // Format hh:mm:ss
  final parts = trimmed.split(':');
  if (parts.length == 3) {
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2]) ?? 0;
    if (h == 0 && m == 0 && s == 0) return trimmed;
    if (h == 0 && s == 0) return m == 1 ? '1 minute' : '$m minutes';
    if (h > 0 && m == 0 && s == 0) return h == 1 ? '1 heure' : '$h heures';
    if (h > 0 && m > 0 && s == 0) {
      return '${h}h${m.toString().padLeft(2, '0')}';
    }
    if (h == 0 && m > 0 && s > 0) return '$m min $s s';
    return '${h}h${m.toString().padLeft(2, '0')} $s s';
  }

  // Format qty%unité (ex: "30%minutes", "5 à 8%min", "1%heure")
  final pctIdx = trimmed.indexOf('%');
  if (pctIdx > 0) {
    final qty = trimmed.substring(0, pctIdx).trim();
    final unit = trimmed.substring(pctIdx + 1).trim().toLowerCase();
    if (qty.isNotEmpty && unit.isNotEmpty) {
      if (unit.startsWith('min')) return '$qty min';
      if (unit.startsWith('h')) return '$qty h';
      return '$qty $unit';
    }
  }

  return trimmed;
}

/// Formate l'affichage d'un ingrédient, accordé en nombre.
///
/// Ex : qty="3", unit="Cuillère à soupe", name="sauce soja"
///        → "3 cuillères à soupe de sauce soja"
///      qty="2", unit="pièces", name="carotte" → "2 carottes"
///
/// Les règles d'accord vivent dans core/utils/ingredient_display.dart ; ce
/// wrapper ne garde que le rattrapage défensif du séparateur `%`, qui est un
/// défaut de parsing en amont et non une question de langue.
String cooklangFormatIngredient(String qty, String unit, String name) {
  var normalizedQty = qty.trim();
  var normalizedUnit = unit.trim();

  // Rattrapage défensif : si le parsing a échoué en amont et que la quantité
  // porte encore le séparateur (ex. "2%c.s."), on la scinde pour l'affichage.
  if (normalizedUnit.isEmpty) {
    final sepMatch = RegExp(r'[%％﹪]').firstMatch(normalizedQty);
    if (sepMatch != null) {
      final idx = sepMatch.start;
      if (idx > 0 && idx < normalizedQty.length - 1) {
        normalizedUnit = normalizedQty.substring(idx + 1).trim();
        normalizedQty = normalizedQty.substring(0, idx).trim();
      }
    }
  }

  normalizedQty = normalizedQty.replaceAll(RegExp(r'[%％﹪]+$'), '').trim();
  normalizedUnit = normalizedUnit.replaceAll(RegExp(r'^[%％﹪]+'), '').trim();

  return formatIngredientDisplay(
    qty: normalizedQty,
    unit: normalizedUnit,
    name: name.trim(),
  );
}

/// Miniature d'illustration (48×48) avec bouton poubelle visible.
class CooklangIllustrationThumb extends StatelessWidget {
  final String url;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const CooklangIllustrationThumb({
    super.key,
    required this.url,
    required this.onTap,
    this.onDelete,
  });

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette illustration ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed == true) onDelete!();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: url,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(
                  width: 48,
                  height: 48,
                  color: Colors.grey.shade200,
                  child: const Icon(Icons.image_outlined, size: 20),
                ),
                errorWidget: (_, _, _) => Container(
                  width: 48,
                  height: 48,
                  color: Colors.grey.shade200,
                  child: const Icon(Icons.broken_image_outlined, size: 20),
                ),
              ),
            ),
          ),
          if (onDelete != null)
            Positioned(
              top: -4,
              right: -4,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _confirmDelete(context),
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(
                      Icons.delete_outline,
                      size: 12,
                      color: Colors.white,
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
