/// Data model for the WYSIWYG visual editor.
///
/// A CookLang recipe is parsed into a flat list of [EditorBlock]s.
/// Each block corresponds to one logical "line" in the source text and
/// carries both its raw representation (the source-of-truth string) and
/// its semantic content (segments for display, key/value for metadata).
library;

// ── Enums ─────────────────────────────────────────────────────────────────────

/// Position d'un bloc image dans le texte.
enum ImagePosition { left, right, after }

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

  /// `![left](url)`, `![right](url)`, `![after](url)` — bloc image
  image,

  /// `+ text` — continuation visuelle de l'étape précédente (même numéro)
  continuation,
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
    if (qty.isNotEmpty || unit.isNotEmpty) return '@$name{$qty%$unit}';
    return '@$name{}';
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

  static String buildRaw(String name) => '#$name{}';

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

  // ── For image blocks ─────────────────────────────────────────────────────
  final String? imageUrl;
  final ImagePosition? imagePosition;

  /// Largeur en % de la ligne (null = valeur par défaut selon la position).
  final int? imageWidthPercent;

  const EditorBlock._({
    required this.type,
    required this.rawLine,
    this.metaKey,
    this.metaValue,
    this.segments,
    this.plainText,
    this.imageUrl,
    this.imagePosition,
    this.imageWidthPercent,
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

  factory EditorBlock.comment(
    String rawLine,
    String text, [
    List<LineSegment>? segs,
  ]) => EditorBlock._(
    type: BlockType.comment,
    rawLine: rawLine,
    plainText: text,
    segments: segs,
  );

  factory EditorBlock.paragraph(String rawLine, List<LineSegment> segments) =>
      EditorBlock._(
        type: BlockType.paragraph,
        rawLine: rawLine,
        segments: segments,
      );

  factory EditorBlock.continuation(
    String rawLine,
    String text,
    List<LineSegment> segments,
  ) => EditorBlock._(
    type: BlockType.continuation,
    rawLine: rawLine,
    plainText: text,
    segments: segments,
  );

  factory EditorBlock.image(
    String rawLine,
    String url,
    ImagePosition position, [
    int? widthPercent,
  ]) => EditorBlock._(
    type: BlockType.image,
    rawLine: rawLine,
    imageUrl: url,
    imagePosition: position,
    imageWidthPercent: widthPercent,
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
    final String newRawLine;
    if (type == BlockType.bullet) {
      newRawLine = '- $raw';
    } else if (type == BlockType.continuation) {
      newRawLine = '+ $raw';
    } else if (type == BlockType.comment) {
      // Preserve > vs -- prefix for conseil/comment blocks
      if (rawLine.trimLeft().startsWith('>')) {
        newRawLine = '> $raw';
      } else {
        newRawLine = '-- $raw';
      }
    } else {
      newRawLine = raw;
    }
    return EditorBlock._(
      type: type,
      rawLine: newRawLine,
      segments: segs,
      plainText: segs.map((s) => s is TextSegment ? s.text : '').join(),
    );
  }

  /// Rebuild the raw line from plain text (for section / comment).
  EditorBlock withPlainText(String text) {
    late final String newRaw;
    switch (type) {
      case BlockType.section:
        // Preserve original format if possible, otherwise use == ==
        if (rawLine.trim().startsWith('##')) {
          newRaw = '## $text';
        } else {
          newRaw = '== $text ==';
        }
      case BlockType.comment:
        // Preserve > vs -- format
        if (rawLine.trimLeft().startsWith('>')) {
          newRaw = '> $text';
        } else {
          newRaw = '-- $text';
        }
      case BlockType.bullet:
        newRaw = '- $text';
      case BlockType.continuation:
        newRaw = '+ $text';
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

  /// Rebuild le raw depuis une nouvelle position (uniquement pour BlockType.image).
  EditorBlock withImagePosition(ImagePosition pos) {
    final widthPart = imageWidthPercent != null ? '|$imageWidthPercent' : '';
    final newRaw = '![${pos.name}$widthPart]($imageUrl)';
    return EditorBlock.image(newRaw, imageUrl!, pos, imageWidthPercent);
  }

  /// Rebuild le raw avec un nouveau % de largeur (uniquement pour BlockType.image).
  EditorBlock withImageWidth(int? widthPercent) {
    final widthPart = widthPercent != null ? '|$widthPercent' : '';
    final newRaw = '![${imagePosition!.name}$widthPart]($imageUrl)';
    return EditorBlock.image(newRaw, imageUrl!, imagePosition!, widthPercent);
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
  // ingredient: with braces (spaces allowed in name), or single word without braces
  r'(@(?:[^{@#~\n,;.!?()[\]]+\{[^}]*\}|[^{@#~\n\s,;.!?()[\]]+))'
  // utensil (# not followed by space): same rule as ingredient
  r'|(#(?!\s)(?:[^{@#~\n,;.!?()[\]]+\{[^}]*\}|[^{@#~\n\s,;.!?()[\]]+))'
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

  // ── Note/conseil: > text ─────────────────────────────────────────────────
  if (line.trimLeft().startsWith('> ') || line.trim() == '>') {
    final idx = line.indexOf('>');
    final text = line.substring(idx + 1).trim();
    return EditorBlock.comment(line, text, _parseInlineSegments(text));
  }

  // ── Section: == Title == or ## Title ─────────────────────────────────────
  final sectionMatch = RegExp(r'^==\s*(.+?)\s*==$').firstMatch(line.trim());
  if (sectionMatch != null) {
    return EditorBlock.section(line, sectionMatch.group(1)!.trim());
  }
  if (line.trimLeft().startsWith('## ')) {
    final text = line.substring(line.indexOf('## ') + 3).trim();
    return EditorBlock.section(line, text);
  }
  // Treat '== ...' without closing '==' as section too (e.g. from toolbar insertion)
  if (line.trimLeft().startsWith('== ')) {
    final text = line.substring(line.indexOf('== ') + 3).trim();
    return EditorBlock.section(line, text);
  }

  // ── Image: ![position|width](url) ────────────────────────────────────────────
  final imgMatch = RegExp(
    r'^!\[([^\]]*)\]\(([^)]+)\)$',
  ).firstMatch(line.trim());
  if (imgMatch != null) {
    final posAndWidth = imgMatch.group(1)!.trim().toLowerCase();
    final url = imgMatch.group(2)!.trim();
    final pipeIdx = posAndWidth.indexOf('|');
    final posStr = pipeIdx >= 0
        ? posAndWidth.substring(0, pipeIdx).trim()
        : posAndWidth;
    final widthStr = pipeIdx >= 0
        ? posAndWidth.substring(pipeIdx + 1).trim().replaceAll('%', '')
        : null;
    final widthPercent = widthStr != null ? int.tryParse(widthStr) : null;
    final pos = ImagePosition.values.firstWhere(
      (p) => p.name == posStr,
      orElse: () => ImagePosition.after,
    );
    return EditorBlock.image(line, url, pos, widthPercent);
  }

  // ── Blank line ────────────────────────────────────────────────────────────
  if (line.trim().isEmpty) {
    return EditorBlock.blank();
  }

  final trimmed = line.trimLeft();

  // ── Continuation: + text ──────────────────────────────────────────────────
  if (trimmed.startsWith('+ ') && trimmed.length > 2) {
    final text = trimmed.substring(2);
    return EditorBlock.continuation(line, text, _parseInlineSegments(text));
  }

  // ── Bullet: "- text" or "* text" ─────────────────────────────────────────
  if ((trimmed.startsWith('- ') || trimmed.startsWith('* ')) &&
      trimmed.length >= 2) {
    final text = trimmed.length > 2 ? trimmed.substring(2) : '';
    final segs = text.isEmpty ? <LineSegment>[] : _parseInlineSegments(text);
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
