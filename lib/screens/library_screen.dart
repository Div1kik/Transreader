import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../db/book_database.dart';
import '../models/book_models.dart';
import '../services/book_parser.dart';
import '../services/settings_service.dart';
import '../services/translation_queue.dart';
import '../services/translator_service.dart';
import 'dictionary_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final SettingsService _settingsService = SettingsService();
  late TranslatorSettings _settings;
  late TranslatorService _translatorService;
  late TranslationQueueController _queueController;

  List<Book> _books = [];
  bool _loading = true;
  bool _importing = false;
  String? _importStatusText;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _settings = const TranslatorSettings();
    _translatorService = TranslatorService(settings: _settings);
    _queueController = TranslationQueueController(
      db: BookDatabase.instance,
      translator: _translatorService,
    );
    _init();
  }

  Future<void> _init() async {
    final loadedSettings = await _settingsService.loadSettings();
    _settings = loadedSettings;
    _translatorService.settings = loadedSettings;
    _queueController.updateSettings(loadedSettings);
    await _reloadBooks();
  }

  Future<void> _reloadBooks() async {
    final list = await BookDatabase.instance.getBooks();
    if (!mounted) return;
    setState(() {
      _books = list;
      _loading = false;
    });
  }

  Future<void> _importBook() async {
    setState(() {
      _importing = true;
      _importStatusText = 'Открытие файла...';
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['fb2', 'txt', 'epub', 'pdf'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);

      if (bytes == null) {
        throw Exception('Не удалось прочитать файл книги');
      }

      final bundle = await BookParser.parseFromBytes(
        bytes: bytes,
        fileName: file.name,
        onProgress: (status) {
          if (mounted) {
            setState(() => _importStatusText = status);
          }
        },
      );

      await BookDatabase.instance.insertBookWithChapters(
        bundle.book,
        bundle.chapters,
        bundle.paragraphs,
      );

      await _reloadBooks();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Документ «${bundle.book.title}» (${bundle.book.format}) добавлен: разделов ${bundle.book.totalChapters}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка импорта: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _importStatusText = null;
        });
      }
    }
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<TranslatorSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(initialSettings: _settings),
      ),
    );
    if (updated != null) {
      setState(() => _settings = updated);
      _translatorService.settings = updated;
      _queueController.updateSettings(updated);
    }
  }

  Future<void> _deleteBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить книгу / документ?'),
        content: Text('«${book.title}» и её перевод будут удалены из памяти.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await BookDatabase.instance.deleteBook(book.id);
      await _reloadBooks();
    }
  }

  Widget _buildBookCover(Book book, Color accent) {
    if (book.coverBase64 != null && book.coverBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(book.coverBase64!);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 48,
            height: 68,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildFallbackCover(book, accent),
          ),
        );
      } catch (_) {}
    }
    return _buildFallbackCover(book, accent);
  }

  Widget _buildFallbackCover(Book book, Color accent) {
    return Container(
      width: 48,
      height: 68,
      decoration: BoxDecoration(
        color: accent.withOpacity(0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withOpacity(0.35)),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            book.format == 'PDF'
                ? Icons.picture_as_pdf_outlined
                : Icons.auto_stories,
            color: accent,
            size: 22,
          ),
          const SizedBox(height: 2),
          Text(
            book.format,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _queueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(_tabIndex == 0 ? 'Библиотека' : 'Личный словарь'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Настройки ИИ и резервная копия',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_importing && _importStatusText != null)
            Container(
              width: double.infinity,
              color: accent.withOpacity(0.18),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _importStatusText!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          StreamBuilder<TranslationProgress>(
            stream: _queueController.progressStream,
            initialData: _queueController.currentProgress,
            builder: (context, snapshot) {
              final p = snapshot.data ?? const TranslationProgress();
              if (!p.isRunning &&
                  !p.isPausedOffline &&
                  p.rateLimitWaitSeconds <= 0) {
                return const SizedBox.shrink();
              }
              return Container(
                width: double.infinity,
                color: accent.withOpacity(0.16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.isPausedOffline
                            ? 'Нет сети — перевод «${p.activeBookTitle}» на паузе'
                            : p.rateLimitWaitSeconds > 0
                                ? 'Лимит модели — ждём ${p.rateLimitWaitSeconds}с («${p.activeBookTitle}»)'
                                : 'Переводится «${p.activeBookTitle}»: раздел ${p.currentChapter} (${p.translatedParagraphsInChapter}/${p.totalParagraphsInChapter})',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _queueController.stop,
                      child: const Text('Стоп'),
                    ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: _tabIndex == 1
                ? const DictionaryScreen()
                : _loading
                    ? Center(child: CircularProgressIndicator(color: accent))
                    : _books.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.menu_book_outlined,
                                    size: 64,
                                    color: accent.withOpacity(0.7),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Библиотека пока пуста',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Нажмите «Добавить книгу», чтобы загрузить .pdf (включая сканы), .epub, .fb2 или .txt файл.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Color(0xFFA89E93)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                            itemCount: _books.length,
                            itemBuilder: (context, index) {
                              final book = _books[index];
                              final pct =
                                  (book.readingProgressPercent * 100).round();

                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ReaderScreen(
                                          book: book,
                                          queueController: _queueController,
                                          translatorService:
                                              _translatorService,
                                          settingsService: _settingsService,
                                          initialSettings: _settings,
                                          onSettingsChanged: (next) {
                                            setState(() => _settings = next);
                                          },
                                        ),
                                      ),
                                    );
                                    _reloadBooks();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      children: [
                                        _buildBookCover(book, accent),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                book.title,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              if (book.author.isNotEmpty) ...[
                                                const SizedBox(height: 2),
                                                Text(
                                                  book.author,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Color(0xFFA89E93),
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 6),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        4,
                                                      ),
                                                      child:
                                                          LinearProgressIndicator(
                                                        value: book
                                                            .readingProgressPercent,
                                                        minHeight: 5,
                                                        backgroundColor:
                                                            Colors.white10,
                                                        color: accent,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    '${book.format == 'PDF' ? 'Стр.' : 'Гл.'} ${book.lastChapterIndex + 1}/${book.totalChapters} ($pct%)',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Color(0xFFA89E93),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.redAccent,
                                          ),
                                          onPressed: () => _deleteBook(book),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton.extended(
              onPressed: _importing ? null : _importBook,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(_importing ? 'Распознавание...' : 'Добавить файл'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) {
          setState(() => _tabIndex = idx);
          if (idx == 0) _reloadBooks();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: 'Библиотека',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmarks_outlined),
            selectedIcon: Icon(Icons.bookmarks),
            label: 'Словарь',
          ),
        ],
      ),
    );
  }
}
