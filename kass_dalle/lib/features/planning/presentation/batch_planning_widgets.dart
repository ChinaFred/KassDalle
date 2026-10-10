import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_advice_access.dart';
import '../../recipes/domain/storage_advice.dart';
import '../domain/meal_choice_source.dart';
import '../domain/meal_component.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planning_preferences.dart';
import '../domain/recipe_search_scope.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';

export '../domain/recipe_search_scope.dart'
    show RecipeSource, RecipeSearchScope;

/// Éditeur des contraintes d'un slot : prépa max, parts, réchauffage, note.
///
/// Chaque frappe est remontée au parent. Une validation clavier ne suffisait
/// pas : le champ de note est multiligne, donc `onFieldSubmitted` n'y est
/// jamais appelé — la contrainte saisie n'atteignait jamais l'IA.
class SlotConstraintsEditor extends StatefulWidget {
  final DayConstraint constraint;
  final ValueChanged<int> onMaxPrepChanged;
  final ValueChanged<int> onTargetPortionsChanged;
  final ValueChanged<bool> onReheatChanged;
  final ValueChanged<String> onNotesChanged;

  /// Le format du repas sur ce créneau ; le plat seul remet au défaut.
  final ValueChanged<MealFormat> onFormatChanged;

  const SlotConstraintsEditor({
    super.key,
    required this.constraint,
    required this.onMaxPrepChanged,
    required this.onTargetPortionsChanged,
    required this.onReheatChanged,
    required this.onNotesChanged,
    required this.onFormatChanged,
  });

  @override
  State<SlotConstraintsEditor> createState() => _SlotConstraintsEditorState();
}

class _SlotConstraintsEditorState extends State<SlotConstraintsEditor> {
  late final TextEditingController _prepCtrl;
  late final TextEditingController _portionsCtrl;
  late final TextEditingController _notesCtrl;

  static String _numText(int value) => value > 0 ? '$value' : '';

  @override
  void initState() {
    super.initState();
    _prepCtrl = TextEditingController(
      text: _numText(widget.constraint.maxPrepMinutes),
    );
    _portionsCtrl = TextEditingController(
      text: _numText(widget.constraint.targetPortions),
    );
    _notesCtrl = TextEditingController(text: widget.constraint.notes);
  }

  @override
  void didUpdateWidget(SlotConstraintsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ne réécrire que si la valeur vient d'ailleurs que du champ lui-même,
    // sinon le curseur saute à chaque frappe.
    _syncController(_prepCtrl, _numText(widget.constraint.maxPrepMinutes));
    _syncController(_portionsCtrl, _numText(widget.constraint.targetPortions));
    _syncController(_notesCtrl, widget.constraint.notes);
  }

  void _syncController(TextEditingController ctrl, String value) {
    if (ctrl.text != value) ctrl.text = value;
  }

  @override
  void dispose() {
    _prepCtrl.dispose();
    _portionsCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 150,
          child: TextField(
            controller: _prepCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Prépa max (min)',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                widget.onMaxPrepChanged(int.tryParse(value.trim()) ?? 0),
          ),
        ),
        SizedBox(
          width: 150,
          child: TextField(
            controller: _portionsCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Parts à préparer',
              hintText: '0 = portions recette',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                widget.onTargetPortionsChanged(int.tryParse(value.trim()) ?? 0),
          ),
        ),
        // Le format du repas sur ce créneau : c'est lui qui demande une entrée
        // ou un dessert à la suggestion, pas la contrainte en prose.
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<MealFormat>(
            initialValue: widget.constraint.effectiveFormat,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Format du repas',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final f in MealFormat.values)
                DropdownMenuItem(value: f, child: Text(f.label)),
            ],
            onChanged: (f) {
              if (f != null) widget.onFormatChanged(f);
            },
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Réchauffage'),
            Switch.adaptive(
              value: widget.constraint.isBatchCooking,
              onChanged: widget.onReheatChanged,
            ),
          ],
        ),
        SizedBox(
          width: 340,
          child: StylusPadTextField(
            controller: _notesCtrl,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Contrainte spécifique',
              hintText: 'Ex: sport le soir, street food…',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onNotesChanged,
          ),
        ),
      ],
    );
  }
}

/// Tuile représentant un slot de planning dans BatchPlanningScreen.
class BatchSlotTile extends StatelessWidget {
  final int index;
  final DateTime date;
  final Recipe? recipe;
  final TimeOfDay slotTime;
  final bool isGenerating;
  final DayConstraint dayConstraint;
  final bool isBatchDay;
  final bool constraintsReadOnly;

  /// Faits qui justifient le choix (protéine, durée, note, dernier service),
  /// produits par le serveur ; ou la justification d'une conception.
  final String? justification;

  /// Qui a choisi la recette ; `null` pour un repas sans origine connue.
  final MealChoiceSource? choiceSource;

  /// Vrai pendant la conception d'une recette pour ce créneau.
  final bool conceiving;

  /// Jour de préparation à l'avance (calculé depuis le batch cooking day).
  final DateTime? prepDate;

  /// True si la proposition associée au slot a été redimensionnée/ajustée.
  final bool wasResized;

  /// Détail du redimensionnement quand [wasResized] est true.
  final String? resizeReason;

  final bool isGeneratedByAI;

  /// Le repas du créneau est déjà enregistré au planning, depuis son icône
  /// calendrier ; « Valider » le mettra à jour au lieu de l'ajouter.
  final bool savedToPlanning;

  /// Conseil de conservation de la recette, s'il en existe un.
  final StorageAdvice? storageAdvice;

  /// Vrai pendant la production du conseil de conservation de ce créneau.
  final bool storageLoading;

  /// La recette n'a pas de conseil et l'utilisateur n'est ni son créateur ni
  /// un administrateur : une courte phrase remplace le bouton, constaté au
  /// premier essai.
  final bool storageReserved;

  /// Demande le conseil de conservation — null tant qu'aucune recette
  /// enregistrée n'est posée sur le créneau.
  final VoidCallback? onGenerateStorageAdvice;

  final VoidCallback onAssign;
  final VoidCallback onRemove;
  final VoidCallback onDelete;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final ValueChanged<int> onMaxPrepChanged;
  final ValueChanged<int> onTargetPortionsChanged;
  final ValueChanged<bool> onReheatChanged;
  final ValueChanged<String> onNotesChanged;

  /// « Autre suggestion » sur un créneau rempli, « Proposer une recette » sur
  /// un créneau vide : la recette suivante de la liste classée, sans IA.
  final VoidCallback? onGenerateWithAI;
  final VoidCallback? onExportToCalendar;

  /// Callback appelé quand l'utilisateur tape sur le titre de la recette.
  final VoidCallback? onRecipeTap;

  /// L'accompagnement posé sur le créneau, choisi par le programme ou par
  /// l'utilisateur ; null quand le plat se suffit, ou qu'on n'a rien trouvé.
  final MealComponent? side;

  /// Ouvre le choix d'un accompagnement — null tant qu'aucune recette n'est
  /// posée.
  final VoidCallback? onChangeSide;
  final VoidCallback? onRemoveSide;

  /// L'entrée et le dessert du créneau, quand son format en demande.
  final MealComponent? starter;
  final MealComponent? dessert;
  final VoidCallback? onChangeStarter;
  final VoidCallback? onRemoveStarter;
  final VoidCallback? onChangeDessert;
  final VoidCallback? onRemoveDessert;

  /// Le format du repas sur ce créneau, changé dans l'éditeur de contraintes.
  final ValueChanged<MealFormat> onFormatChanged;

  const BatchSlotTile({
    super.key,
    required this.index,
    required this.date,
    required this.recipe,
    required this.slotTime,
    required this.isGenerating,
    required this.dayConstraint,
    required this.isBatchDay,
    this.constraintsReadOnly = false,
    this.justification,
    this.choiceSource,
    this.conceiving = false,
    this.prepDate,
    this.wasResized = false,
    this.resizeReason,
    this.isGeneratedByAI = false,
    this.savedToPlanning = false,
    this.storageAdvice,
    this.storageLoading = false,
    this.storageReserved = false,
    this.onGenerateStorageAdvice,
    required this.onAssign,
    required this.onRemove,
    required this.onDelete,
    required this.onTimeChanged,
    required this.onMaxPrepChanged,
    required this.onTargetPortionsChanged,
    required this.onReheatChanged,
    required this.onNotesChanged,
    this.onGenerateWithAI,
    this.onExportToCalendar,
    this.onRecipeTap,
    this.side,
    this.onChangeSide,
    this.onRemoveSide,
    this.starter,
    this.dessert,
    this.onChangeStarter,
    this.onRemoveStarter,
    this.onChangeDessert,
    this.onRemoveDessert,
    required this.onFormatChanged,
  });

  /// Une entrée ou un dessert, quand le format du créneau en demande : posé
  /// par la suggestion, changé ou retiré d'un appui. « À choisir » quand la
  /// suggestion n'a rien rendu — un vide qui se voit vaut mieux qu'un vide
  /// qui se devine.
  Widget _buildCourseLine(
    ThemeData theme,
    MealComponentRole role,
    MealComponent? course,
    VoidCallback? onChange,
    VoidCallback? onRemove,
  ) {
    final text = course == null
        ? '${role.label} : à choisir'
        : '${role.label} : ${course.label}';
    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 4),
      child: Row(
        children: [
          Icon(
            role == MealComponentRole.entree
                ? Icons.soup_kitchen_outlined
                : Icons.cake_outlined,
            size: AppIconSize.badge,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: course == null ? FontStyle.italic : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onChange != null)
            TextButton(
              onPressed: onChange,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: Text(course == null ? 'Choisir' : 'Changer'),
            ),
          if (course != null && onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: AppIconSize.inline),
              tooltip: 'Retirer',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  /// L'accompagnement du créneau : ce qu'on sert à côté, et pourquoi.
  ///
  /// Le pourquoi est celui du programme — « le plat n'apporte pas de
  /// féculent » — en infobulle : la ligne reste courte, la raison reste
  /// accessible.
  Widget _buildSideLine(ThemeData theme) {
    final s = side;
    final text = s == null
        ? 'Sans accompagnement'
        : 'Accompagnement : ${s.label}'
              '${s.quantityLabel != null ? ' · ${s.quantityLabel}' : ''}';
    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 4),
      child: Row(
        children: [
          Icon(
            Icons.rice_bowl_outlined,
            size: AppIconSize.badge,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: s?.justification ?? '',
              child: Text(
                text,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: s == null ? FontStyle.italic : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (onChangeSide != null)
            TextButton(
              onPressed: onChangeSide,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: Text(s == null ? 'Ajouter' : 'Changer'),
            ),
          if (s != null && onRemoveSide != null)
            IconButton(
              icon: const Icon(Icons.close, size: AppIconSize.inline),
              tooltip: 'Retirer l\'accompagnement',
              visualDensity: VisualDensity.compact,
              onPressed: onRemoveSide,
            ),
        ],
      ),
    );
  }

  /// Consigne calculée : jour de préparation et mode imposé par le délai.
  ///
  /// Aucun appel d'IA n'a lieu ici — ces règles se calculent, et doivent
  /// s'afficher même sur une recette qui n'a jamais reçu de conseil.
  Widget _buildComputedStorage(ThemeData theme, DateTime prep) {
    final daysAhead = mealStorageDaysAhead(prepDate: prep, mealDate: date);
    final mode = mealStorageMode(daysAhead);
    final color = mode == MealStorageMode.freezer
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;

    return Row(
      children: [
        Icon(
          mode == MealStorageMode.freezer
              ? Icons.ac_unit_outlined
              : Icons.kitchen_outlined,
          size: AppIconSize.badge,
          color: color,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            'À préparer le ${DateFormat('EEEE d MMM', 'fr').format(prep)} · '
            '${mealStorageInstruction(daysAhead)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Ligne de conservation : consigne calculée quand le jour de préparation est
  /// connu, puis le conseil propre au plat ou le bouton qui le demande.
  Widget _buildStorageLine(ThemeData theme) {
    final prep = prepDate;
    final reheat = storageAdvice?.rechauffage;

    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // La consigne calculée n'a de sens que si l'on sait quel jour le plat
          // est préparé. Sans jour de préparation, seul le conseil reste utile.
          if (prep != null) _buildComputedStorage(theme, prep),
          if (reheat != null && !reheat.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 17),
              child: Text(
                'Réchauffage : ${reheat.summary}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (storageReserved)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 17),
              child: Text(
                kStorageAdviceReservedMessage,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (onGenerateStorageAdvice != null)
            Padding(
              padding: const EdgeInsets.only(left: 9),
              child: TextButton.icon(
                onPressed: storageLoading ? null : onGenerateStorageAdvice,
                icon: storageLoading
                    ? const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.kitchen_outlined,
                        size: AppIconSize.inline,
                      ),
                label: const Text('Conservation et réchauffage'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelSmall,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isToday = date == today;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: GestureDetector(
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: slotTime,
                helpText: 'Heure du repas',
              );
              if (context.mounted && t != null) onTimeChanged(t);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('EEE', 'fr').format(date).toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isToday
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  DateFormat('d', 'fr').format(date),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: isToday ? theme.colorScheme.primary : null,
                    fontWeight: isToday ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
          ),
          title: recipe != null
              ? InkWell(
                  onTap: (recipe!.id.isNotEmpty && onRecipeTap != null)
                      ? onRecipeTap
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          recipe!.titre,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            decoration:
                                (recipe!.id.isNotEmpty && onRecipeTap != null)
                                ? TextDecoration.underline
                                : null,
                          ),
                        ),
                      ),
                      if (isGeneratedByAI) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Recette conçue par l\'IA',
                          child: Icon(
                            Icons.smart_toy_outlined,
                            size: AppIconSize.inline,
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                      ],
                      if (savedToPlanning) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Déjà au planning',
                          child: Icon(
                            Icons.check_circle_outline,
                            size: AppIconSize.inline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              : Text(
                  conceiving ? 'Conception en cours…' : 'À assigner',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
          subtitle: _buildSubtitle(theme, dayConstraint, isBatchDay, slotTime),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isGenerating)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (onGenerateWithAI != null)
                // Sans IA : la recette suivante de la liste classée par le
                // serveur. L'icône d'IA mentait sur ce geste.
                IconButton(
                  icon: const Icon(Icons.autorenew, size: AppIconSize.small),
                  tooltip: recipe != null
                      ? 'Autre suggestion'
                      : 'Proposer une recette',
                  onPressed: onGenerateWithAI,
                ),
              if (recipe != null) ...[
                IconButton(
                  icon: const Icon(
                    AppIcons.calendarExport,
                    size: AppIconSize.small,
                  ),
                  tooltip: savedToPlanning
                      ? 'Ajouter au calendrier et mettre à jour le planning'
                      : 'Ajouter au calendrier et au planning',
                  onPressed: onExportToCalendar,
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz_outlined),
                  tooltip: 'Changer',
                  onPressed: onAssign,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Retirer',
                  onPressed: onRemove,
                ),
              ] else
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Choisir une recette',
                  onPressed: onAssign,
                ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: AppIconSize.small,
                  color: Theme.of(context).colorScheme.error,
                ),
                tooltip: 'Supprimer ce jour',
                onPressed: onDelete,
              ),
            ],
          ),
          onTap: recipe == null ? onAssign : null,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 72, right: 16, bottom: 8),
          child: constraintsReadOnly
              ? _buildConstraintSummary(theme, dayConstraint)
              : SlotConstraintsEditor(
                  key: ValueKey('constraints-$index'),
                  constraint: dayConstraint,
                  onMaxPrepChanged: onMaxPrepChanged,
                  onTargetPortionsChanged: onTargetPortionsChanged,
                  onReheatChanged: onReheatChanged,
                  onNotesChanged: onNotesChanged,
                  onFormatChanged: onFormatChanged,
                ),
        ),
        // Ce qui accompagne le plat — choisi par le programme, changé d'un
        // appui. Après les contraintes, avant la conservation : c'est du repas,
        // pas de la logistique.
        // Dans l'ordre du repas : l'entrée, le plat et son accompagnement, le
        // dessert. L'entrée et le dessert n'apparaissent que si le format du
        // créneau en demande.
        if (recipe != null) ...[
          if (dayConstraint.effectiveFormat.wantsStarter)
            _buildCourseLine(
              theme,
              MealComponentRole.entree,
              starter,
              onChangeStarter,
              onRemoveStarter,
            ),
          _buildSideLine(theme),
          if (dayConstraint.effectiveFormat.wantsDessert)
            _buildCourseLine(
              theme,
              MealComponentRole.dessert,
              dessert,
              onChangeDessert,
              onRemoveDessert,
            ),
        ],
        // Jour de préparation à l'avance, et ce que le plat devra supporter.
        if (prepDate != null || onGenerateStorageAdvice != null)
          _buildStorageLine(theme),
        // Origine du choix, puis les faits qui le justifient, puis le
        // redimensionnement.
        if (recipe != null)
          Padding(
            padding: const EdgeInsets.only(left: 72, right: 16, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?MealOriginLine.maybe(
                  source: choiceSource,
                  facts: justification,
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.open_in_full_outlined,
                      size: AppIconSize.badge,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _resizeExplainability,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  String get _resizeExplainability {
    if (!wasResized) return 'Redimensionnée : non';
    final detail = (resizeReason ?? '').trim();
    if (detail.isEmpty) return 'Redimensionnée : oui';
    return 'Redimensionnée : oui ($detail)';
  }

  Widget _buildSubtitle(
    ThemeData theme,
    DayConstraint? constraint,
    bool isBatchDay,
    TimeOfDay time,
  ) {
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    final parts = <String>[];
    if (isBatchDay) parts.add('jour de batch cooking (repas normal)');
    if (constraint != null && !constraint.isEmpty) {
      if (constraint.maxPrepMinutes > 0) {
        parts.add('max ${constraint.maxPrepMinutes}min');
      }
      if (constraint.targetPortions > 0) {
        parts.add('${constraint.targetPortions} parts');
      }
      if (constraint.isBatchCooking && !isBatchDay) {
        parts.add('réchauffage');
      }
    }
    if (recipe != null) {
      final prep = recipe!.tags.prepTime;
      final cook = recipe!.tags.cookTime;
      if (prep != null || cook != null) {
        final times = <String>[];
        if (prep != null) times.add('${prep}min prép');
        if (cook != null) times.add('${cook}min cuisson');
        parts.add(times.join(' + '));
      }
    }

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        children: [
          TextSpan(
            text: timeStr,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (parts.isNotEmpty)
            TextSpan(
              text: '  ·  ${parts.join(' · ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConstraintSummary(ThemeData theme, DayConstraint constraint) {
    final chips = <Widget>[];
    if (constraint.maxPrepMinutes > 0) {
      chips.add(
        _constraintChip(theme, 'Prépa max ${constraint.maxPrepMinutes} min'),
      );
    }
    if (constraint.targetPortions > 0) {
      chips.add(_constraintChip(theme, '${constraint.targetPortions} parts'));
    }
    chips.add(
      _constraintChip(
        theme,
        constraint.isBatchCooking ? 'Réchauffage: oui' : 'Réchauffage: non',
      ),
    );
    // Le format ne se lit que s'il s'écarte du plat seul.
    if (constraint.mealFormat != null) {
      chips.add(_constraintChip(theme, constraint.mealFormat!.label));
    }

    final notes = constraint.notes.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: chips),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            notes,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _constraintChip(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Sheet de sélection des sources de recettes pour la génération IA par slot,
/// et des livres dans lesquels chercher.
///
/// [availableBooks] est le réservoir de livres qui portent au moins une
/// recette candidate — le choix se fait parmi ce qui peut réellement être
/// trouvé, pas parmi tout ce qui existe. Vide, la section livres ne s'affiche
/// pas : rien à restreindre.
class RecipeSourceSheet extends StatefulWidget {
  final Set<RecipeSource> initialSources;
  final Set<String> initialBookIds;
  final List<({String id, String titre})> availableBooks;

  const RecipeSourceSheet({
    super.key,
    required this.initialSources,
    this.initialBookIds = const {},
    this.availableBooks = const [],
  });

  @override
  State<RecipeSourceSheet> createState() => _RecipeSourceSheetState();
}

class _RecipeSourceSheetState extends State<RecipeSourceSheet> {
  late Set<RecipeSource> _selected;
  late Set<String> _selectedBookIds;

  @override
  void initState() {
    super.initState();
    _selected = Set.of(widget.initialSources);
    _selectedBookIds = Set.of(widget.initialBookIds);
  }

  void _selectAllBooks() {
    setState(
      () => _selectedBookIds = widget.availableBooks.map((b) => b.id).toSet(),
    );
  }

  void _selectNoBook() {
    setState(() => _selectedBookIds = {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBooks = widget.availableBooks.isNotEmpty;
    return DraggableScrollableSheet(
      initialChildSize: hasBooks ? 0.65 : 0.4,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Text(
                      'Où chercher des recettes ?',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final source in RecipeSource.values)
                    CheckboxListTile(
                      value: _selected.contains(source),
                      title: Text(source.label),
                      secondary: Icon(switch (source) {
                        RecipeSource.myRecipes => Icons.check_circle_outline,
                        RecipeSource.myDrafts => Icons.edit_outlined,
                        RecipeSource.familyRecipes => Icons.group_outlined,
                        RecipeSource.aiCreation => Icons.smart_toy_outlined,
                      }),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selected.add(source);
                          } else {
                            _selected.remove(source);
                          }
                        });
                      },
                    ),
                  if (hasBooks) ...[
                    const Divider(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Dans quels livres ?',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          TextButton(
                            onPressed:
                                _selectedBookIds.length ==
                                    widget.availableBooks.length
                                ? _selectNoBook
                                : _selectAllBooks,
                            child: Text(
                              _selectedBookIds.length ==
                                      widget.availableBooks.length
                                  ? 'Tout décocher'
                                  : 'Tout cocher',
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final book in widget.availableBooks)
                      CheckboxListTile(
                        value: _selectedBookIds.contains(book.id),
                        title: Text(book.titre),
                        secondary: const Icon(Icons.menu_book_outlined),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selectedBookIds.add(book.id);
                            } else {
                              _selectedBookIds.remove(book.id);
                            }
                          });
                        },
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.pop(
                        context,
                        RecipeSearchScope(
                          sources: _selected,
                          bookIds: _selectedBookIds,
                        ),
                      ),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Générer'),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Le bouton « Planifier avec l'IA » des grands écrans.
///
/// Il porte un nom plutôt qu'une baguette, et il est posé là où se prennent les
/// décisions de cet écran — juste au-dessus de « Valider ». C'est l'action
/// principale : sans elle, il n'y a rien à valider.
///
/// Il ouvre le même menu que l'icône du mobile, parce que remplir les créneaux
/// vides et tout régénérer ne sont pas la même chose : la seconde efface le
/// travail déjà fait à l'écran, et ce choix ne doit pas se faire par mégarde.
class PlanWithAiButton extends StatelessWidget {
  final bool generating;
  final bool enabled;
  final int emptySlots;
  final List<PopupMenuEntry<int>> Function() itemBuilder;
  final ValueChanged<int> onSelected;

  const PlanWithAiButton({
    super.key,
    required this.generating,
    required this.enabled,
    required this.emptySlots,
    required this.itemBuilder,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (generating) {
      return FilledButton.tonalIcon(
        onPressed: null,
        icon: const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('Planification en cours…'),
      );
    }

    return PopupMenuButton<int>(
      enabled: enabled,
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: onSelected,
      itemBuilder: (_) => itemBuilder(),
      child: IgnorePointer(
        child: FilledButton.tonalIcon(
          // Le bouton n'est qu'une surface : c'est le menu qui reçoit l'appui.
          onPressed: enabled ? () {} : null,
          icon: const Icon(Icons.auto_awesome_outlined),
          label: Text(
            emptySlots > 0
                ? 'Planifier avec l\'IA ($emptySlots créneau'
                      '${emptySlots > 1 ? 'x' : ''} vide'
                      '${emptySlots > 1 ? 's' : ''})'
                : 'Planifier avec l\'IA',
          ),
        ),
      ),
    );
  }
}

/// Ligne d'origine d'un repas : qui l'a choisi, puis les faits qui le
/// justifient. « Choisie par Kass'Dalle · volaille · 35 min ».
///
/// L'icône dit l'origine : le robot pour ce qu'une IA a produit, une
/// personne pour un choix à la main, l'icône des règles pour un choix du
/// code. Un repas sans origine connue n'affiche que ses faits.
class MealOriginLine extends StatelessWidget {
  final MealChoiceSource? source;
  final String? facts;

  const MealOriginLine({super.key, this.source, this.facts});

  /// La ligne, ou `null` quand il n'y a rien à dire.
  static MealOriginLine? maybe({MealChoiceSource? source, String? facts}) {
    final text = facts?.trim() ?? '';
    if (source == null && text.isEmpty) return null;
    return MealOriginLine(source: source, facts: text);
  }

  static IconData iconFor(MealChoiceSource? source) => switch (source) {
    MealChoiceSource.ai || MealChoiceSource.concept => Icons.smart_toy_outlined,
    MealChoiceSource.rules => Icons.rule_outlined,
    MealChoiceSource.manual => Icons.person_outline,
    null => Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = facts?.trim() ?? '';
    final label = source?.label;
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(iconFor(source), size: AppIconSize.badge, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                if (label != null)
                  TextSpan(
                    text: label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                if (label != null && text.isNotEmpty)
                  const TextSpan(text: ' · '),
                if (text.isNotEmpty) TextSpan(text: text),
              ],
            ),
            style: theme.textTheme.labelSmall?.copyWith(color: color),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Bandeau d'avis au-dessus des créneaux : l'IA n'a pas répondu, un plafond
/// a été atteint, ou le plafond de conceptions a laissé des créneaux vides.
/// Une action au plus, et une croix pour le fermer.
///
/// Deux lignes par défaut, « Voir plus » pour le reste : sur un téléphone, un
/// avis long poussait la liste des créneaux hors de l'écran. Annoncé au
/// lecteur d'écran dès qu'il apparaît (`liveRegion`).
class PlanningNoticeBanner extends StatefulWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onClose;

  const PlanningNoticeBanner({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
    required this.onClose,
  });

  @override
  State<PlanningNoticeBanner> createState() => _PlanningNoticeBannerState();
}

class _PlanningNoticeBannerState extends State<PlanningNoticeBanner> {
  static const _collapsedLines = 2;
  bool _expanded = false;

  @override
  void didUpdateWidget(PlanningNoticeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onTertiaryContainer);
    return Semantics(
      liveRegion: true,
      child: Container(
        color: scheme.tertiaryContainer,
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.info_outline,
                size: AppIconSize.small,
                color: scheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final painter = TextPainter(
                    text: TextSpan(text: widget.message, style: style),
                    maxLines: _collapsedLines,
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout(maxWidth: constraints.maxWidth);
                  final overflows = painter.didExceedMaxLines;
                  painter.dispose();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.message,
                        style: style,
                        maxLines: _expanded ? null : _collapsedLines,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                      ),
                      Wrap(
                        spacing: 4,
                        children: [
                          if (overflows || _expanded)
                            TextButton(
                              onPressed: () =>
                                  setState(() => _expanded = !_expanded),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(
                                _expanded ? 'Voir moins' : 'Voir plus',
                              ),
                            ),
                          if (widget.actionLabel != null &&
                              widget.onAction != null)
                            TextButton(
                              onPressed: widget.onAction,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(widget.actionLabel!),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: AppIconSize.small),
              tooltip: 'Fermer',
              color: scheme.onTertiaryContainer,
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}
