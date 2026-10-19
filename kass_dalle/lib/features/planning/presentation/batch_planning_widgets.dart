import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_advice_access.dart';
import '../../recipes/domain/storage_advice.dart';
import '../domain/meal_choice_source.dart';
import '../domain/planning_criteria.dart';
import '../domain/relaxed_criteria.dart';
import '../domain/side_chooser.dart';
import '../domain/meal_component.dart';
import '../domain/meal_composition.dart';
import '../domain/meal_storage_rules.dart';
import 'constraint_understanding.dart';
import 'meal_course_style.dart';
import '../domain/planning_preferences.dart';
import '../domain/recipe_search_scope.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/duration_format.dart';
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

  /// Ce que le serveur a compris d'un texte, pour « Compris : … » sous la
  /// contrainte spécifique ; absent : aucune ligne.
  final ConstraintTranslation? Function(String text)? understandingOf;

  const SlotConstraintsEditor({
    super.key,
    required this.constraint,
    required this.onMaxPrepChanged,
    required this.onTargetPortionsChanged,
    required this.onReheatChanged,
    required this.onNotesChanged,
    required this.onFormatChanged,
    this.understandingOf,
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
            // Un libellé long (« Entrée, plat et dessert ») se coupe au lieu
            // de déborder du champ.
            isExpanded: true,
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              StylusPadTextField(
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
              if (widget.understandingOf != null)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _notesCtrl,
                  builder: (context, value, _) => ConstraintUnderstandingLines(
                    text: value.text,
                    translation: widget.understandingOf!(value.text),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Largeur au-delà de laquelle la grille des créneaux ajoute une colonne.
///
/// Une carte plus large étire la ligne de lecture sans rien montrer de plus.
const double kBatchSlotCardMaxWidth = 560;

/// Largeur minimale d'une carte : en dessous, l'éditeur des contraintes d'une
/// carte dépliée se tasse, et la grille garde une colonne de moins.
const double kBatchSlotCardMinWidth = 340;

/// Actions du menu ⋮ d'un créneau.
enum _SlotAction { assign, compose, exportToCalendar, remove, delete }

/// Carte d'un créneau de BatchPlanningScreen.
///
/// La carte montre toujours le jour, l'heure, la recette, une ligne de
/// résumé (parts, durée, accompagnement, format) et les avertissements. Le
/// reste — contraintes du jour, composants du repas, conservation, origine —
/// vit dans un pli « Détails », déplié d'office quand le créneau porte un
/// avertissement, replié sinon.
class BatchSlotTile extends StatefulWidget {
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

  /// Jour de préparation à l'avance (calculé depuis le jour de préparation
  /// des préférences).
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

  /// Les accompagnements du plat, 0 à [kMaxSidesPerDish], choisis par le
  /// programme ou par l'utilisateur ; vide quand le plat se suffit, ou
  /// qu'on n'a rien trouvé.
  final List<MealComponent> sides;

  /// Ouvre le choix d'un accompagnement de plus, filtré sur un besoin s'il
  /// est donné — null tant qu'aucune recette n'est posée.
  final ValueChanged<SideNeed?>? onAddSide;
  final ValueChanged<MealComponent>? onRemoveSide;

  /// Ce que le plat et ses accompagnements apportent ; `null` sans recette.
  final DishSideStatus? sideStatus;

  /// Besoins pour lesquels aucune garniture ni recette d'accompagnement
  /// n'existe : « Il manque un légume. Aucune garniture de légume
  /// disponible. »
  final Set<SideNeed> needsWithoutCandidate;

  /// Critères relâchés par le serveur pour le plat de ce créneau
  /// (`in_cycle`, `variety_window`, `rating`) : une ligne par écart.
  final List<String> relaxed;

  /// Critères que le repas ne tient pas, ou n'a pas pu vérifier : une ligne
  /// par écart, hors du pli. Préférence relâchée et exclusion non vérifiée en
  /// `info_outline` ; service vidé par une exclusion en couleur `error`,
  /// avec « Choisir ».
  final List<UnmetCriterion> unmet;

  /// Ce que le serveur a compris d'un texte, pour la contrainte spécifique.
  final ConstraintTranslation? Function(String text)? understandingOf;

  /// Aucune recette classée en entrée ou en dessert : la ligne « à choisir »
  /// le dit.
  final bool noStarterCandidate;
  final bool noDessertCandidate;

  /// L'entrée et le dessert du créneau, quand son format en demande. Un
  /// service « à choisir » posé par l'éditeur se lit comme absent.
  final MealComponent? starter;
  final MealComponent? dessert;

  /// Les autres services d'un menu — deuxième entrée, sorbet, fromage, plat
  /// secondaire, « Autre » —, montrés dans le pli « Détails ».
  final List<MealCourse> extraCourses;

  /// « Composer le menu » : l'éditeur partagé, en mémoire. Null sans
  /// recette.
  final VoidCallback? onCompose;

  /// [Choisir] d'un service vide de [extraCourses] : sa position dans la
  /// liste. Ouvre directement la feuille du type du service.
  final ValueChanged<int>? onChooseExtraCourse;
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
    this.sides = const [],
    this.onAddSide,
    this.onRemoveSide,
    this.sideStatus,
    this.needsWithoutCandidate = const {},
    this.relaxed = const [],
    this.unmet = const [],
    this.understandingOf,
    this.noStarterCandidate = false,
    this.noDessertCandidate = false,
    this.starter,
    this.dessert,
    this.extraCourses = const [],
    this.onCompose,
    this.onChooseExtraCourse,
    this.onChangeStarter,
    this.onRemoveStarter,
    this.onChangeDessert,
    this.onRemoveDessert,
    required this.onFormatChanged,
  });

  /// L'entrée manque alors que le format en demande une.
  bool get missingStarter =>
      recipe != null &&
      dayConstraint.effectiveFormat.wantsStarter &&
      (starter == null || starter!.isEmptyCourse);

  /// Le dessert manque alors que le format en demande un.
  bool get missingDessert =>
      recipe != null &&
      dayConstraint.effectiveFormat.wantsDessert &&
      (dessert == null || dessert!.isEmptyCourse);

  /// Ce qui manque encore au plat, en comptant ses accompagnements.
  List<SideNeed> get missingSides =>
      recipe != null && sideStatus?.state == DishSideState.missing
      ? sideStatus!.missing
      : const [];

  /// Le créneau porte un avertissement : un composant à choisir, ou un plat
  /// à préparer un autre jour que celui où on le mange.
  bool get hasWarning =>
      missingStarter ||
      missingDessert ||
      missingSides.isNotEmpty ||
      prepDate != null;

  @override
  State<BatchSlotTile> createState() => _BatchSlotTileState();
}

class _BatchSlotTileState extends State<BatchSlotTile> {
  /// Le pli « Détails » est ouvert.
  late bool _expanded;

  /// L'utilisateur a ouvert ou fermé le pli lui-même : la carte ne le
  /// rouvre ni ne le referme plus au gré des avertissements, tant que la
  /// recette du créneau ne change pas.
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.hasWarning;
  }

  @override
  void didUpdateWidget(BatchSlotTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recipe?.id != widget.recipe?.id ||
        oldWidget.recipe?.titre != widget.recipe?.titre) {
      _userToggled = false;
    }
    // Un avertissement apparu après une suggestion ouvre le pli, comme à la
    // création de la carte ; un choix de l'utilisateur prime.
    if (!_userToggled) _expanded = widget.hasWarning;
  }

  void _toggle() => setState(() {
    _expanded = !_expanded;
    _userToggled = true;
  });

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: widget.slotTime,
      helpText: 'Heure du repas',
    );
    if (mounted && t != null) widget.onTimeChanged(t);
  }

  // ── Menu ⋮ ─────────────────────────────────────────────────────────────

  List<PopupMenuEntry<_SlotAction>> _menuItems(ThemeData theme) {
    final w = widget;
    final error = theme.colorScheme.error;
    return [
      PopupMenuItem(
        value: _SlotAction.assign,
        child: ListTile(
          leading: Icon(
            w.recipe != null ? Icons.swap_horiz_outlined : Icons.search,
          ),
          title: Text(
            w.recipe != null ? 'Changer de recette' : 'Choisir une recette',
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      PopupMenuItem(
        value: _SlotAction.compose,
        enabled: w.recipe != null && w.onCompose != null,
        child: const ListTile(
          leading: Icon(Icons.restaurant_menu_outlined),
          title: Text('Composer le menu'),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      PopupMenuItem(
        value: _SlotAction.exportToCalendar,
        enabled: w.recipe != null && w.onExportToCalendar != null,
        child: ListTile(
          leading: const Icon(AppIcons.calendarExport),
          title: Text(
            w.savedToPlanning
                ? 'Ajouter au calendrier et mettre à jour le planning'
                : 'Ajouter au calendrier et au planning',
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      PopupMenuItem(
        value: _SlotAction.remove,
        enabled: w.recipe != null,
        child: const ListTile(
          leading: Icon(Icons.close),
          title: Text('Retirer la recette'),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: _SlotAction.delete,
        child: ListTile(
          leading: Icon(Icons.delete_outline, color: error),
          title: Text('Supprimer ce jour', style: TextStyle(color: error)),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }

  void _onAction(_SlotAction action) {
    switch (action) {
      case _SlotAction.assign:
        widget.onAssign();
      case _SlotAction.compose:
        widget.onCompose?.call();
      case _SlotAction.exportToCalendar:
        widget.onExportToCalendar?.call();
      case _SlotAction.remove:
        widget.onRemove();
      case _SlotAction.delete:
        widget.onDelete();
    }
  }

  /// Le même menu, ouvert d'un clic droit sur la carte (desktop et web).
  Future<void> _showContextMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final theme = Theme.of(context);
    final action = await showMenu<_SlotAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _menuItems(theme),
    );
    if (action != null && mounted) _onAction(action);
  }

  // ── Lignes ─────────────────────────────────────────────────────────────

  /// Une entrée ou un dessert, quand le format du créneau en demande : posé
  /// par la suggestion, changé ou retiré d'un appui. « À choisir » quand la
  /// suggestion n'a rien rendu : la ligne est alors un avertissement, affiché
  /// hors du pli.
  Widget _buildCourseLine(
    ThemeData theme,
    MealComponentRole role,
    MealComponent? course,
    VoidCallback? onChange,
    VoidCallback? onRemove,
  ) {
    final missing = course == null || course.isEmptyCourse;
    final noCandidate = role == MealComponentRole.entree
        ? widget.noStarterCandidate
        : widget.noDessertCandidate;
    final service = role == MealComponentRole.entree ? 'entree' : 'dessert';
    final emptied = widget.unmet
        .where((u) => u.service == service && u.isEmptyService)
        .map((u) => u.detail)
        .firstOrNull;
    final text = missing
        ? emptied != null
              ? '${role.label} : à choisir. $emptied'
              : noCandidate
              ? '${role.label} : à choisir. Aucune recette classée en '
                    '${role.label.toLowerCase()}.'
              : '${role.label} : à choisir'
        : '${role.label} : ${course.label}';
    final color = missing
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(
          missing
              ? Icons.warning_amber_outlined
              : role == MealComponentRole.entree
              ? Icons.soup_kitchen_outlined
              : Icons.cake_outlined,
          size: AppIconSize.inline,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: missing ? FontWeight.w600 : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onChange != null)
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(
              missing ? 'Choisir' : 'Changer',
              semanticsLabel: missing
                  ? chooseCourseSemanticLabel(role, role.label)
                  : null,
            ),
          ),
        if (!missing && onRemove != null)
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSize.inline),
            tooltip: 'Retirer',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
          ),
      ],
    );
  }

  /// Un autre service du menu, en lecture : « Fromage : à choisir »,
  /// « Plat : Gratin + Salade verte ». Il se modifie dans « Composer le
  /// menu ».
  Widget _buildExtraCourseLine(
    ThemeData theme,
    MealCourse course,
    int position,
  ) {
    final sides = course.sides.map((s) => s.label).join(', ');
    final missing = course.isEmpty;
    final text = missing
        ? '${course.typeLabel} : à choisir'
        : '${course.typeLabel} : ${course.component.label}'
              '${course.component.quantityLabel != null ? ' · ${course.component.quantityLabel}' : ''}'
              '${sides.isEmpty ? '' : ' + $sides'}';
    final color = missing
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(
          missing
              ? courseRoleIcon(course.role)
              : course.component.isRecipe
              ? Icons.menu_book_outlined
              : course.component.isStaple
              ? Icons.rice_bowl_outlined
              : courseRoleIcon(course.role),
          size: AppIconSize.inline,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: missing ? FontWeight.w600 : null,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (missing && widget.onChooseExtraCourse != null)
          ChooseCourseButton(
            role: course.role,
            typeLabel: course.typeLabel,
            compact: true,
            onPressed: () => widget.onChooseExtraCourse!(position),
          ),
      ],
    );
  }

  /// Un accompagnement du créneau : ce qu'on sert à côté, et pourquoi.
  ///
  /// Le pourquoi est celui du programme — « le plat n'apporte pas de
  /// féculent » — en infobulle : la ligne reste courte, la raison reste
  /// accessible.
  Widget _buildSideLine(ThemeData theme, MealComponent s) {
    final text =
        'Accompagnement : ${s.label}'
        '${s.quantityLabel != null ? ' · ${s.quantityLabel}' : ''}';
    return Row(
      children: [
        Icon(
          s.isRecipe ? Icons.menu_book_outlined : Icons.rice_bowl_outlined,
          size: AppIconSize.inline,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Tooltip(
            message: s.justification ?? '',
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (widget.onRemoveSide != null)
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSize.inline),
            tooltip: 'Retirer « ${s.label} »',
            onPressed: () => widget.onRemoveSide!(s),
          ),
      ],
    );
  }

  /// Les accompagnements du créneau, puis « Ajouter un accompagnement »
  /// jusqu'à [kMaxSidesPerDish].
  List<Widget> _buildSideLines(ThemeData theme) {
    final w = widget;
    final full = w.sides.length >= kMaxSidesPerDish;
    return [
      if (w.sides.isEmpty)
        Text(
          'Sans accompagnement',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      for (final s in w.sides) _buildSideLine(theme, s),
      if (w.onAddSide != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: full
              ? Text(
                  '$kMaxSidesPerDish accompagnements au plus',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : TextButton.icon(
                  onPressed: () => w.onAddSide!(null),
                  icon: const Icon(Icons.add, size: AppIconSize.inline),
                  label: const Text('Ajouter un accompagnement'),
                ),
        ),
    ];
  }

  /// « Il manque un légume. » avec « Choisir » ; « Aucune garniture de
  /// légume disponible. » quand rien ne peut l'apporter. Hors du pli.
  Widget _buildMissingSideLine(ThemeData theme, SideNeed need) {
    final none = widget.needsWithoutCandidate.contains(need);
    final color = theme.colorScheme.error;
    return Row(
      children: [
        Icon(
          Icons.warning_amber_outlined,
          size: AppIconSize.inline,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            none
                ? 'Il manque un ${need.label}. Aucune garniture de '
                      '${need.label} disponible.'
                : 'Il manque un ${need.label}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.onAddSide != null && widget.sides.length < kMaxSidesPerDish)
          TextButton(
            onPressed: () => widget.onAddSide!(need),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Choisir'),
          ),
      ],
    );
  }

  /// Un écart à un critère compris : « 1 h 10, au-delà des 45 min
  /// demandées : peu d'autres choix », « Dessert — Allergènes non vérifiés :
  /// gluten ». Sans action ; un service vide a sa propre ligne.
  Widget _buildUnmetLine(ThemeData theme, UnmetCriterion u) {
    final color = theme.colorScheme.onSurfaceVariant;
    final prefix = switch (u.service) {
      'entree' => 'Entrée — ',
      'dessert' => 'Dessert — ',
      _ => '',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: AppIconSize.inline, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$prefix${u.detail}',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  /// « Plat : à choisir. Aucun plat sans porc. » avec « Choisir » : une
  /// exclusion a vidé le créneau, et elle ne se relâche pas.
  Widget _buildEmptyDishLine(ThemeData theme, UnmetCriterion u) {
    final color = theme.colorScheme.error;
    return Row(
      children: [
        Icon(
          Icons.warning_amber_outlined,
          size: AppIconSize.inline,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Plat : à choisir. ${u.detail}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: widget.onAssign,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Text('Choisir', semanticsLabel: 'Choisir le plat'),
        ),
      ],
    );
  }

  /// Une ligne par critère relâché par le serveur, sans action.
  Widget _buildRelaxedLine(ThemeData theme, RelaxedCriterion c) {
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: AppIconSize.inline, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            c.sentence,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  /// Consigne calculée : jour de préparation et mode imposé par le délai.
  ///
  /// Aucun appel d'IA n'a lieu ici — ces règles se calculent, et doivent
  /// s'afficher même sur une recette qui n'a jamais reçu de conseil.
  Widget _buildComputedStorage(ThemeData theme, DateTime prep) {
    final daysAhead = mealStorageDaysAhead(
      prepDate: prep,
      mealDate: widget.date,
    );
    final mode = mealStorageMode(daysAhead);
    final color = mode == MealStorageMode.freezer
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          mode == MealStorageMode.freezer
              ? Icons.ac_unit_outlined
              : Icons.kitchen_outlined,
          size: AppIconSize.inline,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'À préparer le ${DateFormat('EEEE d MMM', 'fr').format(prep)} · '
            '${mealStorageInstruction(daysAhead)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Conseil de conservation propre au plat, ou le bouton qui le demande.
  ///
  /// La consigne calculée (« À préparer le … ») n'en fait pas partie : c'est
  /// un avertissement, affiché hors du pli.
  Widget? _buildStorageAdvice(ThemeData theme) {
    final reheat = widget.storageAdvice?.rechauffage;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (reheat != null && !reheat.isEmpty) {
      return Text('Réchauffage : ${reheat.summary}', style: style);
    }
    if (widget.storageReserved) {
      return Text(kStorageAdviceReservedMessage, style: style);
    }
    if (widget.onGenerateStorageAdvice != null) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: widget.storageLoading
              ? null
              : widget.onGenerateStorageAdvice,
          icon: widget.storageLoading
              ? const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.kitchen_outlined, size: AppIconSize.inline),
          label: const Text('Conservation et réchauffage'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      );
    }
    return null;
  }

  /// Ligne de résumé, sous le titre : parts, durée, accompagnement, format.
  String _summaryLine() {
    final w = widget;
    final c = w.dayConstraint;
    final r = w.recipe;
    final parts = <String>[];
    final portions = c.targetPortions > 0 ? c.targetPortions : r?.portions;
    if (portions != null && portions > 0) {
      parts.add('$portions part${portions > 1 ? 's' : ''}');
    }
    if (r != null) {
      final prep = r.tags.prepTime;
      final cook = r.tags.cookTime;
      if (prep != null || cook != null) {
        parts.add(formatDurationMinutes((prep ?? 0) + (cook ?? 0)));
      }
    }
    if (c.maxPrepMinutes > 0) parts.add('${c.maxPrepMinutes} min max');
    if (r != null) parts.addAll(w.sides.map((s) => s.label));
    final format = c.mealFormat;
    if (format != null && format != MealFormat.defaultFormat) {
      parts.add(format.label);
    }
    if (w.isBatchDay) parts.add('jour de préparation');
    if (c.isBatchCooking && !w.isBatchDay) parts.add('réchauffage');
    return parts.join(' · ');
  }

  // ── Construction ───────────────────────────────────────────────────────

  Widget _buildTimeButton(ThemeData theme) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isToday = widget.date == today;
    final t = widget.slotTime;
    final timeStr =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return Tooltip(
      message: 'Changer l\'heure du repas',
      child: TextButton(
        onPressed: _pickTime,
        style: TextButton.styleFrom(
          minimumSize: const Size(56, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              DateFormat('EEE d', 'fr').format(widget.date),
              style: theme.textTheme.labelLarge?.copyWith(
                color: isToday
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              timeStr,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    final w = widget;
    final recipe = w.recipe;
    if (recipe == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            w.conceiving ? 'Conception en cours…' : 'À assigner',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
          if (!w.conceiving)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                onPressed: w.onAssign,
                icon: const Icon(Icons.search, size: AppIconSize.small),
                label: const Text('Choisir une recette'),
              ),
            ),
        ],
      );
    }
    final tappable = recipe.id.isNotEmpty && w.onRecipeTap != null;
    return Row(
      children: [
        Flexible(
          // InkWell : le survol se voit à la souris, l'appui ouvre la fiche.
          child: InkWell(
            onTap: tappable ? w.onRecipeTap : null,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Text(
                recipe.titre,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: tappable ? theme.colorScheme.primary : null,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        if (w.isGeneratedByAI) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: 'Recette conçue par l\'IA',
            child: Icon(
              Icons.smart_toy_outlined,
              size: AppIconSize.inline,
              color: theme.colorScheme.tertiary,
            ),
          ),
        ],
        if (w.savedToPlanning) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: 'Déjà au planning',
            child: Icon(
              Icons.check_circle_outline,
              size: AppIconSize.inline,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActions(ThemeData theme) {
    final w = widget;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (w.isGenerating)
          const SizedBox.square(
            dimension: 48,
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (w.onGenerateWithAI != null)
          // Sans IA : la recette suivante de la liste classée par le
          // serveur. L'icône d'IA mentait sur ce geste.
          IconButton(
            icon: const Icon(Icons.autorenew),
            tooltip: w.recipe != null
                ? 'Autre suggestion'
                : 'Proposer une recette',
            onPressed: w.onGenerateWithAI,
          ),
        PopupMenuButton<_SlotAction>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'Plus d\'actions',
          onSelected: _onAction,
          itemBuilder: (_) => _menuItems(theme),
        ),
      ],
    );
  }

  Widget _buildDetailsToggle(ThemeData theme) {
    final dayLabel = DateFormat('EEEE d', 'fr').format(widget.date);
    // Un nœud à part : sans `container`, le libellé se fondait dans celui
    // de la carte entière.
    return Semantics(
      container: true,
      button: true,
      expanded: _expanded,
      onTap: _toggle,
      label:
          'Détails du repas du $dayLabel, '
          '${_expanded ? 'déplié' : 'replié'}',
      excludeSemantics: true,
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: AppIconSize.small,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'Détails',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDetails(ThemeData theme) {
    final w = widget;
    final format = w.dayConstraint.effectiveFormat;
    final storage = _buildStorageAdvice(theme);
    final origin = w.recipe != null
        // Sans `relaxed` : les écarts ont déjà leur ligne hors du pli.
        ? MealOriginLine.maybe(source: w.choiceSource, facts: w.justification)
        : null;
    // Les contraintes du jour, puis le repas dans son ordre (l'entrée, le
    // plat et son accompagnement, le dessert), puis la conservation, puis
    // l'origine du choix. Un composant « à choisir » est déjà affiché hors
    // du pli, comme avertissement.
    return [
      if (w.constraintsReadOnly)
        _buildConstraintSummary(theme, w.dayConstraint)
      else
        SlotConstraintsEditor(
          key: ValueKey('constraints-${w.index}'),
          constraint: w.dayConstraint,
          onMaxPrepChanged: w.onMaxPrepChanged,
          onTargetPortionsChanged: w.onTargetPortionsChanged,
          onReheatChanged: w.onReheatChanged,
          onNotesChanged: w.onNotesChanged,
          onFormatChanged: w.onFormatChanged,
          understandingOf: w.understandingOf,
        ),
      if (w.recipe != null) ...[
        const SizedBox(height: 8),
        if (format.wantsStarter && !w.missingStarter && w.starter != null)
          _buildCourseLine(
            theme,
            MealComponentRole.entree,
            w.starter,
            w.onChangeStarter,
            w.onRemoveStarter,
          ),
        ..._buildSideLines(theme),
        if (format.wantsDessert && !w.missingDessert && w.dessert != null)
          _buildCourseLine(
            theme,
            MealComponentRole.dessert,
            w.dessert,
            w.onChangeDessert,
            w.onRemoveDessert,
          ),
        for (var i = 0; i < w.extraCourses.length; i++)
          _buildExtraCourseLine(theme, w.extraCourses[i], i),
      ],
      if (storage != null) ...[const SizedBox(height: 4), storage],
      if (origin != null) ...[const SizedBox(height: 6), origin],
      // Le redimensionnement ne se lit que s'il a eu lieu : « Redimensionnée :
      // non » sur chaque créneau n'apprenait rien.
      if (w.recipe != null && w.wasResized) ...[
        const SizedBox(height: 4),
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
    ];
  }

  String get _resizeExplainability {
    final detail = (widget.resizeReason ?? '').trim();
    if (detail.isEmpty) return 'Redimensionnée';
    return 'Redimensionnée : $detail';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = widget;
    final summary = _summaryLine();
    final prep = w.prepDate;

    final warnings = <Widget>[
      if (w.missingStarter)
        _buildCourseLine(
          theme,
          MealComponentRole.entree,
          null,
          w.onChangeStarter,
          null,
        ),
      if (w.missingDessert)
        _buildCourseLine(
          theme,
          MealComponentRole.dessert,
          null,
          w.onChangeDessert,
          null,
        ),
      for (final need in w.missingSides) _buildMissingSideLine(theme, need),
      if (w.recipe == null)
        for (final u in w.unmet)
          if (u.service == 'plat' && u.isEmptyService)
            _buildEmptyDishLine(theme, u),
      if (w.recipe != null) ...[
        // Un critère relâché qui a sa phrase d'écart ne se dit qu'une fois.
        for (final c in RelaxedCriterion.listFrom(w.relaxed))
          if (!w.unmet.any((u) => u.key == c.key)) _buildRelaxedLine(theme, c),
        for (final u in w.unmet)
          if (!u.isEmptyService) _buildUnmetLine(theme, u),
      ],
      if (prep != null) _buildComputedStorage(theme, prep),
    ];

    return GestureDetector(
      // Clic droit : le même menu que ⋮, à l'endroit du clic.
      onSecondaryTapDown: (details) => _showContextMenu(details.globalPosition),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTimeButton(theme),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _buildTitle(theme),
                    ),
                  ),
                  _buildActions(theme),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (summary.isNotEmpty)
                      Text(
                        summary,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    for (final warning in warnings) ...[
                      const SizedBox(height: 4),
                      warning,
                    ],
                    const SizedBox(height: 4),
                    _buildDetailsToggle(theme),
                    if (_expanded) ...[
                      const SizedBox(height: 4),
                      ..._buildDetails(theme),
                      const SizedBox(height: 4),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConstraintSummary(ThemeData theme, DayConstraint constraint) {
    final chips = <Widget>[];
    if (constraint.maxPrepMinutes > 0) {
      chips.add(
        _constraintChip(theme, 'Prépa ${constraint.maxPrepMinutes} min max'),
      );
    }
    if (constraint.targetPortions > 0) {
      chips.add(_constraintChip(theme, '${constraint.targetPortions} parts'));
    }
    // Le réchauffage ne se lit que s'il est demandé : « Réchauffage: non »
    // sur chaque créneau n'apprenait rien.
    if (constraint.isBatchCooking) {
      chips.add(_constraintChip(theme, 'Réchauffage'));
    }
    // Le format ne se lit que s'il s'écarte du plat seul.
    if (constraint.mealFormat != null) {
      chips.add(_constraintChip(theme, constraint.mealFormat!.label));
    }

    final notes = constraint.notes.trim();
    if (chips.isEmpty && notes.isEmpty) {
      return Text(
        'Aucune contrainte pour ce jour',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
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
          if (widget.understandingOf != null)
            ConstraintUnderstandingLines(
              text: notes,
              translation: widget.understandingOf!(notes),
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

/// La dernière carte de la grille : ajoute un jour au cycle.
class AddSlotDayCard extends StatelessWidget {
  final VoidCallback onPressed;

  const AddSlotDayCard({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: const Icon(Icons.add_circle_outline),
      label: const Text('Ajouter un jour'),
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

  /// Faux pour un lecteur : « Conception IA » enregistre une recette, et le
  /// lecteur n'en crée pas. La source n'est alors ni proposée ni rendue.
  final bool allowAiCreation;

  const RecipeSourceSheet({
    super.key,
    required this.initialSources,
    this.initialBookIds = const {},
    this.availableBooks = const [],
    this.allowAiCreation = true,
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
    if (!widget.allowAiCreation) _selected.remove(RecipeSource.aiCreation);
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
                    if (widget.allowAiCreation ||
                        source != RecipeSource.aiCreation)
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

  /// Critères relâchés par le serveur pour ce choix (`relaxed_criteria`) :
  /// « Choisie par Kass'Dalle · déjà servi dans ce cycle, faute d'autre
  /// choix ». Une clé inconnue ne s'affiche pas.
  final List<String> relaxed;

  /// Écarts aux critères compris (`unmet_criteria`) : « 1 h 10, au-delà des
  /// 45 min demandées : peu d'autres choix ». Un critère relâché qui a sa
  /// phrase ici ne se dit qu'une fois.
  final List<UnmetCriterion> unmet;

  const MealOriginLine({
    super.key,
    this.source,
    this.facts,
    this.relaxed = const [],
    this.unmet = const [],
  });

  /// La ligne, ou `null` quand il n'y a rien à dire.
  static MealOriginLine? maybe({
    MealChoiceSource? source,
    String? facts,
    List<String> relaxed = const [],
    List<UnmetCriterion> unmet = const [],
  }) {
    final text = facts?.trim() ?? '';
    if (source == null &&
        text.isEmpty &&
        RelaxedCriterion.listFrom(relaxed).isEmpty &&
        unmet.isEmpty) {
      return null;
    }
    return MealOriginLine(
      source: source,
      facts: text,
      relaxed: relaxed,
      unmet: unmet,
    );
  }

  /// « dessert : aucun dessert sans fruits à coque », « 1 h 10, au-delà des
  /// 45 min demandées : peu d'autres choix » — en minuscule, à la suite de
  /// l'origine.
  static String _unmetPhrase(UnmetCriterion u) {
    final detail = u.detail.endsWith('.')
        ? u.detail.substring(0, u.detail.length - 1)
        : u.detail;
    final lower = detail.isEmpty
        ? detail
        : detail[0].toLowerCase() + detail.substring(1);
    return switch (u.service) {
      'entree' => 'entrée : $lower',
      'dessert' => 'dessert : $lower',
      _ => lower,
    };
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
    final text = [
      for (final c in RelaxedCriterion.listFrom(relaxed))
        if (!unmet.any((u) => u.key == c.key)) c.phrase,
      for (final u in unmet) _unmetPhrase(u),
      if ((facts?.trim() ?? '').isNotEmpty) facts!.trim(),
    ].join(' · ');
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
