import 'package:flutter/material.dart';

/// Saisie du nombre de portions.
///
/// Extrait de `cooklang_preview.dart`, où il occupait 75 lignes au milieu d'une
/// classe de 1200 : un dialogue autonome, sans lien avec le rendu de la recette,
/// qui n'avait aucune raison d'y vivre. Isolé, il devient testable seul — ce
/// qu'il n'était pas.

/// Vérifie une saisie de portions et rend le message d'erreur, ou `null` si la
/// valeur convient.
///
/// Séparée de l'affichage pour que la règle se teste sans monter de widget :
/// c'est elle qui décide, le dialogue ne fait que la montrer.
///
/// [unit] nomme ce qu'on compte dans le message : « portions » sur la fiche
/// recette, « parts » dans le planning.
String? validatePortionsInput(
  String raw, {
  required int minPortions,
  required int maxPortions,
  String unit = 'portions',
}) {
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) return 'Saisis un nombre entier.';
  if (parsed < minPortions || parsed > maxPortions) {
    return 'Le nombre de $unit doit être entre $minPortions et $maxPortions.';
  }
  return null;
}

class PortionsInputDialog extends StatefulWidget {
  final int current;
  final int minPortions;
  final int maxPortions;
  final String title;
  final String unit;

  const PortionsInputDialog({
    super.key,
    required this.current,
    required this.minPortions,
    required this.maxPortions,
    this.title = 'Nombre de portions',
    this.unit = 'portions',
  });

  @override
  State<PortionsInputDialog> createState() => _PortionsInputDialogState();
}

class _PortionsInputDialogState extends State<PortionsInputDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: '${widget.current}',
  );
  String? _errorText;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validatePortionsInput(
      _ctrl.text,
      minPortions: widget.minPortions,
      maxPortions: widget.maxPortions,
      unit: widget.unit,
    );
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.of(context).pop(int.parse(_ctrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: InputDecoration(
          labelText:
              '${widget.unit[0].toUpperCase()}${widget.unit.substring(1)}',
          hintText: '${widget.minPortions} - ${widget.maxPortions}',
          errorText: _errorText,
          errorMaxLines: 3,
        ),
        // L'erreur s'efface à la frappe : la laisser affichée pendant que
        // l'utilisateur corrige donne l'impression que sa correction ne compte
        // pas.
        onChanged: (_) {
          if (_errorText != null) setState(() => _errorText = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
  }
}

/// Ouvre le dialogue et rend le nombre saisi, ou `null` si l'utilisateur annule.
Future<int?> showPortionsInputDialog(
  BuildContext context, {
  required int current,
  required int minPortions,
  required int maxPortions,
  String title = 'Nombre de portions',
  String unit = 'portions',
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => PortionsInputDialog(
      current: current,
      minPortions: minPortions,
      maxPortions: maxPortions,
      title: title,
      unit: unit,
    ),
  );
}
