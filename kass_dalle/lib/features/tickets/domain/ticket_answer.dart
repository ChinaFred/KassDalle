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

/// Caractères invisibles retirés avant la recherche (U+200B à U+200D,
/// U+2060).
final _invisibleChars = RegExp('[\u200B-\u200D\u2060]');

/// Ramène les caractères dont la forme NFKC tombe dans l'alphabet d'une
/// adresse : formes pleine chasse U+FF01 à U+FF5E, petites formes U+FE52
/// (.), U+FE62 (+), U+FE63 (-), U+FE6A (%), U+FE6B (@), et U+2024 (.). Dart
/// n'a pas de NFKC : le serveur, qui l'applique en entier, reste le contrôle
/// qui décide.
String _foldForEmail(String text) {
  final out = StringBuffer();
  for (final rune in text.replaceAll(_invisibleChars, '').runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else {
      out.writeCharCode(switch (rune) {
        0xFE52 || 0x2024 => 0x2E,
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

final _emailPattern = RegExp(
  r'[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}',
);

/// Vrai si [text] contient une adresse e-mail : partie locale ASCII, `@`,
/// domaine à étiquettes, suffixe d'au moins deux lettres. Une mention
/// (`@ChinaFred`) n'en est pas une. Même règle que `containsEmailAddress` :
/// caractères invisibles retirés, formes pleine chasse et petites formes
/// ramenées avant la recherche.
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
