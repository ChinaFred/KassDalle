/// Data model for the WYSIWYG visual editor.
///
/// A CookLang recipe is parsed into a flat list of [EditorBlock]s.
/// Each block corresponds to one logical "line" in the source text and
/// carries both its raw representation (the source-of-truth string) and
/// its semantic content (segments for display, key/value for metadata).
library;

// ── Enums ─────────────────────────────────────────────────────────────────────

enum BlockType {
  /// `>> key: value`  — metadata header
  metadata,

  /// `## Title text`  — section heading (no inline chips allowed)
  section,

  /// `- text` or `* text`  — bullet list item
  bullet,

  /// `-- comment`  — private note (visible in edit mode only)
  comment,

  /// Blank line (separator)
  blank,

  /// Regular paragraph (may contain inline chips)
  paragraph,
}

// ── Line segments ─────────────────────────────────────────────────────────────

/// A segment within a paragraph line — either plain text or a CookLang token.
sealed class LineSegment {
  const LineSegment();
}

/// Plain text portion (may contain Markdown bold/italic markers).
class TextSegment extends LineSegment {
  final String text;
  const TextSegment(this.text);
}

/// `@name{qty%unit}` — ingredient chip.
class IngredientSegment extends LineSegment {
  final String name;
  final String qty;
  final String unit;
  final String raw; // full original token
  const IngredientSegment({
    required this.name,
    required this.qty,
    required this.unit,
    required this.raw,
  });

  /// Rebuild the CookLang raw token from edited fields.
  static String buildRaw(String name, String qty, String unit) {
    if (qty.isNotEmpty || unit.isNotEmpty) {
      return '@$name{$qty%$unit}';
    }
    return '@$name';
  }

  IngredientSegment copyWith({String? name, String? qty, String? unit}) {
    final n = name ?? this.name;
    final q = qty ?? this.qty;
    final u = unit ?? this.unit;
    return IngredientSegment(name: n, qty: q, unit: u, raw: buildRaw(n, q, u));
  }
}

/// `#name{}` — utensil chip.
class UtensilSegment extends LineSegment {
  final String name;
  final String raw;
  const UtensilSegment({required this.name, required this.raw});

  static String buildRaw(String name) {
    if (name.contains(' ')) return '#$name{}';
    return '#$name';
  }

  UtensilSegment copyWith({String? name}) {
    final n = name ?? this.name;
    return UtensilSegment(name: n, raw: buildRaw(n));
  }
}

/// `~{qty%unit}` or `~name{qty%unit}` — timer chip.
class TimerSegment extends LineSegment {
  final String name; // may be empty
  final String qty;
  final String unit;
  final String raw;
  const TimerSegment({
    required this.name,
    required this.qty,
    required this.unit,
    required this.raw,
  });

  static String buildRaw(String name, String qty, String unit) {
    return name.isNotEmpty ? '~$name{$qty%$unit}' : '~{$qty%$unit}';
  }

  TimerSegment copyWith({String? name, String? qty, String? unit}) {
    final n = name ?? this.name;
    final q = qty ?? this.qty;
    final u = unit ?? this.unit;
    return TimerSegment(name: n, qty: q, unit: u, raw: buildRaw(n, q, u));
  }
}

// ── EditorBlock ───────────────────────────────────────────────────────────────

/// One logical block/line in the visual editor.
class EditorBlock {
  final BlockType type;

  /// The raw CookLang line (source-of-truth fragment).
  final String rawLine;

  // ── Metadata fields (only for [BlockType.metadata]) ──────────────────────
  final String? metaKey;
  final String? metaValue;

  // ── Display fields (non-metadata blocks) ─────────────────────────────────
  final List<LineSegment>? segments;

  // ── For section / bullet / comment ───────────────────────────────────────
  /// Plain text content of the block (without the marker).
  final String? plainText;

  const EditorBlock._({
    required this.type,
    required this.rawLine,
    this.metaKey,
    this.metaValue,
    this.segments,
    this.plainText,
  });

  // ── Named constructors ────────────────────────────────────────────────────

  factory EditorBlock.metadata(String rawLine, String key, String value) =>
      EditorBlock._(
        type: BlockType.metadata,
        rawLine: rawLine,
        metaKey: key,
        metaValue: value,
      );

  factory EditorBlock.blank() =>
      const EditorBlock._(type: BlockType.blank, rawLine: '');

  factory EditorBlock.section(String rawLine, String text) =>
      EditorBlock._(type: BlockType.section, rawLine: rawLine, plainText: text);

  factory EditorBlock.bullet(
    String rawLine,
    String text,
    List<LineSegment> segments,
  ) => EditorBlock._(
    type: BlockType.bullet,
    rawLine: rawLine,
    plainText: text,
    segments: segments,
  );

  factory EditorBlock.comment(String rawLine, String text) =>
      EditorBlock._(type: BlockType.comment, rawLine: rawLine, plainText: text);

  factory EditorBlock.paragraph(String rawLine, List<LineSegment> segments) =>
      EditorBlock._(
        type: BlockType.paragraph,
        rawLine: rawLine,
        segments: segments,
      );

  // ── Rebuild rawLine from edited data ─────────────────────────────────────

  /// Reconstruct the raw CookLang line from the current metadata fields.
  EditorBlock withMeta(String key, String value) {
    final newRaw = '>> $key: $value';
    return EditorBlock.metadata(newRaw, key, value);
  }

  /// Reconstruct the raw line from edited segments list.
  EditorBlock withSegments(List<LineSegment> segs) {
    final raw = _segmentsToRaw(segs);
    return EditorBlock._(
      type: type,
      rawLine: type == BlockType.bullet ? '- $raw' : raw,
      segments: segs,
      plainText: segs.map((s) => s is TextSegment ? s.text : '').join(),
    );
  }

  /// Rebuild the raw line from plain text (for section / comment).
  EditorBlock withPlainText(String text) {
    late final String newRaw;
    switch (type) {
      case BlockType.section:
        newRaw = '## $text';
      case BlockType.comment:
        newRaw = '-- $text';
      case BlockType.bullet:
        newRaw = '- $text';
      default:
        newRaw = text;
    }
    return EditorBlock._(
      type: type,
      rawLine: newRaw,
      plainText: text,
      segments: segments,
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

String _segmentsToRaw(List<LineSegment> segs) => segs
    .map(
      (s) => switch (s) {
        TextSegment(:final text) => text,
        IngredientSegment(:final raw) => raw,
        UtensilSegment(:final raw) => raw,
        TimerSegment(:final raw) => raw,
      },
    )
    .join();

// ── Parser ─────────────────────────────────────────────────────────────────────

/// The main ingredient / utensil / timer inline regex.
/// Captures in order: ingredient, utensil, timer.
final _reInline = RegExp(
  r'(@[^{@#~\n,;.!?()\[\]]+(?:\{[^}]*\})?)' // ingredient
  r'|(#(?!\s)[^{@#~\n,;.!?()\[\]]+(?:\{[^}]*\})?)' // utensil (# NOT followed by space)
  r'|(~[^{@#~\n]*\{[^}]*\})', // timer
);

/// Parse a single line of CookLang source into an [EditorBlock].
EditorBlock parseLine(String line) {
  // ── Metadata: >> key: value ──────────────────────────────────────────────
  if (line.trimLeft().startsWith('>>')) {
    final content = line.substring(line.indexOf('>>') + 2);
    final colonIdx = content.indexOf(':');
    if (colonIdx > 0) {
      final key = content.substring(0, colonIdx).trim();
      final value = content.substring(colonIdx + 1).trim();
      return EditorBlock.metadata(line, key, value);
    }
    return EditorBlock.metadata(line, '', line);
  }

  // ── Comment: -- text ────────────────────────────────────────────────────
  if (line.trimLeft().startsWith('--')) {
    final text = line.substring(line.indexOf('--') + 2).trim();
    return EditorBlock.comment(line, text);
  }

  // ── Section: ## text ─────────────────────────────────────────────────────
  if (line.trimLeft().startsWith('## ')) {
    final text = line.substring(line.indexOf('## ') + 3).trim();
    return EditorBlock.section(line, text);
  }

  // ── Blank line ────────────────────────────────────────────────────────────
  if (line.trim().isEmpty) {
    return EditorBlock.blank();
  }

  // ── Bullet: "- text" or "* text" ─────────────────────────────────────────
  final trimmed = line.trimLeft();
  if ((trimmed.startsWith('- ') || trimmed.startsWith('* ')) &&
      trimmed.length > 2) {
    final text = trimmed.substring(2);
    final segs = _parseInlineSegments(text);
    return EditorBlock.bullet(line, text, segs);
  }

  // ── Paragraph ─────────────────────────────────────────────────────────────
  return EditorBlock.paragraph(line, _parseInlineSegments(line));
}

/// Parse all CookLang source lines into a list of [EditorBlock]s.
List<EditorBlock> parseCooklangBlocks(String source) {
  if (source.isEmpty) return [];
  return source.split('\n').map(parseLine).toList();
}

/// Reconstruct the full CookLang source from a list of [EditorBlock]s.
String blocksToSource(List<EditorBlock> blocks) =>
    blocks.map((b) => b.rawLine).join('\n');

/// Parse a paragraph text into a list of [LineSegment]s.
List<LineSegment> _parseInlineSegments(String text) {
  final segments = <LineSegment>[];
  int cursor = 0;

  for (final m in _reInline.allMatches(text)) {
    if (m.start > cursor) {
      segments.add(TextSegment(text.substring(cursor, m.start)));
    }

    if (m.group(1) != null) {
      // Ingredient
      segments.add(_parseIngredient(m.group(1)!));
    } else if (m.group(2) != null) {
      // Utensil
      segments.add(_parseUtensil(m.group(2)!));
    } else if (m.group(3) != null) {
      // Timer
      segments.add(_parseTimer(m.group(3)!));
    }

    cursor = m.end;
  }

  if (cursor < text.length) {
    segments.add(TextSegment(text.substring(cursor)));
  }

  if (segments.isEmpty) segments.add(TextSegment(text));
  return segments;
}

IngredientSegment _parseIngredient(String raw) {
  final braceIdx = raw.indexOf('{');
  if (braceIdx < 0) {
    return IngredientSegment(
      name: raw.substring(1).trim(),
      qty: '',
      unit: '',
      raw: raw,
    );
  }
  final name = raw.substring(1, braceIdx).trim();
  final inner = raw.substring(braceIdx + 1, raw.length - 1).trim();
  final pctIdx = inner.indexOf('%');
  final qty = pctIdx >= 0 ? inner.substring(0, pctIdx).trim() : inner;
  final unit = pctIdx >= 0 ? inner.substring(pctIdx + 1).trim() : '';
  return IngredientSegment(name: name, qty: qty, unit: unit, raw: raw);
}

UtensilSegment _parseUtensil(String raw) {
  final braceIdx = raw.indexOf('{');
  final name = braceIdx >= 0
      ? raw.substring(1, braceIdx).trim()
      : raw.substring(1).trim();
  return UtensilSegment(name: name, raw: raw);
}

TimerSegment _parseTimer(String raw) {
  final braceIdx = raw.indexOf('{');
  final name = braceIdx > 1 ? raw.substring(1, braceIdx).trim() : '';
  final inner = raw.substring(braceIdx + 1, raw.length - 1).trim();
  final pctIdx = inner.indexOf('%');
  final qty = pctIdx >= 0 ? inner.substring(0, pctIdx).trim() : inner;
  final unit = pctIdx >= 0 ? inner.substring(pctIdx + 1).trim() : '';
  return TimerSegment(name: name, qty: qty, unit: unit, raw: raw);
}
