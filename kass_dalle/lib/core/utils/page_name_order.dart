/// Ordre des pages d'un même import, déduit de leur nom de fichier.
///
/// Le sélecteur de fichiers rend une sélection multiple dans l'ordre que lui
/// donne le système, qui n'est pas celui des pages : « page10.jpg » y arrive
/// avant « page2.jpg », et la recette part à l'analyse dans le désordre sans
/// qu'aucune erreur soit levée.
///
/// La comparaison lit donc les suites de chiffres comme des nombres, et le
/// reste caractère par caractère, sans tenir compte de la casse.
library;

/// Compare deux noms de fichier en traitant les suites de chiffres comme des
/// nombres. Renvoie une valeur négative si [a] précède [b].
int comparePageNames(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    if (_isDigit(ca) && _isDigit(cb)) {
      final endA = _endOfDigits(la, i);
      final endB = _endOfDigits(lb, j);
      final cmp = _compareDigits(la.substring(i, endA), lb.substring(j, endB));
      if (cmp != 0) return cmp;
      i = endA;
      j = endB;
      continue;
    }
    if (ca != cb) return ca - cb;
    i++;
    j++;
  }
  final byRest = (la.length - i).compareTo(lb.length - j);
  if (byRest != 0) return byRest;
  // Deux noms qui ne diffèrent que par la casse ou par des zéros de tête :
  // l'ordre brut tranche, pour que le tri reste stable et reproductible.
  return a.compareTo(b);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

int _endOfDigits(String name, int start) {
  var end = start;
  while (end < name.length && _isDigit(name.codeUnitAt(end))) {
    end++;
  }
  return end;
}

/// Compare deux suites de chiffres sans passer par `int`.
///
/// Un horodatage collé à un identifiant dépasse la capacité d'un entier sur le
/// web, où les nombres sont des flottants : deux valeurs distinctes s'y
/// retrouveraient égales. La longueur, zéros de tête retirés, puis l'ordre des
/// chiffres, donnent le même résultat sans cette limite.
int _compareDigits(String a, String b) {
  final ta = _withoutLeadingZeros(a);
  final tb = _withoutLeadingZeros(b);
  final byLength = ta.length.compareTo(tb.length);
  if (byLength != 0) return byLength;
  return ta.compareTo(tb);
}

String _withoutLeadingZeros(String digits) {
  var start = 0;
  while (start < digits.length - 1 && digits.codeUnitAt(start) == 0x30) {
    start++;
  }
  return digits.substring(start);
}
