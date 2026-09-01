/// Ordre des pages d'un même import, déduit de leur nom de fichier.
///
/// Le sélecteur de fichiers rend une sélection multiple dans l'ordre que lui
/// donne le système, qui n'est pas celui des pages : « page10.jpg » y arrive
/// avant « page2.jpg », et la recette se retrouve dans le désordre sans qu'une
/// erreur soit levée.
///
/// La comparaison lit donc les suites de chiffres comme des nombres, et le
/// reste comme du texte, sans tenir compte de la casse. « IMG_9.jpg » précède
/// « IMG_10.jpg », « p2 » précède « p10 ».
library;

/// Compare deux noms de fichier en traitant les suites de chiffres comme des
/// nombres. Renvoie une valeur négative si [a] précède [b].
int comparePageNames(String a, String b) {
  final ia = _segments(a);
  final ib = _segments(b);
  for (var i = 0; i < ia.length && i < ib.length; i++) {
    final sa = ia[i];
    final sb = ib[i];
    final int cmp;
    if (sa.number != null && sb.number != null) {
      cmp = sa.number!.compareTo(sb.number!);
    } else {
      cmp = sa.text.compareTo(sb.text);
    }
    if (cmp != 0) return cmp;
  }
  final byLength = ia.length.compareTo(ib.length);
  if (byLength != 0) return byLength;
  // Deux noms qui ne diffèrent que par la casse ou par les zéros de tête :
  // l'ordre brut tranche, pour que le tri reste stable et reproductible.
  return a.compareTo(b);
}

/// Découpe un nom en segments alternant texte et nombres.
///
/// Les nombres au-delà de la capacité d'un entier — un horodatage collé à un
/// identifiant, par exemple — restent comparés comme du texte : `int.tryParse`
/// rend `null`, et le segment retombe sur la comparaison alphabétique.
List<_Segment> _segments(String name) {
  final segments = <_Segment>[];
  final buffer = StringBuffer();
  bool? bufferIsDigits;

  void flush() {
    if (buffer.isEmpty) return;
    final raw = buffer.toString();
    segments.add(
      _Segment(
        text: bufferIsDigits == true ? raw : raw.toLowerCase(),
        number: bufferIsDigits == true ? int.tryParse(raw) : null,
      ),
    );
    buffer.clear();
  }

  for (final rune in name.runes) {
    final isDigit = rune >= 0x30 && rune <= 0x39;
    if (bufferIsDigits != null && isDigit != bufferIsDigits) flush();
    bufferIsDigits = isDigit;
    buffer.writeCharCode(rune);
  }
  flush();
  return segments;
}

class _Segment {
  final String text;
  final int? number;

  const _Segment({required this.text, required this.number});
}
