import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import '../models/reader_theme_settings.dart';
import '../services/offline_translator_service.dart';
import '../services/settings_service.dart';
import '../services/translation_queue.dart';
import '../services/translator_service.dart';
import '../widgets/book_page_view.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  final TranslationQueueController queueController;
  final TranslatorService translatorService;
  final SettingsService settingsService;
  final TranslatorSettings initialSettings;
  final ValueChanged<TranslatorSettings> onSettingsChanged;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.queueController,
    required this.translatorService,
    required this.settingsService,
    required this.initialSettings,
    required this.onSettingsChanged,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  List<Chapter> _chapters = [];
  List<ParagraphItem> _paragraphs = [];
  int _currentChapterIndex = 0;
  int _currentPageInChapter = 0;
  double _currentScrollOffset = 0.0;
  bool _loadingChapter = true;
  bool _showControls = true;
  String _scrollSelectedText = '';

  bool _mlKitModelReady = true;
  bool _downloadingDictInReader = false;

  late TranslatorSettings _settings;
  late final ScrollController _scrollController;
  late final TextEditingController _chaptersAheadController;

  final Map<String, String> _wordLookupCache = {};

  int? _scrollHighlightOrder;
  int? _scrollHighlightSourceToken;
  int? _scrollHighlightTranslatedToken;

  ReaderAppearance _appearance = const ReaderAppearance();

  TranslateMode _selectedMode = TranslateMode.nextChapters;
  int _chaptersAhead = 3;
  int _specificChapterIndex = 0;

  StreamSubscription<TranslationProgress>? _progressSub;
  Timer? _saveProgressDebounce;

  static const Map<String, List<String>> _pronounHints = {
    'его': ['his', 'him', 'its', 'it'],
    'её': ['her', 'hers', 'its', 'it'],
    'ее': ['her', 'hers', 'its', 'it'],
    'их': ['their', 'theirs', 'them', 'they'],
    'он': ['he', 'it'],
    'она': ['she', 'it'],
    'оно': ['it'],
    'они': ['they', 'them'],
    'я': ['i', 'me'],
    'мне': ['me', 'i'],
    'меня': ['me', 'my'],
    'мой': ['my', 'mine'],
    'моя': ['my', 'mine'],
    'мы': ['we', 'us'],
    'нас': ['us', 'we'],
    'наш': ['our', 'ours'],
    'ты': ['you'],
    'вы': ['you'],
    'вас': ['you'],
    'ваш': ['your', 'yours'],
    'твой': ['your', 'yours'],
    'это': ['it', 'this', 'that'],
    'этот': ['this', 'that'],
    'тот': ['that', 'those'],
    'his': ['его', 'свой', 'свою', 'своего'],
    'him': ['его', 'ему', 'ним'],
    'her': ['её', 'ее', 'ей', 'свою'],
    'their': ['их', 'свои', 'своих'],
    'them': ['их', 'им', 'ними'],
    'it': ['это', 'его', 'её', 'ее', 'он', 'она', 'оно'],
    'its': ['его', 'её', 'ее', 'свой'],
    'he': ['он'],
    'she': ['она'],
    'they': ['они'],
  };

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _currentChapterIndex = widget.book.lastChapterIndex;
    _currentPageInChapter = widget.book.lastPageIndex;
    _currentScrollOffset = widget.book.lastScrollOffset;
    _specificChapterIndex = widget.book.lastChapterIndex;

    _chaptersAheadController = TextEditingController(text: '$_chaptersAhead');
    _scrollController = ScrollController(
      initialScrollOffset: _currentScrollOffset,
    )..addListener(_onScrollChanged);

    _initData();
    _progressSub = widget.queueController.progressStream.listen((p) {
      if (p.activeBookId == widget.book.id) {
        _refreshCurrentChapter(silent: true);
        _refreshChaptersList();
      }
    });
  }

  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    _currentScrollOffset = _scrollController.offset;
    _scheduleSaveReadingProgress();
  }

  void _scheduleSaveReadingProgress() {
    _saveProgressDebounce?.cancel();
    _saveProgressDebounce = Timer(const Duration(milliseconds: 450), () {
      _persistReadingProgressNow();
    });
  }

  Future<void> _persistReadingProgressNow() async {
    await BookDatabase.instance.updateBookReadingProgress(
      bookId: widget.book.id,
      chapterIndex: _currentChapterIndex,
      pageIndex: _currentPageInChapter,
      scrollOffset: _currentScrollOffset,
    );
  }

  Future<void> _initData() async {
    final savedAppearance = await ReaderAppearance.load();
    final dictReady = await OfflineTranslatorService.instance.isPairDownloaded(
      targetLanguage: _settings.targetLanguage,
    );
    if (mounted) {
      setState(() {
        _appearance = savedAppearance;
        _mlKitModelReady = dictReady;
      });
    }
    await _refreshChaptersList();

    final freshBook = await BookDatabase.instance.getBookById(widget.book.id);
    final startChapter =
        freshBook?.lastChapterIndex ?? widget.book.lastChapterIndex;
    final startPage = freshBook?.lastPageIndex ?? widget.book.lastPageIndex;
    final startScroll =
        freshBook?.lastScrollOffset ?? widget.book.lastScrollOffset;

    await _loadChapter(
      startChapter,
      startPage: startPage,
      startScrollOffset: startScroll,
      saveProgress: false,
    );
  }

  Future<void> _downloadBilingualDictionary() async {
    setState(() => _downloadingDictInReader = true);
    try {
      await OfflineTranslatorService.instance.downloadLanguagePair(
        targetLanguage: _settings.targetLanguage,
      );
      if (!mounted) return;
      _wordLookupCache.clear();
      setState(() => _mlKitModelReady = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Словарь загружен! Подсветка слов теперь работает за 0 мс.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) setState(() => _downloadingDictInReader = false);
    }
  }

  void _updateAppearance(ReaderAppearance next) {
    setState(() => _appearance = next);
    next.save();
  }

  Future<void> _toggleQuickEngine(bool useOffline) async {
    final nextMode = useOffline
        ? TranslationEngineMode.offlineLocal
        : TranslationEngineMode.groqCloud;
    final updated = _settings.copyWith(engineMode: nextMode);
    await widget.settingsService.saveSettings(updated);
    widget.translatorService.settings = updated;
    widget.queueController.updateSettings(updated);
    widget.onSettingsChanged(updated);
    if (mounted) {
      setState(() => _settings = updated);
    }
  }

  Future<void> _refreshChaptersList() async {
    final chs = await BookDatabase.instance.getChapters(widget.book.id);
    if (!mounted) return;
    setState(() {
      _chapters = chs;
      if (_specificChapterIndex >= _chapters.length) {
        _specificChapterIndex = (_chapters.length - 1).clamp(0, _chapters.length);
      }
    });
  }

  Future<void> _loadChapter(
    int index, {
    int startPage = 0,
    double startScrollOffset = 0.0,
    bool saveProgress = true,
  }) async {
    if (_chapters.isEmpty) return;
    final safeIdx = index.clamp(0, _chapters.length - 1);
    setState(() {
      _currentChapterIndex = safeIdx;
      _currentPageInChapter = startPage;
      _currentScrollOffset = startScrollOffset;
      _loadingChapter = true;
      _scrollHighlightOrder = null;
      _scrollHighlightSourceToken = null;
      _scrollHighlightTranslatedToken = null;
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

    if (_appearance.pageMode == ReaderPageMode.scroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final maxScroll = _scrollController.position.maxScrollExtent;
          _scrollController.jumpTo(startScrollOffset.clamp(0.0, maxScroll));
        }
      });
    }

    if (saveProgress) {
      await _persistReadingProgressNow();
    }
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

  void _startQueue({
    TranslateMode? overrideMode,
    int? overrideAhead,
    bool forceRetranslate = false,
  }) {
    final parsedAhead = int.tryParse(_chaptersAheadController.text.trim());
    final effectiveAhead =
        (overrideAhead ?? parsedAhead ?? _chaptersAhead).clamp(1, 500);

    setState(() {
      _chaptersAhead = effectiveAhead;
      _chaptersAheadController.text = '$effectiveAhead';
    });

    widget.queueController.startTranslation(
      bookId: widget.book.id,
      bookTitle: widget.book.title,
      currentReadingChapter: _currentChapterIndex,
      mode: overrideMode ?? _selectedMode,
      chaptersAhead: effectiveAhead,
      specificChapterIndex: _specificChapterIndex,
      forceRetranslate: forceRetranslate,
      targetLanguage: _settings.targetLanguage,
    );
  }

  Future<void> _confirmAndRetranslate() async {
    final scopeText = _selectedMode == TranslateMode.fullBook
        ? 'всей книги'
        : _selectedMode == TranslateMode.specificChapter
            ? 'главы №${_specificChapterIndex + 1}'
            : 'ближайших ${_chaptersAheadController.text} глав (начиная с текущей)';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Перевести повторно?'),
        content: Text(
          'Старый перевод для $scopeText будет удалён и выполнен заново выбранным движком.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Перевести заново'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _startQueue(forceRetranslate: true);
    }
  }

  Future<String> _lookupWordInContext({
    required String tappedWord,
    required String sourceParagraph,
    required String targetParagraph,
    required double relativePosition,
  }) async {
    final cacheKey =
        '${tappedWord.toLowerCase()}_${sourceParagraph.hashCode}';
    if (_wordLookupCache.containsKey(cacheKey)) {
      return _wordLookupCache[cacheKey]!;
    }
    final res = await widget.translatorService.findCounterpartWordInContext(
      tappedWord: tappedWord,
      sourceParagraph: sourceParagraph,
      targetParagraph: targetParagraph,
      relativePosition: relativePosition,
    );
    if (res.isNotEmpty) {
      _wordLookupCache[cacheKey] = res;
    }
    return res;
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
        targetLanguage: _settings.targetLanguage,
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
                      targetLanguage: _settings.targetLanguage,
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
            final isOffline =
                _settings.engineMode == TranslationEngineMode.offlineLocal;

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
                    'Оформление и движок перевода',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 14),

                  Text(
                    'Движок перевода',
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
                        icon: Icons.bolt,
                        label: 'ИИ-модели',
                        selected: !isOffline,
                        onTap: () async {
                          await _toggleQuickEngine(false);
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(width: 8),
                      _modeChip(
                        palette: palette,
                        icon: Icons.offline_pin_outlined,
                        label: 'Офлайн-словарь',
                        selected: isOffline,
                        onTap: () async {
                          await _toggleQuickEngine(true);
                          setModalState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

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

  List<String> _tokenize(String text) {
    return RegExp(r"([\p{L}\p{N}'’-]+|[^\p{L}\p{N}'’-]+)", unicode: true)
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();
  }

  String _normalizeWord(String raw) {
    return raw
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r"[^\p{L}\p{N}'’-]", unicode: true), '');
  }

  String _stemWord(String w) {
    if (w.length <= 3) return w;
    final stripped = w.replaceFirst(
      RegExp(
        r'(ами|ями|ому|ему|ого|его|ыми|ими|ться|тся|ешь|ете|ишь|ите|ать|ять|ить|еть|уть|ая|яя|ое|ее|ые|ие|ый|ий|ой|ах|ях|ом|ем|ам|ям|ов|ев|ей|ий|ую|юю|ing|ed|es|ly|er|est|s|а|я|о|е|у|ю|ы|и|ь)$',
      ),
      '',
    );
    return stripped.length >= 3 ? stripped : w;
  }

  String _transliterateRuToEn(String ru) {
    const map = {
      'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e',
      'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l',
      'м': 'm', 'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's',
      'т': 't', 'у': 'u', 'ф': 'f', 'х': 'h', 'ц': 'ts', 'ч': 'ch',
      'ш': 'sh', 'щ': 'sch', 'ы': 'y', 'э': 'e', 'ю': 'yu', 'я': 'ya',
    };
    final sb = StringBuffer();
    for (int i = 0; i < ru.length; i++) {
      final ch = ru[i];
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }

  int? _findBestMatchToken({
    required String targetParagraph,
    required String tappedNormWord,
    required String candidateTranslation,
    required double relativePosition,
  }) {
    final tokens = _tokenize(targetParagraph);
    if (tokens.isEmpty) return null;

    final rawCandidates = <String>[
      ...candidateTranslation
          .split(RegExp(r'\s+'))
          .map(_normalizeWord)
          .where((w) => w.isNotEmpty),
      ...(_pronounHints[tappedNormWord] ?? const []),
      _transliterateRuToEn(tappedNormWord),
    ];

    final candidateStems = rawCandidates.map(_stemWord).toList();
    if (rawCandidates.isEmpty) return null;

    int? bestIdx;
    double bestScore = -1.0;

    for (int i = 0; i < tokens.length; i++) {
      final normW = _normalizeWord(tokens[i]);
      if (normW.isEmpty) continue;
      final stemW = _stemWord(normW);

      final posRatio = i / tokens.length;
      final posPenalty = (posRatio - relativePosition).abs() * 1.2;

      for (int cIdx = 0; cIdx < rawCandidates.length; cIdx++) {
        final cand = rawCandidates[cIdx];
        final candStem = candidateStems[cIdx];
        final candBonus = cIdx == 0 ? 0.35 : 0.0;

        if (normW == cand) {
          final score = 12.0 + candBonus - posPenalty;
          if (score > bestScore) {
            bestScore = score;
            bestIdx = i;
          }
        } else if (stemW.length >= 3 && stemW == candStem) {
          final score = 9.5 + candBonus - posPenalty;
          if (score > bestScore) {
            bestScore = score;
            bestIdx = i;
          }
        } else {
          final minLen = math.min(stemW.length, candStem.length);
          if (minLen >= 3) {
            int commonPrefix = 0;
            while (commonPrefix < minLen &&
                stemW[commonPrefix] == candStem[commonPrefix]) {
              commonPrefix++;
            }
            final ratio =
                commonPrefix / math.max(stemW.length, candStem.length);
            if (ratio >= 0.55) {
              final score = ratio * 6.5 + candBonus - posPenalty;
              if (score > bestScore) {
                bestScore = score;
                bestIdx = i;
              }
            }
          }
        }
      }
    }

    return bestIdx;
  }

  Future<void> _onScrollWordTap({
    required ParagraphItem paragraph,
    required int tokenIndex,
    required String rawWord,
    required bool isOriginalText,
    required double relPos,
  }) async {
    final cleanWord = _normalizeWord(rawWord);
    if (cleanWord.isEmpty || !paragraph.isTranslated) return;

    if (_scrollHighlightOrder == paragraph.orderIndex &&
        ((isOriginalText && _scrollHighlightSourceToken == tokenIndex) ||
            (!isOriginalText &&
                _scrollHighlightTranslatedToken == tokenIndex))) {
      setState(() {
        _scrollHighlightOrder = null;
        _scrollHighlightSourceToken = null;
        _scrollHighlightTranslatedToken = null;
      });
      return;
    }

    final sourceText =
        isOriginalText ? paragraph.sourceText : paragraph.translatedText!;
    final targetText =
        isOriginalText ? paragraph.translatedText! : paragraph.sourceText;

    final instantMatch = _findBestMatchToken(
      targetParagraph: targetText,
      tappedNormWord: cleanWord,
      candidateTranslation: '',
      relativePosition: relPos,
    );

    setState(() {
      _scrollHighlightOrder = paragraph.orderIndex;
      if (isOriginalText) {
        _scrollHighlightSourceToken = tokenIndex;
        _scrollHighlightTranslatedToken = instantMatch;
      } else {
        _scrollHighlightTranslatedToken = tokenIndex;
        _scrollHighlightSourceToken = instantMatch;
      }
    });

    if (instantMatch == null) {
      try {
        final candidate = await _lookupWordInContext(
          tappedWord: cleanWord,
          sourceParagraph: sourceText,
          targetParagraph: targetText,
          relativePosition: relPos,
        );
        if (!mounted) return;
        if (_scrollHighlightOrder != paragraph.orderIndex) return;

        final matchedToken = _findBestMatchToken(
          targetParagraph: targetText,
          tappedNormWord: cleanWord,
          candidateTranslation: candidate,
          relativePosition: relPos,
        );
        if (matchedToken != null) {
          setState(() {
            if (isOriginalText) {
              _scrollHighlightTranslatedToken = matchedToken;
            } else {
              _scrollHighlightSourceToken = matchedToken;
            }
          });
        }
      } catch (_) {}
    }
  }

  Widget _buildScrollInteractiveText({
    required ReaderPalette palette,
    required ParagraphItem paragraph,
    required String text,
    required TextStyle baseStyle,
    required bool isOriginalText,
  }) {
    final activeToken = _scrollHighlightOrder == paragraph.orderIndex
        ? (isOriginalText
            ? _scrollHighlightSourceToken
            : _scrollHighlightTranslatedToken)
        : null;

    final markerColor = palette.brightness == Brightness.dark
        ? const Color(0xFFD98A3C).withOpacity(0.38)
        : const Color(0xFFFFD54F).withOpacity(0.78);

    final tokens = _tokenize(text);
    final spans = <InlineSpan>[];

    for (int i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final norm = _normalizeWord(token);
      final isWord = norm.isNotEmpty;
      final isHighlighted = isWord && activeToken != null && i == activeToken;

      if (!isWord) {
        spans.add(TextSpan(text: token));
      } else {
        final relPos = tokens.isEmpty ? 0.5 : i / tokens.length;
        spans.add(
          TextSpan(
            text: token,
            style: isHighlighted
                ? baseStyle.copyWith(
                    backgroundColor: markerColor,
                    fontWeight: FontWeight.w600,
                  )
                : null,
            recognizer: TapGestureRecognizer()
              ..onTap = () => _onScrollWordTap(
                    paragraph: paragraph,
                    tokenIndex: i,
                    rawWord: token,
                    isOriginalText: isOriginalText,
                    relPos: relPos,
                  ),
          ),
        );
      }
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  @override
  void dispose() {
    _saveProgressDebounce?.cancel();
    _persistReadingProgressNow();
    _progressSub?.cancel();
    _scrollController.dispose();
    _chaptersAheadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ReaderPalette.of(_appearance.colorTheme);
    final currentChapterTitle = _chapters.isNotEmpty
        ? _chapters[_currentChapterIndex].title
        : 'Глава 1';
    final isOfflineEngine =
        _settings.engineMode == TranslationEngineMode.offlineLocal;

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
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                avatar: Icon(
                  isOfflineEngine ? Icons.offline_pin : Icons.bolt,
                  size: 16,
                  color: palette.accent,
                ),
                label: Text(
                  isOfflineEngine ? 'Офлайн' : 'ИИ',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: palette.text,
                  ),
                ),
                backgroundColor: palette.background,
                side: BorderSide(color: palette.accent.withOpacity(0.45)),
                onPressed: () => _toggleQuickEngine(!isOfflineEngine),
              ),
            ),
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
              tooltip: 'Шрифт, тема и движок',
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
                                  fontSize: 13,
                                ),
                                value: _selectedMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: TranslateMode.nextChapters,
                                    child: Text('+N глав вперёд'),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslateMode.specificChapter,
                                    child: Text('Конкретная глава'),
                                  ),
                                  DropdownMenuItem(
                                    value: TranslateMode.fullBook,
                                    child: Text('Вся книга'),
                                  ),
                                ],
                                onChanged: p.isRunning
                                    ? null
                                    : (val) {
                                        if (val != null) {
                                          setState(() {
                                            _selectedMode = val;
                                            if (val ==
                                                TranslateMode.specificChapter) {
                                              _specificChapterIndex =
                                                  _currentChapterIndex;
                                            }
                                          });
                                        }
                                      },
                              ),
                            ),
                            if (_selectedMode == TranslateMode.nextChapters) ...[
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 54,
                                height: 38,
                                child: TextField(
                                  controller: _chaptersAheadController,
                                  enabled: !p.isRunning,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  style: TextStyle(
                                    color: palette.text,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    hintText: '3',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ] else if (_selectedMode ==
                                    TranslateMode.specificChapter &&
                                _chapters.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Expanded(
                                child: DropdownButton<int>(
                                  isExpanded: true,
                                  dropdownColor: palette.surface,
                                  style: TextStyle(
                                    color: palette.text,
                                    fontSize: 13,
                                  ),
                                  value: _specificChapterIndex.clamp(
                                    0,
                                    _chapters.length - 1,
                                  ),
                                  items: _chapters
                                      .map(
                                        (ch) => DropdownMenuItem(
                                          value: ch.index,
                                          child: Text(
                                            'Гл. ${ch.index + 1}: ${ch.title}',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: p.isRunning
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            setState(
                                              () => _specificChapterIndex = val,
                                            );
                                          }
                                        },
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            if (p.isRunning)
                              FilledButton.tonalIcon(
                                onPressed: widget.queueController.stop,
                                icon: const Icon(Icons.stop, size: 18),
                                label: const Text('Стоп'),
                              )
                            else ...[
                              FilledButton.icon(
                                onPressed: () => _startQueue(),
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: const Text('Старт'),
                              ),
                              const SizedBox(width: 4),
                              IconButton.outlined(
                                tooltip: 'Перевести повторно (перезаписать)',
                                icon: const Icon(Icons.refresh, size: 20),
                                onPressed: _confirmAndRetranslate,
                              ),
                            ],
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
              if (_appearance.showOriginal && !_mlKitModelReady)
                Container(
                  width: double.infinity,
                  color: palette.accent.withOpacity(0.14),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.flash_on, size: 16, color: palette.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Для мгновенной подсветки слов без сети скачайте словарь (~30 МБ)',
                          style: TextStyle(fontSize: 11, color: palette.text),
                        ),
                      ),
                      TextButton(
                        onPressed: _downloadingDictInReader
                            ? null
                            : _downloadBilingualDictionary,
                        child: _downloadingDictInReader
                            ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: palette.accent,
                                ),
                              )
                            : Text(
                                'Скачать',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: palette.accent,
                                ),
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
                            _scheduleSaveReadingProgress();
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
                            overrideMode: TranslateMode.specificChapter,
                          ),
                          onTranslateSelection: _showSelectionTranslationSheet,
                          onSaveSelectionToDictionary:
                              _saveToDictionaryDirectly,
                          onLookupWordInContext: _lookupWordInContext,
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
          ...selectableRegionState.contextMenuButtonItems,
        ];
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: items,
        );
      },
      child: ListView.builder(
        controller: _scrollController,
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
          final translatedStyle = TextStyle(
            fontSize: _appearance.fontSize,
            height: _appearance.lineHeight,
            color: palette.text,
          );
          final originalStyle = TextStyle(
            fontSize: (_appearance.fontSize - 3.5).clamp(11.0, 24.0),
            height: 1.38,
            color: palette.secondaryText,
            fontStyle: FontStyle.italic,
          );

          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_appearance.isOriginalOnly)
                  Text(p.sourceText, style: translatedStyle)
                else if (hasTranslation && _appearance.showOriginal)
                  _buildScrollInteractiveText(
                    palette: palette,
                    paragraph: p,
                    text: p.translatedText!,
                    baseStyle: translatedStyle,
                    isOriginalText: false,
                  )
                else if (hasTranslation)
                  Text(p.translatedText!, style: translatedStyle)
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
                          overrideMode: TranslateMode.specificChapter,
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
                  _buildScrollInteractiveText(
                    palette: palette,
                    paragraph: p,
                    text: p.sourceText,
                    baseStyle: originalStyle,
                    isOriginalText: true,
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
