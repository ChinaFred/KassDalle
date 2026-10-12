/// Quels plannings l'écran du planning affiche.
///
/// Chaque rôle a son défaut :
/// - un éditeur ou un administrateur voit son planning, et pas ceux qu'on
///   partage avec lui — y compris ceux reçus après coup ;
/// - un lecteur voit tous les plannings partagés avec lui, et pas le sien
///   (il ne planifie plus ; il ne garde que ses repas antérieurs).
///
/// L'appareil ne mémorise que l'**écart** à ce défaut : les plannings que la
/// personne a basculés. Un planning partagé demain s'affiche donc selon le
/// défaut du rôle, sans rien réécrire.
library;

/// Le planning [ownerUid] est-il affiché par défaut pour [myUid] ?
bool planningShownByDefault({
  required String ownerUid,
  required String myUid,
  required bool canPlan,
}) => ownerUid == myUid ? canPlan : !canPlan;

/// Les plannings affichés parmi [available], d'après le défaut du rôle et
/// les plannings basculés [toggled]. L'ordre de [available] est gardé.
List<String> displayedPlannings({
  required List<String> available,
  required String myUid,
  required bool canPlan,
  required Set<String> toggled,
}) => [
  for (final uid in available)
    if (planningShownByDefault(ownerUid: uid, myUid: myUid, canPlan: canPlan) !=
        toggled.contains(uid))
      uid,
];

/// Libellé du bouton-puce du téléphone : « Plannings : Moi, Marie », puis
/// « Plannings : Moi, Marie, +2 » au-delà de deux, « Plannings : aucun » sans
/// rien d'affiché.
String planningSelectorLabel(List<String> displayedNames) {
  if (displayedNames.isEmpty) return 'Plannings : aucun';
  if (displayedNames.length <= 2) {
    return 'Plannings : ${displayedNames.join(', ')}';
  }
  return 'Plannings : ${displayedNames.take(2).join(', ')}, '
      '+${displayedNames.length - 2}';
}

/// Les bascules mémorisées après un appui sur [ownerUid] : il entre dans
/// l'écart au défaut, ou en sort.
Set<String> togglePlanning(Set<String> toggled, String ownerUid) =>
    toggled.contains(ownerUid)
    ? ({...toggled}..remove(ownerUid))
    : {...toggled, ownerUid};
