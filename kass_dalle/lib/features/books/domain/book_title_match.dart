import '../../../core/utils/ingredient_name.dart';

/// Vrai quand [title] contient [query], sans tenir compte des accents, des
/// majuscules ni de la ponctuation.
///
/// « creation » trouve « Mes créations Kass'Dalle », et « kass d » aussi : une
/// apostrophe et une espace se valent. Une saisie vide correspond à tout.
bool bookTitleMatches(String title, String query) {
  final wanted = normalizeBase(query);
  if (wanted.isEmpty) return true;
  return normalizeBase(title).contains(wanted);
}

/// Vrai quand [a] et [b] ne diffèrent que par les accents, les majuscules ou la
/// ponctuation.
///
/// Sert à retenir, parmi plusieurs titres qui contiennent la saisie, celui
/// qu'elle écrit en entier : « COOK » avant « COOK 2 ».
bool bookTitleEquals(String a, String b) =>
    normalizeBase(a) == normalizeBase(b);
