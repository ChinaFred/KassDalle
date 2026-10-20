import 'package:flutter/material.dart';

import 'cooklang_editor_colors.dart';

/// Custom [TextEditingController] that applies live syntax highlighting
/// to CookLang + Markdown text using regex-based [TextSpan] rendering.
///
/// Couleurs : [CooklangPalette], selon la luminosité du thème ; texte sans
/// syntaxe en `onSurface`.
///   - Metadata  `>> …`    : grey          (discrete)
///   - Comments  `-- …`    : green-grey italic
///   - Sections  `## …`    : indigo bold   (enlarged via fontSize)
///   - Ingredients `@…`    : blue
///   - Utensils    `#…`    : deep-orange
///   - Timers      `~…`    : purple
class CooklangSyntaxController extends TextEditingController {
  // ── Regex patterns ────────────────────────────────────────────────────────

  /// Full metadata line:  >> key: value
  static final _reMeta = RegExp(r'^(>>.*)', multiLine: true);

  /// Full comment line:   -- some note  OR  > conseil
  static final _reComment = RegExp(r'^(--|>\s).*', multiLine: true);

  /// Full section line:   ## Title  OR  == Title ==
  static final _reSection = RegExp(
    r'^(##\s+.*|==\s*.+?\s*==)',
    multiLine: true,
  );

  /// Ingredient token:    @name  or  @name{qty%unit}
  static final _reIngredient = RegExp(r'@[^{@#~\n,;.!?()\[\]]+(?:\{[^}]*\})?');

  /// Utensil token:       #name  or  #name{}
  static final _reUtensil = RegExp(r'#[^{@#~\n,;.!?()\[\]]+(?:\{[^}]*\})?');

  /// Timer token:         ~{qty%unit}  or  ~name{qty%unit}
  static final _reTimer = RegExp(r'~[^{@#~\n]*\{[^}]*\}');

  /// Image block:  ![position](url)
  static final _reImage = RegExp(r'^!\[[^\]]*\]\([^)]+\)', multiLine: true);

  /// Continuation prefix:  + (just the leading "+ " marker)
  static final _reContinuation = RegExp(r'^\+\s', multiLine: true);

  // ── Base style ────────────────────────────────────────────────────────────

  /// Style du texte sans syntaxe ; la couleur vient du thème, à l'appel.
  static const _baseNoColor = TextStyle(fontFamily: 'monospace', fontSize: 13);

  // ── buildTextSpan ─────────────────────────────────────────────────────────

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final theme = Theme.of(context);
    final palette = CooklangPalette.of(theme.brightness);
    final base = _baseNoColor.copyWith(color: theme.colorScheme.onSurface);
    final fullText = text;
    if (fullText.isEmpty) {
      return TextSpan(style: style ?? base, text: '');
    }

    // We build a list of (start, end, style) spans covering the full string,
    // then merge adjacent same-style regions into TextSpan children.

    // Start with a default "unstyled" map (index → style)
    final spans = <_Span>[];
    final len = fullText.length;

    // Helper: add a span (only if the range is non-empty)
    void add(int start, int end, TextStyle s) {
      if (end > start) spans.add(_Span(start, end, s));
    }

    // ── Line-level patterns (applied first, cover the whole line) ──────────

    for (final m in _reMeta.allMatches(fullText)) {
      add(m.start, m.end, base.copyWith(color: palette.meta));
    }
    for (final m in _reComment.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        base.copyWith(color: palette.comment, fontStyle: FontStyle.italic),
      );
    }
    for (final m in _reSection.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        base.copyWith(
          color: palette.section,
          fontWeight: FontWeight.bold,
          fontSize: 15,
        ),
      );
    }
    for (final m in _reImage.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        base.copyWith(color: palette.image, fontStyle: FontStyle.italic),
      );
    }
    for (final m in _reContinuation.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        base.copyWith(color: palette.continuation, fontWeight: FontWeight.bold),
      );
    }

    // ── Inline token patterns ──────────────────────────────────────────────

    for (final m in _reIngredient.allMatches(fullText)) {
      if (!_isInLinePattern(fullText, m.start)) {
        add(
          m.start,
          m.end,
          base.copyWith(color: palette.ingredient, fontWeight: FontWeight.w600),
        );
      }
    }
    for (final m in _reUtensil.allMatches(fullText)) {
      if (!_isInLinePattern(fullText, m.start)) {
        add(
          m.start,
          m.end,
          base.copyWith(color: palette.utensil, fontWeight: FontWeight.w600),
        );
      }
    }
    for (final m in _reTimer.allMatches(fullText)) {
      if (!_isInLinePattern(fullText, m.start)) {
        add(
          m.start,
          m.end,
          base.copyWith(color: palette.timer, fontWeight: FontWeight.w600),
        );
      }
    }

    // ── Merge & sort ───────────────────────────────────────────────────────

    // Sort spans by start, then by specificity (longer = more specific wins)
    spans.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : b.length.compareTo(a.length),
    ); // wider span first

    // Build non-overlapping TextSpan list using a cursor
    final children = <TextSpan>[];
    int cursor = 0;

    for (final span in spans) {
      if (span.start < cursor) continue; // already covered
      if (span.start > cursor) {
        // Gap before this span → plain text
        children.add(
          TextSpan(text: fullText.substring(cursor, span.start), style: base),
        );
      }
      children.add(
        TextSpan(
          text: fullText.substring(span.start, span.end),
          style: span.style,
        ),
      );
      cursor = span.end;
    }

    // Remaining text after last span
    if (cursor < len) {
      children.add(TextSpan(text: fullText.substring(cursor), style: base));
    }

    return TextSpan(style: style ?? base, children: children);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns true if the position [pos] is inside a line that already starts
  /// with `>>`, `--`, or `##` — so inline tokens inside those lines are
  /// skipped (the line-level style takes precedence).
  static bool _isInLinePattern(String text, int pos) {
    // `lastIndexOf` refuse une position négative : un jeton en tête de texte
    // (pos 0) commence la première ligne.
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    final linePrefix = text.substring(lineStart, pos).trimLeft();
    return linePrefix.startsWith('>>') ||
        linePrefix.startsWith('--') ||
        linePrefix.startsWith('##');
  }
}

/// Internal helper holding a styled range.
class _Span {
  final int start;
  final int end;
  final TextStyle style;
  int get length => end - start;
  const _Span(this.start, this.end, this.style);
}
