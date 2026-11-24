import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import '../models/reader_theme_settings.dart';
import '../services/translation_queue.dart';
import '../services/translator_service.dart';
import '../widgets/book_page_view.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  final TranslationQueueController queueController;
  final TranslatorService translatorService;
  final String targetLanguage;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.queueController,
    required this.translatorService,
    required this.targetLanguage,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  List<Chapter> _chapters = [];
  List<ParagraphItem> _paragraphs = [];
  int _currentChapterIndex = 0;
  int _currentPageInChapter = 0;
  bool _loadingChapter = true;
  bool _showControls = true;
  String _scrollSelectedText = '';

  ReaderAppearance _appearance = const ReaderAppearance();

  TranslateMode _selectedMode = TranslateMode.nextChapters;
  int _chaptersAhead = 3;
  StreamSubscription<TranslationProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _initData();
    _progressSub = widget.queueController.progressStream.listen((p) {
      if (p.activeBookId == widget.book.id) {
        _refreshCurrentChapter(silent: true);
        _refreshChaptersList();
      }
    });
  }

  Future<void> _initData() async {
    final savedAppearance = await ReaderAppearance.load();
    if (mounted) {
      setState(() => _appearance = savedAppearance);
    }
    await _refreshChaptersList();
    await _loadChapter(0);
  }

  void _updateAppearance(ReaderAppearance next) {
    setState(() => _appearance = next);
    next.save();
  }

  Future<void> _refreshChaptersList() async {
    final chs = await BookDatabase.instance.getChapters(widget.book.id);
    if (!mounted) return;
    setState(() => _chapters = chs);
  }

  Future<void> _loadChapter(int index, {int startPage = 0}) async {
    if (_chapters.isEmpty) return;
    final safeIdx = index.clamp(0, _chapters.length - 1);
    setState(() {
      _currentChapterIndex = safeIdx;
      _currentPageInChapter = startPage;
      _loadingChapter = true;
    });
    final items = await BookDatabase.instance.getChapterParagraphs(
      widget.book.id,
      safeIdx,
    );
    if (!mounted) return;
    setState(() {
      _paragraphs = items;
      _loadingChapter = false;
    });
  }

  Future<void> _refreshCurrentChapter({bool silent = false}) async {
    if (_chapters.isEmpty) return;
    if (!silent) setState(() => _loadingChapter = true);
    final items = await BookDatabase.instance.getChapterParagraphs(
      widget.book.id,
      _currentChapterIndex,
    );
    if (!mounted) return;
    setState(() {
      _paragraphs = items;
      _loadingChapter = false;
    });
  }

  void _startQueue({TranslateMode? overrideMode, int? overrideAhead}) {
    widget.queueController.startTranslation(
      bookId: widget.book.id,
      bookTitle: widget.book.title,
      currentReadingChapter: _currentChapterIndex,
      mode: overrideMode ?? _selectedMode,
      chaptersAhead: overrideAhead ?? _chaptersAhead,
      targetLanguage: widget.targetLanguage,
    );
  }

  Future<void> _saveToDictionaryDirectly(String selectedText) async {
    final clean = selectedText.trim();
    if (clean.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('Переводим и сохраняем «$clean»...'),
      ),
    );

    try {
      final translated = await widget.translatorService.translateSelection(
        selectedText: clean,
        targetLanguage: widget.targetLanguage,
      );

      await BookDatabase.instance.addDictionaryEntry(
        DictionaryEntry(
          sourceText: clean,
          translatedText: translated,
          bookTitle: widget.book.title,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('В словаре: $clean — $translated'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось добавить в словарь: $e')),
      );
    }
  }

  void _showSelectionTranslationSheet(String selectedText) {
    final palette = ReaderPalette.of(_appearance.colorTheme);
    bool saved = false;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.translate, color: palette.accent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Быстрый перевод фрагмента',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: palette.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.background,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      selectedText,
                      style: TextStyle(
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                        color: palette.secondaryText,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FutureBuilder<String>(
                    future: widget.translatorService.translateSelection(
                      selectedText: selectedText,
                      targetLanguage: widget.targetLanguage,
                    ),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Row(
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: palette.accent,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Переводим...',
                              style: TextStyle(color: palette.text),
                            ),
                          ],
                        );
                      }
                      if (snapshot.hasError) {
                        return Text(
                          'Не удалось перевести: ${snapshot.error}',
                          style: const TextStyle(color: Colors.redAccent),
                        );
                      }
                      final resultText = snapshot.data ?? '';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SelectableText(
                            resultText,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                              color: palette.text,
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: saved
                                ? null
                                : () async {
                                    await BookDatabase.instance
                                        .addDictionaryEntry(
                                      DictionaryEntry(
                                        sourceText: selectedText,
                                        translatedText: resultText,
                                        bookTitle: widget.book.title,
                                        createdAt: DateTime.now()
                                            .millisecondsSinceEpoch,
                                      ),
                                    );
                                    setModalState(() => saved = true);
                                  },
                            icon: Icon(
                              saved ? Icons.check : Icons.bookmark_add_outlined,
                              color: palette.accent,
                            ),
                            label: Text(
                              saved
                                  ? 'Сохранено в словарь'
                                  : 'Сохранить в словарь',
                              style: TextStyle(color: palette.text),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _statusLabel(ChapterStatus status) {
    switch (status) {
      case ChapterStatus.completed:
        return 'Готова';
      case ChapterStatus.inProgress:
        return 'Переводится';
      case ChapterStatus.partial:
        return 'Частично';
      case ChapterStatus.pending:
        return 'Не переведена';
    }
  }

  String _formatWaitTime(int totalSeconds) {
    if (totalSeconds < 60) {
      return '$totalSeconds сек';
    }
    final mins = totalSeconds ~/ 60;
    final secs = totalSeconds % 60;
    return secs > 0 ? '$mins мин $secs сек' : '$mins мин';
  }

  void _openAppearanceSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final palette = ReaderPalette.of(_appearance.colorTheme);

            void apply(ReaderAppearance next) {
              _updateAppearance(next);
              setModalState(() {});
            }

            return Container(
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: palette.secondaryText.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Оформление и режим чтения',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 14),

                  Text(
                    'Отображение текста',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _modeChip(
                        palette: palette,
                        icon: Icons.translate,
                        label: 'Перевод',
                        selected: _appearance.textDisplay ==
                            ReaderTextDisplay.translationOnly,
                        onTap: () => apply(
                          _appearance.copyWith(
                            textDisplay: ReaderTextDisplay.translationOnly,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _modeChip(
                        palette: palette,
                        icon: Icons.vertical_split,
                        label: 'Билингва',
                        selected: _appearance.textDisplay ==
                            ReaderTextDisplay.bilingual,
                        onTap: () => apply(
                          _appearance.copyWith(
                            textDisplay: ReaderTextDisplay.bilingual,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _modeChip(
                        palette: palette,
                        icon: Icons.menu_book,
                        label: 'Оригинал',
                        selected: _appearance.textDisplay ==
                            ReaderTextDisplay.originalOnly,
                        onTap: () => apply(
                          _appearance.copyWith(
                            textDisplay: ReaderTextDisplay.originalOnly,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Text(
                    'Цветовая схема',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: ReaderColorTheme.values.map((t) {
                      final itemPalette = ReaderPalette.of(t);
                      final selected = _appearance.colorTheme == t;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () =>
                                apply(_appearance.copyWith(colorTheme: t)),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: itemPalette.background,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: selected
                                      ? palette.accent
                                      : palette.secondaryText.withOpacity(0.3),
                                  width: selected ? 2.2 : 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    'Аа',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: itemPalette.text,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    itemPalette.name,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: itemPalette.secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  Text(
                    'Режим листания',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _modeChip(
                        palette: palette,
                        icon: Icons.swap_vert,
                        label: 'Прокрутка',
                        selected:
                            _appearance.pageMode == ReaderPageMode.scroll,
                        onTap: () => apply(
                          _appearance.copyWith(pageMode: ReaderPageMode.scroll),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _modeChip(
                        palette: palette,
                        icon: Icons.swipe,
                        label: 'Листание',
                        selected:
                            _appearance.pageMode == ReaderPageMode.pageSlide,
                        onTap: () => apply(
                          _appearance.copyWith(
                            pageMode: ReaderPageMode.pageSlide,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _modeChip(
                        palette: palette,
                        icon: Icons.auto_stories,
                        label: 'Книга 3D',
                        selected:
                            _appearance.pageMode == ReaderPageMode.pageCurl,
                        onTap: () => apply(
                          _appearance.copyWith(
                            pageMode: ReaderPageMode.pageCurl,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Размер шрифта',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.secondaryText,
                        ),
                      ),
                      Text(
                        '${_appearance.fontSize.toInt()} pt',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: palette.text,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: _appearance.fontSize > 13
                            ? () => apply(
                                  _appearance.copyWith(
                                    fontSize: _appearance.fontSize - 1,
                                  ),
                                )
                            : null,
                        icon: Icon(Icons.text_decrease, color: palette.text),
                      ),
                      Expanded(
                        child: Slider(
                          min: 13,
                          max: 28,
                          divisions: 15,
                          activeColor: palette.accent,
                          value: _appearance.fontSize,
                          onChanged: (v) =>
                              apply(_appearance.copyWith(fontSize: v)),
                        ),
                      ),
                      IconButton(
                        onPressed: _appearance.fontSize < 28
                            ? () => apply(
                                  _appearance.copyWith(
                                    fontSize: _appearance.fontSize + 1,
                                  ),
                                )
                            : null,
                        icon: Icon(Icons.text_increase, color: palette.text),
                      ),
                    ],
                  ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Межстрочный интервал',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.secondaryText,
                        ),
                      ),
                      Text(
                        _appearance.lineHeight.toStringAsFixed(2),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: palette.text,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    min: 1.2,
                    max: 2.0,
                    divisions: 8,
                    activeColor: palette.accent,
                    value: _appearance.lineHeight,
                    onChanged: (v) =>
                        apply(_appearance.copyWith(lineHeight: v)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _modeChip({
    required ReaderPalette palette,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: selected
                ? palette.accent.withOpacity(0.18)
                : palette.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? palette.accent
                  : palette.secondaryText.withOpacity(0.25),
              width: selected ? 1.8 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? palette.accent : palette.text,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? palette.accent : palette.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(_appearance.colorTheme);
    final currentChapterTitle = _chapters.isNotEmpty
        ? _chapters[_currentChapterIndex].title
        : 'Глава 1';

    return Theme(
      data: ThemeData(
        brightness: palette.brightness,
        scaffoldBackgroundColor: palette.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: palette.brightness,
        ),
        useMaterial3: true,
      ),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.surface,
          foregroundColor: palette.text,
          elevation: 0,
          title: Text(
            widget.book.title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.text, fontSize: 17),
          ),
          actions: [
            IconButton(
              icon: Icon(
                _showControls ? Icons.fullscreen : Icons.fullscreen_exit,
                color: palette.text,
              ),
              tooltip: _showControls ? 'Скрыть панель' : 'Показать панель',
              onPressed: () => setState(() => _showControls = !_showControls),
            ),
            IconButton(
              icon: Icon(Icons.text_fields, color: palette.text),
              tooltip: 'Шрифт и тема чтения',
              onPressed: _openAppearanceSheet,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_showControls) ...[
              StreamBuilder<TranslationProgress>(
                stream: widget.queueController.progressStream,
                initialData: widget.queueController.currentProgress,
                builder: (context, snapshot) {
                  final p = snapshot.data ?? const TranslationProgress();
                  final isThisBook = p.activeBookId.isEmpty ||
                      p.activeBookId == widget.book.id;
                  final modelBadge =
                      p.activeModel.isNotEmpty ? ' • ${p.activeModel}' : '';

                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    color: palette.surface,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButton<TranslateMode>(
                                isExpanded: true,
                                dropdownColor: palette.surface,
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 14,
                                ),
                                value: _selectedMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: TranslateMode.nextChapters,
                                    child: Text('Перевести +N глав вперёд'),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslateMode.fullBook,
                                    child: Text('Перевести всю книгу'),
                                  ),
                                ],
                                onChanged: p.isRunning
                                    ? null
                                    : (val) {
                                        if (val != null) {
                                          setState(() => _selectedMode = val);
                                        }
                                      },
                              ),
                            ),
                            if (_selectedMode == TranslateMode.nextChapters) ...[
                              const SizedBox(width: 8),
                              DropdownButton<int>(
                                dropdownColor: palette.surface,
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 14,
                                ),
                                value: _chaptersAhead,
                                items: const [1, 2, 3, 5, 10]
                                    .map(
                                      (n) => DropdownMenuItem(
                                        value: n,
                                        child: Text('+$n'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: p.isRunning
                                    ? null
                                    : (val) {
                                        if (val != null) {
                                          setState(() => _chaptersAhead = val);
                                        }
                                      },
                              ),
                            ],
                            const SizedBox(width: 8),
                            p.isRunning
                                ? FilledButton.tonalIcon(
                                    onPressed: widget.queueController.stop,
                                    icon: const Icon(Icons.stop, size: 18),
                                    label: const Text('Стоп'),
                                  )
                                : FilledButton.icon(
                                    onPressed: () => _startQueue(),
                                    icon:
                                        const Icon(Icons.play_arrow, size: 18),
                                    label: const Text('Старт'),
                                  ),
                          ],
                        ),
                        if (p.isRunning ||
                            p.isPausedOffline ||
                            p.rateLimitWaitSeconds > 0 ||
                            p.errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              !isThisBook && p.isRunning
                                  ? 'В фоне переводится «${p.activeBookTitle}» — глава ${p.currentChapter}...'
                                  : p.isPausedOffline
                                      ? 'Нет сети — перевод на паузе. Ждём подключение...'
                                      : p.rateLimitWaitSeconds > 0
                                          ? 'Все модели в лимите — ждём квоту: ${_formatWaitTime(p.rateLimitWaitSeconds)}...'
                                          : p.errorMessage != null
                                              ? 'Ошибка: ${p.errorMessage}'
                                              : 'Глава ${p.currentChapter} (в очереди ${p.totalChaptersInJob})$modelBadge: '
                                                  'абзацев ${p.translatedParagraphsInChapter}/${p.totalParagraphsInChapter}',
                              style: TextStyle(
                                fontSize: 12,
                                color: p.errorMessage != null
                                    ? Colors.redAccent
                                    : p.rateLimitWaitSeconds > 0
                                        ? Colors.orangeAccent
                                        : palette.accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
              if (_chapters.isNotEmpty)
                Container(
                  color: palette.background,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _currentChapterIndex > 0
                            ? () => _loadChapter(_currentChapterIndex - 1)
                            : null,
                        icon: Icon(
                          Icons.arrow_back_ios,
                          size: 16,
                          color: palette.text,
                        ),
                      ),
                      Expanded(
                        child: DropdownButton<int>(
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          dropdownColor: palette.surface,
                          style: TextStyle(color: palette.text, fontSize: 14),
                          value: _currentChapterIndex,
                          items: _chapters
                              .map(
                                (ch) => DropdownMenuItem(
                                  value: ch.index,
                                  child: Text(
                                    '${ch.index + 1}. ${ch.title} [${_statusLabel(ch.status)}]',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (idx) {
                            if (idx != null) _loadChapter(idx);
                          },
                        ),
                      ),
                      IconButton(
                        onPressed: _currentChapterIndex < _chapters.length - 1
                            ? () => _loadChapter(_currentChapterIndex + 1)
                            : null,
                        icon: Icon(
                          Icons.arrow_forward_ios,
                          size: 16,
                          color: palette.text,
                        ),
                      ),
                    ],
                  ),
                ),
              Divider(
                height: 1,
                color: palette.secondaryText.withOpacity(0.2),
              ),
            ],
            Expanded(
              child: _loadingChapter
                  ? Center(
                      child: CircularProgressIndicator(color: palette.accent),
                    )
                  : _appearance.pageMode == ReaderPageMode.scroll
                      ? _buildScrollReader(palette, currentChapterTitle)
                      : BookPageView(
                          key: ValueKey('book_view_$_currentChapterIndex'),
                          chapterTitle: currentChapterTitle,
                          paragraphs: _paragraphs,
                          appearance: _appearance,
                          palette: palette,
                          initialPage: _currentPageInChapter,
                          onPageChanged: (page) {
                            _currentPageInChapter = page;
                          },
                          onCenterTap: () {
                            setState(() => _showControls = !_showControls);
                          },
                          onNextChapter: () {
                            if (_currentChapterIndex < _chapters.length - 1) {
                              _loadChapter(_currentChapterIndex + 1);
                            }
                          },
                          onPrevChapter: () {
                            if (_currentChapterIndex > 0) {
                              _loadChapter(_currentChapterIndex - 1);
                            }
                          },
                          onTranslateHere: () => _startQueue(
                            overrideMode: TranslateMode.nextChapters,
                            overrideAhead: 1,
                          ),
                          onTranslateSelection: _showSelectionTranslationSheet,
                          onSaveSelectionToDictionary:
                              _saveToDictionaryDirectly,
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrollReader(
    ReaderPalette palette,
    String currentChapterTitle,
  ) {
    if (_paragraphs.isEmpty) {
      return Center(
        child: Text(
          'В главе нет текста',
          style: TextStyle(color: palette.secondaryText),
        ),
      );
    }

    return SelectionArea(
      onSelectionChanged: (SelectedContent? content) {
        _scrollSelectedText = content?.plainText ?? '';
      },
      contextMenuBuilder: (context, selectableRegionState) {
        final baseItems =
            selectableRegionState.contextMenuButtonItems.where((item) {
          return item.type == ContextMenuButtonType.copy ||
              item.type == ContextMenuButtonType.selectAll;
        }).toList();

        final cleanText = _scrollSelectedText.trim();
        final items = <ContextMenuButtonItem>[
          if (cleanText.isNotEmpty) ...[
            ContextMenuButtonItem(
              label: 'Перевести',
              onPressed: () {
                selectableRegionState.hideToolbar();
                _showSelectionTranslationSheet(cleanText);
              },
            ),
            ContextMenuButtonItem(
              label: 'В словарь',
              onPressed: () {
                selectableRegionState.hideToolbar();
                _saveToDictionaryDirectly(cleanText);
              },
            ),
          ],
          ...baseItems,
        ];
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: items,
        );
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 48),
        itemCount: _paragraphs.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                currentChapterTitle,
                style: TextStyle(
                  fontSize: _appearance.fontSize + 5,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                  color: palette.text,
                ),
              ),
            );
          }

          final p = _paragraphs[index - 1];
          final hasTranslation = p.isTranslated;

          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_appearance.isOriginalOnly)
                  Text(
                    p.sourceText,
                    style: TextStyle(
                      fontSize: _appearance.fontSize,
                      height: _appearance.lineHeight,
                      color: palette.text,
                    ),
                  )
                else if (hasTranslation)
                  Text(
                    p.translatedText!,
                    style: TextStyle(
                      fontSize: _appearance.fontSize,
                      height: _appearance.lineHeight,
                      color: palette.text,
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          p.sourceText,
                          style: TextStyle(
                            fontSize: _appearance.fontSize - 1,
                            height: _appearance.lineHeight,
                            color: palette.secondaryText,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _startQueue(
                          overrideMode: TranslateMode.nextChapters,
                          overrideAhead: 1,
                        ),
                        child: Text(
                          'Перевести',
                          style: TextStyle(color: palette.accent),
                        ),
                      ),
                    ],
                  ),
                if (_appearance.showOriginal && hasTranslation) ...[
                  const SizedBox(height: 5),
                  Text(
                    p.sourceText,
                    style: TextStyle(
                      fontSize: (_appearance.fontSize - 3.5).clamp(11.0, 24.0),
                      height: 1.38,
                      color: palette.secondaryText,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
