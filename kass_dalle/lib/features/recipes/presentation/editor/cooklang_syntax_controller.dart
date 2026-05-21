import 'package:flutter/material.dart';

/// Custom [TextEditingController] that applies live syntax highlighting
/// to CookLang + Markdown text using regex-based [TextSpan] rendering.
///
/// Color palette (Material-aligned, readable on white background):
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

  // ── Colors ────────────────────────────────────────────────────────────────

  static const _colorMeta = Color(0xFF9E9E9E); // grey 500
  static const _colorComment = Color(0xFF6A9955); // VS Code green
  static const _colorSection = Color(0xFF3949AB); // indigo 600
  static const _colorIngredient = Color(0xFF1565C0); // blue 800
  static const _colorUtensil = Color(0xFFE64A19); // deep-orange 700
  static const _colorTimer = Color(0xFF6A1B9A); // purple 800
  static const _colorImage = Color(0xFF00838F); // teal 700
  static const _colorContinuation = Color(0xFF607D8B); // blue-grey 600

  // ── Base style ────────────────────────────────────────────────────────────

  static const _base = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    color: Color(0xFF212121), // near-black
  );

  // ── buildTextSpan ─────────────────────────────────────────────────────────

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final fullText = text;
    if (fullText.isEmpty) {
      return TextSpan(style: style ?? _base, text: '');
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
      add(m.start, m.end, _base.copyWith(color: _colorMeta));
    }
    for (final m in _reComment.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        _base.copyWith(color: _colorComment, fontStyle: FontStyle.italic),
      );
    }
    for (final m in _reSection.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        _base.copyWith(
          color: _colorSection,
          fontWeight: FontWeight.bold,
          fontSize: 15,
        ),
      );
    }
    for (final m in _reImage.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        _base.copyWith(color: _colorImage, fontStyle: FontStyle.italic),
      );
    }
    for (final m in _reContinuation.allMatches(fullText)) {
      add(
        m.start,
        m.end,
        _base.copyWith(color: _colorContinuation, fontWeight: FontWeight.bold),
      );
    }

    // ── Inline token patterns ──────────────────────────────────────────────

    for (final m in _reIngredient.allMatches(fullText)) {
      if (!_isInLinePattern(fullText, m.start)) {
        add(
          m.start,
          m.end,
          _base.copyWith(color: _colorIngredient, fontWeight: FontWeight.w600),
        );
      }
    }
    for (final m in _reUtensil.allMatches(fullText)) {
      if (!_isInLinePattern(fullText, m.start)) {
        add(
          m.start,
          m.end,
          _base.copyWith(color: _colorUtensil, fontWeight: FontWeight.w600),
        );
      }
    }
    for (final m in _reTimer.allMatches(fullText)) {
      if (!_isInLinePattern(fullText, m.start)) {
        add(
          m.start,
          m.end,
          _base.copyWith(color: _colorTimer, fontWeight: FontWeight.w600),
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
          TextSpan(text: fullText.substring(cursor, span.start), style: _base),
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
      children.add(TextSpan(text: fullText.substring(cursor), style: _base));
    }

    return TextSpan(style: style ?? _base, children: children);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns true if the position [pos] is inside a line that already starts
  /// with `>>`, `--`, or `##` — so inline tokens inside those lines are
  /// skipped (the line-level style takes precedence).
  static bool _isInLinePattern(String text, int pos) {
    final lineStart = text.lastIndexOf('\n', pos - 1) + 1;
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
