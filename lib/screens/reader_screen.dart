import 'package:flutter/material.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import '../services/translation_queue.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  final TranslationQueueController queueController;
  final String targetLanguage;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.queueController,
    required this.targetLanguage,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  List<Chapter> _chapters = [];
  List<ParagraphItem> _paragraphs = [];
  int _currentChapterIndex = 0;
  bool _showOriginal = false;
  bool _loadingChapter = true;

  TranslateMode _selectedMode = TranslateMode.nextChapters;
  int _chaptersAhead = 3;

  @override
  void initState() {
    super.initState();
    _initData();
    widget.queueController.progressStream.listen((_) {
      _refreshCurrentChapter(silent: true);
      _refreshChaptersList();
    });
  }

  Future<void> _initData() async {
    await _refreshChaptersList();
    await _loadChapter(0);
  }

  Future<void> _refreshChaptersList() async {
    final chs = await BookDatabase.instance.getChapters(widget.book.id);
    if (!mounted) return;
    setState(() => _chapters = chs);
  }

  Future<void> _loadChapter(int index) async {
    if (_chapters.isEmpty) return;
    final safeIdx = index.clamp(0, _chapters.length - 1);
    setState(() {
      _currentChapterIndex = safeIdx;
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
      currentReadingChapter: _currentChapterIndex,
      mode: overrideMode ?? _selectedMode,
      chaptersAhead: overrideAhead ?? _chaptersAhead,
      targetLanguage: widget.targetLanguage,
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

  @override
  void dispose() {
    widget.queueController.stop();
    widget.queueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentChapterTitle = _chapters.isNotEmpty
        ? _chapters[_currentChapterIndex].title
        : 'Глава 1';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.book.title,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(_showOriginal ? Icons.translate : Icons.visibility),
            tooltip: _showOriginal ? 'Скрыть оригинал' : 'Показать оригинал',
            onPressed: () => setState(() => _showOriginal = !_showOriginal),
          ),
        ],
      ),
      body: Column(
        children: [
          StreamBuilder<TranslationProgress>(
            stream: widget.queueController.progressStream,
            initialData: const TranslationProgress(),
            builder: (context, snapshot) {
              final p = snapshot.data ?? const TranslationProgress();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<TranslateMode>(
                            isExpanded: true,
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
                                icon: const Icon(Icons.stop),
                                label: const Text('Стоп'),
                              )
                            : FilledButton.icon(
                                onPressed: () => _startQueue(),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Старт'),
                              ),
                      ],
                    ),
                    if (p.isRunning || p.isPausedOffline || p.errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          p.isPausedOffline
                              ? 'Нет сети — перевод на паузе. Ждём подключение...'
                              : p.errorMessage != null
                                  ? 'Ошибка: ${p.errorMessage}'
                                  : 'Глава ${p.currentChapter} (в очереди ${p.totalChaptersInJob}): '
                                      'абзацев ${p.translatedParagraphsInChapter}/${p.totalParagraphsInChapter}',
                          style: TextStyle(
                            fontSize: 12,
                            color: p.errorMessage != null
                                ? Colors.redAccent
                                : Colors.tealAccent,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _currentChapterIndex > 0
                        ? () => _loadChapter(_currentChapterIndex - 1)
                        : null,
                    icon: const Icon(Icons.arrow_back_ios, size: 18),
                  ),
                  Expanded(
                    child: DropdownButton<int>(
                      isExpanded: true,
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
                    icon: const Icon(Icons.arrow_forward_ios, size: 18),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _loadingChapter
                ? const Center(child: CircularProgressIndicator())
                : _paragraphs.isEmpty
                    ? const Center(child: Text('В главе нет текста'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _paragraphs.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Text(
                                currentChapterTitle,
                                style: Theme.of(context).textTheme.titleLarge,
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
                                if (hasTranslation)
                                  Text(
                                    p.translatedText!,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      height: 1.5,
                                    ),
                                  )
                                else
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          p.sourceText,
                                          style: TextStyle(
                                            fontSize: 16,
                                            height: 1.45,
                                            color: Colors.grey.shade400,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      TextButton(
                                        onPressed: () => _startQueue(
                                          overrideMode:
                                              TranslateMode.nextChapters,
                                          overrideAhead: 1,
                                        ),
                                        child: const Text('Перевести'),
                                      ),
                                    ],
                                  ),
                                if (_showOriginal && hasTranslation) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    p.sourceText,
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.35,
                                      color: Colors.grey.shade500,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
