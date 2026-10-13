import 'package:cloud_firestore/cloud_firestore.dart';

import '../../groups/domain/family_group.dart';
import 'planned_meal.dart';
import 'planning_reach.dart';

/// Longueur maximale d'un nom libre suggéré (`free_title`), celle des règles.
const kSuggestionFreeTitleMax = 60;

/// Longueur maximale du mot qui accompagne une suggestion (`note`).
const kSuggestionNoteMax = 200;

/// Longueur maximale du titre copié d'une recette (`recipe_titre`).
const kSuggestionRecipeTitleMax = 200;

/// Suggestions au plus par auteur, par groupe et par jour. Tenu par le
/// client : une règle Firestore ne compte pas des documents.
const kSuggestionsPerAuthorPerDay = 5;

/// Profondeur des suggestions lues en continu, en jours avant aujourd'hui.
/// Les plus anciennes se lisent à la demande (« Voir les plus anciennes »).
const kSuggestionHistoryDays = 90;

/// Une suggestion de repas : un membre d'un groupe propose au propriétaire
/// un plat pour un jour du planning du groupe (`meal_suggestions/{id}`).
///
/// Une recette ([recipeId], titre copié dans [recipeTitre]) ou un nom libre
/// ([freeTitle]), jamais les deux. Pas de statut : le propriétaire lit, et
/// planifie lui-même s'il retient l'idée. Le titre d'une recette privée est
/// copié : le propriétaire le lit sans ouvrir la fiche.
class MealSuggestion {
  final String id;
  final String groupId;

  /// Le propriétaire du groupe à la création, vérifié par les règles :
  /// c'est sur ce champ que le propriétaire lit ses suggestions reçues.
  final String groupOwnerId;
  final String authorUid;

  /// Le jour visé, à minuit heure locale.
  final DateTime day;
  final String? recipeId;
  final String? recipeTitre;
  final String? freeTitle;
  final String? note;

  /// Posée par le serveur ; `null` tant que l'écriture locale n'est pas
  /// confirmée.
  final DateTime? createdAt;

  const MealSuggestion({
    required this.id,
    required this.groupId,
    required this.groupOwnerId,
    required this.authorUid,
    required this.day,
    this.recipeId,
    this.recipeTitre,
    this.freeTitle,
    this.note,
    this.createdAt,
  });

  /// Le plat proposé, tel qu'il s'affiche.
  String get title => recipeTitre ?? freeTitle ?? '';

  /// Un nom libre, sans recette liée.
  bool get isFreeName => recipeId == null;

  /// Le jour au format stocké, `AAAA-MM-JJ`.
  String get dayKey => mealSuggestionDayKey(day);

  /// Lit un document. `null` s'il est mal formé (jour illisible, ni recette
  /// ni nom libre) : il est écarté de l'affichage, pas fatal.
  static MealSuggestion? fromFirestore(String id, Map<String, dynamic> data) {
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    final day = parseMealSuggestionDay(data['day']);
    final groupId = text(data['group_id']);
    final owner = text(data['group_owner_id']);
    final author = text(data['author_uid']);
    final recipeId = text(data['recipe_id']);
    final recipeTitre = text(data['recipe_titre']);
    final freeTitle = text(data['free_title']);
    if (day == null || groupId == null || owner == null || author == null) {
      return null;
    }
    final hasRecipe = recipeId != null && recipeTitre != null;
    if (!hasRecipe && freeTitle == null) return null;
    final created = data['created_at'];
    return MealSuggestion(
      id: id,
      groupId: groupId,
      groupOwnerId: owner,
      authorUid: author,
      day: day,
      recipeId: hasRecipe ? recipeId : null,
      recipeTitre: hasRecipe ? recipeTitre : null,
      freeTitle: hasRecipe ? null : freeTitle,
      note: text(data['note']),
      createdAt: created is Timestamp ? created.toDate() : null,
    );
  }

  /// La forme écrite, celle qu'admettent les règles : `created_at` posé par
  /// le serveur, champs absents plutôt que nuls.
  Map<String, dynamic> toFirestore() => {
    'group_id': groupId,
    'group_owner_id': groupOwnerId,
    'author_uid': authorUid,
    'day': dayKey,
    if (recipeId != null) 'recipe_id': recipeId,
    if (recipeId != null) 'recipe_titre': recipeTitre,
    if (recipeId == null) 'free_title': freeTitle,
    if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
    'created_at': FieldValue.serverTimestamp(),
  };
}

/// Ce qu'un membre suggère, avant écriture : une recette ou un nom libre,
/// et un mot facultatif. Les bornes des règles y sont appliquées.
class MealSuggestionDraft {
  final String groupId;
  final String groupOwnerId;
  final DateTime day;
  final String? recipeId;
  final String title;
  final String note;

  const MealSuggestionDraft({
    required this.groupId,
    required this.groupOwnerId,
    required this.day,
    required this.recipeId,
    required this.title,
    this.note = '',
  });

  /// Le nom libre dépasse [kSuggestionFreeTitleMax] caractères.
  bool get freeTitleTooLong =>
      recipeId == null && title.trim().length > kSuggestionFreeTitleMax;

  /// La suggestion de [authorUid], prête à écrire. Le titre copié d'une
  /// recette est tronqué à [kSuggestionRecipeTitleMax] caractères, le mot à
  /// [kSuggestionNoteMax] ; un nom libre trop long lève [ArgumentError] :
  /// l'écran ne l'envoie pas.
  MealSuggestion toSuggestion(String authorUid) {
    final name = title.trim();
    if (name.isEmpty) throw ArgumentError('Plat absent');
    if (freeTitleTooLong) throw ArgumentError('Nom libre trop long');
    final trimmedNote = note.trim();
    return MealSuggestion(
      id: '',
      groupId: groupId,
      groupOwnerId: groupOwnerId,
      authorUid: authorUid,
      day: DateTime(day.year, day.month, day.day),
      recipeId: recipeId,
      recipeTitre: recipeId == null
          ? null
          : _clip(name, kSuggestionRecipeTitleMax),
      freeTitle: recipeId == null ? name : null,
      note: trimmedNote.isEmpty ? null : _clip(trimmedNote, kSuggestionNoteMax),
    );
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}

/// `AAAA-MM-JJ` du jour local de [day].
String mealSuggestionDayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Le jour `AAAA-MM-JJ`, à minuit heure locale ; `null` si [raw] est mal
/// formé ou désigne une date impossible.
DateTime? parseMealSuggestionDay(Object? raw) {
  if (raw is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  final y = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  final d = int.parse(match.group(3)!);
  final day = DateTime(y, m, d);
  if (day.year != y || day.month != m || day.day != d) return null;
  return day;
}

/// Suggestions des jours à venir, aujourd'hui compris : le badge du
/// propriétaire.
int upcomingSuggestionCount(
  Iterable<MealSuggestion> suggestions,
  DateTime today,
) {
  final from = DateTime(today.year, today.month, today.day);
  return suggestions.where((s) => !s.day.isBefore(from)).length;
}

/// Le repas du planning du groupe qui reprend déjà [suggestion] ce jour-là :
/// même groupe, même jour, et même recette ou même titre (casse et espaces
/// ignorés). `null` sinon. Calculé à l'affichage, rien n'est stocké.
PlannedMeal? plannedMatchFor(
  MealSuggestion suggestion,
  Iterable<PlannedMeal> meals,
) {
  String norm(String s) => s.trim().toLowerCase();
  for (final m in meals) {
    if (m.groupId != suggestion.groupId) continue;
    final at = m.plannedAt;
    if (at.year != suggestion.day.year ||
        at.month != suggestion.day.month ||
        at.day != suggestion.day.day) {
      continue;
    }
    final sameRecipe =
        suggestion.recipeId != null && m.recipeId == suggestion.recipeId;
    if (sameRecipe || norm(m.recipeTitre) == norm(suggestion.title)) return m;
  }
  return null;
}

/// Les suggestions rangées par jour, jours croissants, et dans un jour par
/// ordre d'arrivée.
Map<DateTime, List<MealSuggestion>> suggestionsByDay(
  Iterable<MealSuggestion> suggestions,
) {
  final sorted = suggestions.toList()
    ..sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      if (byDay != 0) return byDay;
      final at = a.createdAt, bt = b.createdAt;
      // Une écriture pas encore confirmée vient en dernier.
      if (at == null || bt == null) {
        return at == bt ? 0 : (at == null ? 1 : -1);
      }
      return at.compareTo(bt);
    });
  final out = <DateTime, List<MealSuggestion>>{};
  for (final s in sorted) {
    (out[s.day] ??= []).add(s);
  }
  return out;
}

/// « aujourd'hui », « hier », « il y a 3 jours » : l'âge d'une suggestion.
/// Vide sans date (écriture pas encore confirmée).
String suggestionAgeLabel(DateTime? createdAt, DateTime now) {
  if (createdAt == null) return 'à l\'instant';
  final created = DateTime(createdAt.year, createdAt.month, createdAt.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(created).inDays;
  if (days <= 0) return 'aujourd\'hui';
  if (days == 1) return 'hier';
  return 'il y a $days jours';
}

/// « 1 suggestion », « 2 suggestions ».
String suggestionCountLabel(int n) =>
    n > 1 ? '$n suggestions' : '$n suggestion';

/// Les groupes où [myUid] suggère : groupes actifs (le serveur les ouvre
/// dans `planning_reach.group_ids`) dont il est membre sans en être le
/// propriétaire. Triés par nom.
List<FamilyGroup> suggestableGroups({
  required List<FamilyGroup> groups,
  required String myUid,
  required PlanningReach? reach,
}) {
  final out = [
    for (final g in groups)
      if (g.ownerId != myUid &&
          g.isMember(myUid) &&
          (reach?.readsGroup(g.id) ?? false))
        g,
  ];
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// Les groupes où [myUid] reçoit des suggestions : groupes actifs dont il
/// est le propriétaire et qui comptent au moins un autre membre. Triés par
/// nom.
List<FamilyGroup> suggestionOwnerGroups({
  required List<FamilyGroup> groups,
  required String myUid,
  required PlanningReach? reach,
}) {
  final out = [
    for (final g in groups)
      if (g.ownerId == myUid &&
          (reach?.readsGroup(g.id) ?? false) &&
          g.memberIds.any((id) => id != myUid))
        g,
  ];
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
