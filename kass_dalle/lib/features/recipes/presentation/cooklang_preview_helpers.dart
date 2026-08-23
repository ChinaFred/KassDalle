import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../../core/utils/ingredient_display.dart';
import '../../../core/theme/app_icon_size.dart';

// Le formatage des minuteurs a quitté la couche présentation pour que l'export
// PDF s'en serve aussi. Réexporté ici : les appelants n'ont pas à le savoir.
export '../../../../core/utils/timer_display.dart' show cooklangFormatTimer;

/// Groupe d'étapes de préparation (correspondant à une section == ... ==).
class CooklangStepGroup {
  final String? name; // null = étapes sans section
  final List<String> steps;
  CooklangStepGroup(this.name, this.steps);
}

/// Les jetons CookLang déjà formés : ingrédient, ustensile, minuteur.
///
/// Même expression que celle qui découpe une étape à l'affichage
/// (`cooklang_preview_steps.dart`). Elle sert ici à savoir ce qu'il ne faut
/// **pas** toucher.
const _reJetonsCooklang =
    r'(@[^{@#~]+\{[^}]*\}|#[^{@#~]+\{[^}]*\}|~[^{@#~\s]*\{[^}]*\})';

/// Une durée écrite en texte brut, hors de tout jeton.
///
/// La fourchette est acceptée sous ses deux graphies : « 1 à 2 » et « 1-2 ».
/// C'est la seconde que les modèles écrivent le plus souvent.
final _reDureeNue = RegExp(
  r'(?<![{@#~\d])([1-9]\d*(?:[,./]\d+)?(?:\s*(?:à|-)\s*\d+)?)\s*%\s*'
  r'(minutes?|min\b|heures?|h(?![a-zA-Z])|secondes?|sec\b)',
  caseSensitive: false,
);

/// Normalise les minuteurs écrits en texte brut : `3%minutes` → `~{3%minutes}`.
///
/// **Ne touche jamais l'intérieur d'un jeton déjà formé**, et c'est tout le
/// sujet. L'ancienne version ne regardait que le caractère précédent : dans
/// `~{1-2%minutes}`, le caractère avant le `2` est un tiret, qui passait la
/// garde. Elle réécrivait donc `~{1-~{2%minutes}}`, et l'étape affichait un
/// jeton « 1-~{2 min » suivi d'une accolade orpheline.
///
/// Le texte est donc découpé sur les jetons existants, et seuls les morceaux
/// qui sont entre eux sont normalisés. Une garde de position ne peut pas dire
/// « je suis dans des accolades » ; un découpage, si.
String cooklangNormalizeStepTimers(String step) {
  final tampon = StringBuffer();
  var precedent = 0;

  for (final jeton in RegExp(_reJetonsCooklang).allMatches(step)) {
    tampon.write(_normaliserHorsJeton(step.substring(precedent, jeton.start)));
    tampon.write(jeton.group(0));
    precedent = jeton.end;
  }
  tampon.write(_normaliserHorsJeton(step.substring(precedent)));
  return tampon.toString();
}

String _normaliserHorsJeton(String texte) => texte.replaceAllMapped(
  _reDureeNue,
  (m) => '~{${m.group(1)!.trim()}%${m.group(2)!.trim()}}',
);

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
                  child: const Icon(
                    Icons.image_outlined,
                    size: AppIconSize.small,
                  ),
                ),
                errorWidget: (_, _, _) => Container(
                  width: 48,
                  height: 48,
                  color: Colors.grey.shade200,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    size: AppIconSize.small,
                  ),
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
                      size: AppIconSize.badge,
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
