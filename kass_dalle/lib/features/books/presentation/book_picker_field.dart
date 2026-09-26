import 'package:flutter/material.dart';

import '../domain/book.dart';
import '../domain/book_title_match.dart';

/// Valeur de l'entrée « aucun livre ». `DropdownMenu` rend `null` quand on
/// valide sans ligne retenue : `null` ne peut donc pas désigner une entrée.
const _kNoBook = '';

/// Choix d'un livre par saisie : on tape des lettres, la liste se réduit aux
/// livres dont le titre les contient.
///
/// [books] arrive dans l'ordre voulu — celui de la bibliothèque de
/// l'utilisateur — et le champ ne le change pas.
///
/// Le livre choisi ne change que sur une ligne retenue (touche, clic ou
/// Entrée). Un texte tapé sans choix est remplacé par le titre du livre actuel
/// quand le champ perd le focus : ce qui est affiché reste ce qui sera
/// enregistré.
class BookPickerField extends StatefulWidget {
  final List<Book> books;
  final String? selectedBookId;
  final void Function(String? id, String? titre) onChanged;
  final String label;
  final String? helperText;
  final bool enabled;

  /// Libellé d'une entrée « aucun livre », qui choisit `null`. Absente quand ce
  /// libellé est `null`.
  final String? noneLabel;

  const BookPickerField({
    super.key,
    required this.books,
    required this.selectedBookId,
    required this.onChanged,
    this.label = 'Livre',
    this.helperText,
    this.enabled = true,
    this.noneLabel,
  });

  @override
  State<BookPickerField> createState() => _BookPickerFieldState();
}

class _BookPickerFieldState extends State<BookPickerField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// Livre retenu, tenu ici en plus du parent : le parent ne reçoit le nouveau
  /// choix qu'à son prochain rendu, alors que le champ doit déjà s'y référer.
  String? _selectedId;

  late List<DropdownMenuEntry<String>> _entries;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedBookId;
    _entries = _buildEntries();
    _setText(_labelOf(_selectedId));
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(BookPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Les entrées ne se refont que si la liste change : `DropdownMenu` remet
    // son filtre à zéro dès qu'il reçoit une autre liste, y compris à contenu
    // égal.
    if (!identical(oldWidget.books, widget.books) ||
        oldWidget.noneLabel != widget.noneLabel) {
      _entries = _buildEntries();
    }
    if (oldWidget.selectedBookId != widget.selectedBookId) {
      _selectedId = widget.selectedBookId;
    }
    if (!_focus.hasFocus) _restoreText();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  List<DropdownMenuEntry<String>> _buildEntries() => [
    if (widget.noneLabel != null)
      DropdownMenuEntry(value: _kNoBook, label: widget.noneLabel!),
    for (final book in widget.books)
      DropdownMenuEntry(value: book.id, label: book.titre),
  ];

  /// Texte du champ au repos : le titre du livre retenu, vide s'il est hors
  /// liste.
  String _labelOf(String? id) {
    if (id == null) return widget.noneLabel ?? '';
    for (final book in widget.books) {
      if (book.id == id) return book.titre;
    }
    return '';
  }

  void _setText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _restoreText() {
    final label = _labelOf(_selectedId);
    if (_controller.text != label) _setText(label);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) {
      _restoreText();
      return;
    }
    // Tout le texte est sélectionné à l'entrée dans le champ : la première
    // lettre tapée remplace le titre au lieu de s'y ajouter. Le geste qui a
    // donné le focus place le curseur, la sélection passe donc après lui.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focus.hasFocus) return;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  List<DropdownMenuEntry<String>> _filter(
    List<DropdownMenuEntry<String>> entries,
    String query,
  ) => entries.where((e) => bookTitleMatches(e.label, query)).toList();

  /// Ligne surlignée pour la saisie : celle qui l'écrit en entier, sinon la
  /// première qui la contient. Entrée retient la ligne surlignée.
  int? _search(List<DropdownMenuEntry<String>> entries, String query) {
    if (query.trim().isEmpty) return null;
    var index = entries.indexWhere((e) => bookTitleEquals(e.label, query));
    if (index == -1) {
      index = entries.indexWhere((e) => bookTitleMatches(e.label, query));
    }
    return index == -1 ? null : index;
  }

  void _onSelected(String? value) {
    // Entrée sans ligne surlignée : `DropdownMenu` rend `null`, rien à retenir.
    if (value == null) return;
    _pick(value == _kNoBook ? null : value);
  }

  void _pick(String? id) {
    _selectedId = id;
    // Le clavier se referme sur le choix, et le champ montre le livre retenu.
    _focus.unfocus();
    if (id == widget.selectedBookId) return;
    widget.onChanged(id, id == null ? null : _labelOf(id));
  }

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<String>(
      controller: _controller,
      focusNode: _focus,
      enabled: widget.enabled,
      expandedInsets: EdgeInsets.zero,
      menuHeight: 260,
      label: Text(widget.label),
      helperText: widget.helperText,
      leadingIcon: const Icon(Icons.menu_book_outlined),
      // Sans ce thème, le menu n'a pas l'aspect des autres champs du formulaire.
      inputDecorationTheme: Theme.of(context).inputDecorationTheme,
      initialSelection:
          _selectedId ?? (widget.noneLabel == null ? null : _kNoBook),
      enableFilter: true,
      filterCallback: _filter,
      searchCallback: _search,
      dropdownMenuEntries: _entries,
      onSelected: _onSelected,
    );
  }
}
