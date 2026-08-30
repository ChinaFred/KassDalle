import 'ai_call.dart';
import 'log_entry.dart';
import 'log_treatment_label.dart';

// ─── Le regroupement à trois niveaux ─────────────────────────────────────────
//
// Niveau 1 : le SCAN — l'acte de l'utilisateur. Photographier une page de
//   livre déroule quatre traitements côté serveur : le contrôle du fichier,
//   le pipeline d'import, une détection d'illustrations par page, puis les
//   calculs qui suivent l'écriture de la recette. Chacun a son propre
//   `correlationId`, et l'écran en faisait quatre groupes sans lien — le coût
//   d'un scan se lisait sur quatre lignes qu'il fallait retrouver une à une.
//
// Niveau 2 : l'APPEL de modèle, avec son montant. Il vient de `ai_usage`, pas
//   des journaux : le montant n'existe qu'à un seul endroit. Les lignes qui
//   n'appartiennent à aucun appel — étapes du pipeline, erreurs — restent à ce
//   niveau, mêlées aux appels dans l'ordre du temps.
//
// Niveau 3 : les LIGNES de journal d'un appel — le prompt, la fin de l'appel,
//   le texte rendu. Elles étaient posées au même rang que celles du pipeline,
//   et un poste appelé quarante fois donnait cent vingt lignes indiscernables.

/// Un élément de niveau 2 : un appel, ou une ligne qui n'en relève pas.
sealed class ScanItem {
  DateTime? get at;
}

/// Un appel de modèle et les lignes de journal qui en parlent.
class CallItem extends ScanItem {
  CallItem({required this.callId, this.call, List<LogEntry>? entries})
    : entries = entries ?? [];

  final String callId;

  /// La ligne de consommation. `null` quand seules les lignes de journal sont
  /// là : l'appel est alors visible, mais son montant reste inconnu — ce qui
  /// vaut mieux que de l'afficher à zéro.
  final AiCall? call;

  final List<LogEntry> entries;

  @override
  DateTime? get at {
    final fromEntries = entries
        .map((e) => e.timestampDate)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    return fromEntries ?? call?.timestamp;
  }

  bool get hasError =>
      (call?.failed ?? false) || entries.any((e) => e.severity == 'ERROR');
}

/// Une ligne de journal qui n'appartient à aucun appel.
class EntryItem extends ScanItem {
  EntryItem(this.entry);
  final LogEntry entry;

  @override
  DateTime? get at => entry.timestampDate;
}

/// Un scan, ou un traitement isolé quand aucun scan ne le chapeaute.
class ScanGroup {
  ScanGroup({
    required this.key,
    required this.isScan,
    required this.items,
    required this.treatments,
    required this.roots,
    required this.features,
    required this.total,
    required this.hasError,
    required this.hasWarning,
    required this.lastAt,
    required this.correlationIds,
  });

  /// `scanId` quand il y en a un, `correlationId` sinon.
  final String key;

  /// Vrai quand ce groupe rassemble les traitements d'un scan.
  final bool isScan;

  final List<ScanItem> items;

  /// Libellés des traitements réunis, dans l'ordre où ils sont apparus.
  final List<String> treatments;

  /// Racines techniques de ces traitements — ce qui sert à nommer le scan.
  final Set<String> roots;

  /// Postes des appels — ils disent de quel scan il s'agit.
  final Set<String> features;

  final AiCostTotal total;
  final bool hasError;
  final bool hasWarning;
  final DateTime? lastAt;

  /// Les traitements réunis, pour le bouton « n'afficher que ce traitement »
  /// quand il n'y a pas de scan à isoler.
  final List<String> correlationIds;

  int get entryCount =>
      items.fold<int>(0, (n, i) => n + (i is CallItem ? i.entries.length : 1));

  int get callCount => items.whereType<CallItem>().length;

  String get label {
    if (isScan) {
      if (features.contains('book_cover')) return 'Scan d\'une couverture';
      if (features.contains('polish_markdown')) return 'Scan d\'un document';
      return 'Scan d\'une page de livre';
    }
    if (treatments.isNotEmpty) return treatments.first;
    return key.isEmpty ? 'Hors traitement' : key;
  }
}

/// Racine d'un `correlationId`, débarrassée de son horodatage — `null` quand
/// l'identifiant est opaque (UUID) et ne nomme donc rien.
String? correlationRoot(String correlationId) {
  if (correlationId.isEmpty) return null;
  final isUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(correlationId);
  if (isUuid) return null;
  final root = correlationId
      // Le suffixe de page d'une détection d'illustrations : `…_p1`, `…_p2`.
      // Sans lui, chaque page ouvrait un traitement au nom illisible.
      .replaceAll(RegExp(r'_p\d+$'), '')
      .replaceAll(RegExp(r'[-_]\d{10,}([-_][a-z0-9]+)?$'), '')
      .replaceAll(RegExp(r'[-_]+$'), '');
  return root.isEmpty ? null : root;
}

/// Regroupe entrées et appels par scan, puis par appel à l'intérieur.
///
/// Le rattachement se fait sur `scanId` quand il est là. Les journaux écrits
/// avant que ce champ existe n'en ont pas : on retombe alors sur le
/// `correlationId`, et le groupe ne couvre qu'un traitement. Une carte
/// `correlationId → scanId`, apprise des lignes qui portent les deux, rattrape
/// au passage les appels dont seule la corrélation est connue.
List<ScanGroup> groupLogsByScan(List<LogEntry> entries, List<AiCall> calls) {
  final scanByCorrelation = <String, String>{};
  void learn(String? scan, String? correlation) {
    if (scan == null || scan.isEmpty) return;
    if (correlation == null || correlation.isEmpty) return;
    scanByCorrelation.putIfAbsent(correlation, () => scan);
  }

  for (final e in entries) {
    learn(e.labels['scanId'], e.labels['correlationId']);
  }
  for (final c in calls) {
    learn(c.scanId, c.correlationId);
  }

  String keyOf(String? scan, String? correlation) {
    if (scan != null && scan.isNotEmpty) return scan;
    final corr = correlation ?? '';
    return scanByCorrelation[corr] ?? corr;
  }

  // L'ordre des groupes suit celui du flux : le plus récent d'abord.
  final order = <String>[];
  final entriesByKey = <String, List<LogEntry>>{};
  final scanKeys = <String>{};
  for (final e in entries) {
    final key = keyOf(e.labels['scanId'], e.labels['correlationId']);
    if (!entriesByKey.containsKey(key)) order.add(key);
    (entriesByKey[key] ??= []).add(e);
    final scan = e.labels['scanId'];
    if (scan != null && scan.isNotEmpty) scanKeys.add(scan);
  }

  final callsByKey = <String, List<AiCall>>{};
  for (final c in calls) {
    final key = keyOf(c.scanId, c.correlationId);
    // Un appel dont aucune ligne de journal n'est visible ouvre quand même son
    // groupe : son coût est réel, et un total amputé ne se voit pas.
    if (!entriesByKey.containsKey(key) && !callsByKey.containsKey(key)) {
      order.add(key);
    }
    (callsByKey[key] ??= []).add(c);
    final scan = c.scanId;
    if (scan != null && scan.isNotEmpty) scanKeys.add(scan);
  }

  final groups = <ScanGroup>[];
  for (final key in order) {
    final groupEntries = entriesByKey[key] ?? const <LogEntry>[];
    final groupCalls = callsByKey[key] ?? const <AiCall>[];

    // ── Niveau 2 ──────────────────────────────────────────────────────────
    final callItems = <String, CallItem>{};
    for (final c in groupCalls) {
      final id = c.callId ?? 'sans-journal:${callItems.length}';
      callItems[id] = CallItem(callId: id, call: c);
    }
    final loose = <EntryItem>[];
    for (final e in groupEntries.reversed) {
      final callId = e.labels['callId'];
      if (callId == null || callId.isEmpty) {
        loose.add(EntryItem(e));
        continue;
      }
      // Une ligne dont l'appel n'a pas été lu ouvre son propre appel : mieux
      // vaut un appel sans montant qu'une ligne perdue au milieu des étapes.
      final item = callItems.putIfAbsent(
        callId,
        () => CallItem(callId: callId),
      );
      item.entries.add(e);
    }

    final items = <ScanItem>[...callItems.values, ...loose];
    items.sort((a, b) {
      final x = a.at;
      final y = b.at;
      if (x == null || y == null) return 0;
      return x.compareTo(y);
    });

    // ── Ce que le groupe dit de lui-même ──────────────────────────────────
    final treatments = <String>[];
    final roots = <String>{};
    final correlationIds = <String>[];
    for (final e in groupEntries.reversed) {
      final corr = e.labels['correlationId'] ?? '';
      if (corr.isNotEmpty && !correlationIds.contains(corr)) {
        correlationIds.add(corr);
      }
      final root = correlationRoot(corr);
      if (root == null || !roots.add(root)) continue;
      treatments.add(logTreatmentName(root).display);
    }

    groups.add(
      ScanGroup(
        key: key,
        isScan: scanKeys.contains(key),
        items: items,
        treatments: treatments,
        roots: roots,
        features: groupCalls.map((c) => c.feature).toSet(),
        total: AiCostTotal.of(groupCalls),
        hasError:
            groupEntries.any((e) => e.severity == 'ERROR') ||
            groupCalls.any((c) => c.failed),
        hasWarning: groupEntries.any((e) => e.severity == 'WARNING'),
        lastAt: groupEntries.isEmpty
            ? groupCalls.first.timestamp
            : groupEntries.first.timestampDate,
        correlationIds: correlationIds,
      ),
    );
  }
  return groups;
}

// ─── Montants ────────────────────────────────────────────────────────────────

/// Rend un montant dans la monnaie du compte, en dollars faute de taux.
///
/// Sans taux, on n'invente pas : afficher des euros calculés avec une constante
/// du code produirait un montant périmé présenté comme exact.
String formatCost(double? costUsd, double? usdToEur) {
  if (costUsd == null) return 'sans montant';
  if (usdToEur != null && usdToEur > 0) {
    return '${_amount(costUsd * usdToEur)} €';
  }
  return '${_amount(costUsd)} \$';
}

String _amount(double value) {
  final text = value >= 1
      ? value.toStringAsFixed(2)
      : _trimZeros(value.toStringAsFixed(6));
  return text.replaceAll('.', ',');
}

/// Enlève les zéros de fin, sans jamais descendre sous deux décimales.
///
/// Six décimales fixes noieraient « 0,90 € » dans des zéros ; deux décimales
/// fixes afficheraient « 0,00 € » pour un appel à quatre millièmes de dollar,
/// et un montant nul est ce qu'on ne veut jamais montrer à la place d'un
/// montant réel.
String _trimZeros(String fixed) {
  var text = fixed;
  while (text.endsWith('0') && text.split('.')[1].length > 2) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// Le total d'un groupe, et ce qu'il ne couvre pas.
///
/// Le nombre d'appels non chiffrés voyage avec le total : 0,03 $ sur douze
/// appels dont quatre sans prix n'est pas une dépense, c'est un minimum.
String formatTotal(AiCostTotal total, double? usdToEur) {
  if (total.isEmpty) return 'aucun appel d\'IA';
  final manquants = total.unpricedCalls > 0
      ? ' · ${total.unpricedCalls} sans montant'
      : '';
  if (total.unpricedCalls == total.calls) {
    return 'sans montant · ${total.calls} appel(s)';
  }
  return '${formatCost(total.costUsd, usdToEur)} · '
      '${total.calls} appel(s)$manquants';
}

/// Fusionne deux listes d'appels sans compter deux fois le même.
///
/// L'identité d'un appel est son `callId`. Les appels enregistrés avant que ce
/// champ existe n'en ont pas : on les distingue alors par leur traitement, leur
/// poste, leur modèle et leur horodatage.
List<AiCall> mergeAiCalls(List<AiCall> existing, List<AiCall> incoming) {
  String key(AiCall c) =>
      c.callId ??
      '${c.correlationId}|${c.feature}|${c.model}|${c.timestamp?.toIso8601String()}';
  final byKey = <String, AiCall>{for (final c in existing) key(c): c};
  for (final c in incoming) {
    byKey.putIfAbsent(key(c), () => c);
  }
  return byKey.values.toList(growable: false);
}
