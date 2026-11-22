/// Réponse de l'administrateur à la dernière analyse d'un ticket
/// (« Répondre », callable `answerTicketAnalysis`).
///
/// Le texte part sur un dépôt GitHub public. Le serveur refait les mêmes
/// contrôles (`readAnswerText`, `functions/src/tickets/rules.ts`) : logique
/// dupliquée, verrouillée par `test-fixtures/ticket_answer_text.json`.
library;

/// Longueur minimale de la réponse, espaces de bord retirées
/// (`ANSWER_MIN_CHARS`).
const kTicketAnswerMinChars = 5;

/// Longueur maximale de la réponse (`ANSWER_MAX_CHARS`).
const kTicketAnswerMaxChars = 4000;

const kTicketAnswerTooShortMessage =
    'La réponse doit faire au moins 5 caractères.';
const kTicketAnswerEmailMessage = 'Retirez l\'adresse e-mail avant de publier.';

/// Caractères invisibles retirés avant la recherche : tout point de code
/// `Default_Ignorable_Code_Point` d'Unicode (U+00AD, U+200B à U+200F, U+202A
/// à U+202E, U+2060 à U+206F, U+FEFF, étiquettes U+E0000 à U+E0FFF…) et les
/// contrôles C0 hors tabulation et sauts de ligne, DEL et C1 (U+0080 à
/// U+009F), et les ancres d'annotation U+FFF9 à U+FFFB. Même liste que
/// `INVISIBLE_CHARS` côté serveur.
final _invisibleChars = RegExp(
  r'(?![\t\n\r])[\p{Default_Ignorable_Code_Point}\p{Cc}\uFFF9-\uFFFB]',
  unicode: true,
);

/// Ramène les caractères dont la forme NFKC tombe dans l'alphabet d'une
/// adresse : formes pleine chasse U+FF01 à U+FF5E, petites formes U+FE52
/// (.), U+FE62 (+), U+FE63 (-), U+FE6A (%), U+FE6B (@), et U+2024 (.). Le
/// point idéographique U+3002, sa forme demi-chasse U+FF61 et sa forme
/// verticale U+FE12 deviennent aussi « . ». Dart n'a pas de NFKC : le serveur, qui l'applique en entier, reste
/// le contrôle qui décide.
String _foldForEmail(String text) {
  final out = StringBuffer();
  for (final rune in text.replaceAll(_invisibleChars, '').runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else {
      out.writeCharCode(switch (rune) {
        0xFE52 || 0x2024 || 0x3002 || 0xFF61 || 0xFE12 => 0x2E,
        0xFE62 => 0x2B,
        0xFE63 => 0x2D,
        0xFE6A => 0x25,
        0xFE6B => 0x40,
        _ => rune,
      });
    }
  }
  return out.toString();
}

/// Lettres et chiffres de tout alphabet, marques diacritiques comprises : un
/// domaine accentué (`exemplé.fr`) ou en alphabet non latin (`пример.рф`) est
/// une adresse. Suffixe : deux lettres au moins (un suffixe punycode `xn--…`
/// commence par deux lettres et en fait partie). Même motif que `EMAIL_PATTERN` côté serveur.
final _emailPattern = RegExp(
  r'[\p{L}\p{M}\p{N}._%+-]+@[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}-]*[\p{L}\p{M}\p{N}])?'
  r'(?:\.[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}-]*[\p{L}\p{M}\p{N}])?)*'
  r'\.\p{L}[\p{L}\p{M}]+',
  unicode: true,
);

/// Vrai si [text] contient une adresse e-mail : partie locale, `@`, domaine à
/// étiquettes, suffixe d'au moins deux lettres (punycode compris), en lettres et
/// chiffres de tout alphabet. Une mention (`@ChinaFred`) n'en est pas une.
/// Même règle que `containsEmailAddress` : caractères invisibles retirés,
/// formes pleine chasse, petites formes et point idéographique ramenés avant
/// la recherche.
bool ticketTextContainsEmail(String text) =>
    _emailPattern.hasMatch(_foldForEmail(text));

/// Le message à poser sous le champ « Votre réponse », ou `null` si le texte
/// peut partir. La longueur maximale est tenue par le champ lui-même.
String? ticketAnswerFieldError(String text) {
  final trimmed = text.trim();
  if (trimmed.length < kTicketAnswerMinChars) {
    return kTicketAnswerTooShortMessage;
  }
  if (ticketTextContainsEmail(trimmed)) return kTicketAnswerEmailMessage;
  return null;
}

const kTicketCloseTooShortMessage =
    'Le commentaire doit faire au moins 5 caractères.';

/// Le message à poser sous le champ « Commentaire de clôture », ou `null` si
/// le texte peut partir. Mêmes règles que [ticketAnswerFieldError]
/// (`readCloseComment` côté serveur).
String? ticketCloseFieldError(String text) {
  final trimmed = text.trim();
  if (trimmed.length < kTicketAnswerMinChars) {
    return kTicketCloseTooShortMessage;
  }
  if (ticketTextContainsEmail(trimmed)) return kTicketAnswerEmailMessage;
  return null;
}
