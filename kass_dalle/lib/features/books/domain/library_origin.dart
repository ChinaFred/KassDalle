/// D'où vient la bibliothèque qu'on est en train de lire.
///
/// Un livre appartient à la personne qui l'a créé. Les autres membres ne le
/// voient que parce qu'un groupe familial les réunit, et l'écran n'en disait
/// rien : deux livres au même titre, tenus par deux personnes différentes,
/// s'affichaient exactement pareil.
library;

/// Phrase d'origine d'un livre, ou `null` quand il n'y a rien à dire.
///
/// [ownerName] est le nom préféré du propriétaire, pas son nom de compte
/// Google : c'est sous ce nom-là que la famille se reconnaît.
///
/// [groupNames] liste les groupes familiaux qui relient le lecteur au
/// propriétaire. Elle est vide quand le lien n'est pas connu — un livre lu par
/// un administrateur, par exemple, qui voit tout sans partager de groupe.
String? libraryOriginLabel({
  required bool isMine,
  required String? ownerName,
  required List<String> groupNames,
}) {
  if (isMine) return 'Ma bibliothèque';

  final name = ownerName?.trim() ?? '';
  // Sans nom, la phrase n'apprendrait rien : « au travers de … » ne désigne
  // personne. Se taire vaut mieux que meubler.
  if (name.isEmpty) return null;

  final groups = groupNames
      .map((g) => g.trim())
      .where((g) => g.isNotEmpty)
      .toList();
  if (groups.isEmpty) return 'Bibliothèque de $name';

  final quoted = groups.map((g) => '« $g »').join(' et ');
  final prefix = groups.length == 1
      ? 'Issu du groupe familial'
      : 'Issu des groupes familiaux';
  return '$prefix $quoted, au travers de $name';
}
