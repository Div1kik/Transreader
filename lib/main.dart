import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'db/book_database.dart';
import 'models/book_models.dart';
import 'screens/reader_screen.dart';
import 'screens/settings_screen.dart';
import 'services/book_parser.dart';
import 'services/settings_service.dart';
import 'services/translation_queue.dart';
import 'services/translator_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TransReaderApp());
}

class TransReaderApp extends StatelessWidget {
  const TransReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    const warmAccent = Color(0xFFD98A3C);
    const warmBg = Color(0xFF191613);
    const warmCard = Color(0xFF241F1B);

    return MaterialApp(
      title: 'TransReader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: warmBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: warmAccent,
          primary: warmAccent,
          secondary: const Color(0xFFE5A967),
          surface: warmCard,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF211C18),
          foregroundColor: Color(0xFFF3ECE4),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: warmCard,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: const Color(0xFFE5A967).withOpacity(0.12),
            ),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: warmAccent,
          foregroundColor: Color(0xFF191613),
        ),
        useMaterial3: true,
      ),
      home: const LibraryScreen(),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final SettingsService _settingsService = SettingsService();
  TranslatorSettings _settings = const TranslatorSettings();
  late final TranslatorService _translatorService;
  late final TranslationQueueController _queueController;
  List<Book> _books = [];
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _translatorService = TranslatorService(settings: _settings);
    _queueController = TranslationQueueController(
      db: BookDatabase.instance,
      translator: _translatorService,
    );
    _initAll();
  }

  @override
  void dispose() {
    _queueController.stop();
    _queueController.dispose();
    super.dispose();
  }

  Future<void> _initAll() async {
    final loadedSettings = await _settingsService.loadSettings();
    final loadedBooks = await BookDatabase.instance.getBooks();
    if (!mounted) return;
    _translatorService.settings = loadedSettings;
    _queueController.updateSettings(loadedSettings);
    setState(() {
      _settings = loadedSettings;
      _books = loadedBooks;
      _loading = false;
    });
  }

  Future<void> _reloadBooks() async {
    final loadedBooks = await BookDatabase.instance.getBooks();
    if (!mounted) return;
    setState(() => _books = loadedBooks);
  }

  String _decodeFileBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return _decodeWindows1251(bytes);
    }
  }

  String _decodeWindows1251(List<int> bytes) {
    const cp1251Extra = {
      0x80: 0x0402, 0x81: 0x0403, 0x82: 0x201A, 0x83: 0x0453,
      0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
      0x88: 0x20AC, 0x89: 0x2030, 0x8A: 0x0409, 0x8B: 0x2039,
      0x8C: 0x040A, 0x8D: 0x040C, 0x8E: 0x040B, 0x8F: 0x040F,
      0x90: 0x0452, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
      0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x99: 0x2122, 0x9A: 0x0459, 0x9B: 0x203A, 0x9C: 0x045A,
      0x9D: 0x045C, 0x9E: 0x045B, 0x9F: 0x045F, 0xA0: 0x00A0,
      0xA1: 0x040E, 0xA2: 0x045E, 0xA3: 0x0408, 0xA4: 0x00A4,
      0xA5: 0x0490, 0xA6: 0x00A6, 0xA7: 0x00A7, 0xA8: 0x0401,
      0xA9: 0x00A9, 0xAA: 0x0404, 0xAB: 0x00AB, 0xAC: 0x00AC,
      0xAD: 0x00AD, 0xAE: 0x00AE, 0xAF: 0x0407, 0xB0: 0x00B0,
      0xB1: 0x00B1, 0xB2: 0x0406, 0xB3: 0x0456, 0xB4: 0x0491,
      0xB5: 0x00B5, 0xB6: 0x00B6, 0xB7: 0x00B7, 0xB8: 0x0451,
      0xB9: 0x2116, 0xBA: 0x0454, 0xBB: 0x00BB, 0xBC: 0x0458,
      0xBD: 0x0405, 0xBE: 0x0455, 0xBF: 0x0457,
    };

    final buffer = StringBuffer();
    for (final b in bytes) {
      if (b < 0x80) {
        buffer.writeCharCode(b);
      } else if (b >= 0xC0) {
        buffer.writeCharCode(0x0410 + (b - 0xC0));
      } else {
        buffer.writeCharCode(cp1251Extra[b] ?? 0xFFFD);
      }
    }
    return buffer.toString();
  }

  Future<void> _importBook() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final lowerName = file.name.toLowerCase();
      if (!lowerName.endsWith('.txt') && !lowerName.endsWith('.fb2')) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Выберите файл формата .txt или .fb2'),
          ),
        );
        return;
      }

      setState(() => _importing = true);
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);

      if (bytes == null) {
        throw Exception('Не удалось прочитать файл книги');
      }

      final rawContent = _decodeFileBytes(bytes);
      final bookId = DateTime.now().millisecondsSinceEpoch.toString();

      final parsed = BookParser.parse(
        bookId: bookId,
        fileName: file.name,
        rawContent: rawContent,
      );

      await BookDatabase.instance.insertBookWithChapters(
        parsed.book,
        parsed.chapters,
        parsed.paragraphs,
      );
      await _reloadBooks();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка импорта: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<TranslatorSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(initialSettings: _settings),
      ),
    );
    if (updated != null && mounted) {
      _translatorService.settings = updated;
      _queueController.updateSettings(updated);
      setState(() => _settings = updated);
    }
  }

  void _openBook(Book book) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ReaderScreen(
              book: book,
              queueController: _queueController,
              translatorService: _translatorService,
              targetLanguage: _settings.targetLanguage,
            ),
          ),
        )
        .then((_) => _reloadBooks());
  }

  void _downloadFullBook(Book book) {
    final isOffline = _settings.engineMode == TranslationEngineMode.offlineLocal;
    if (!isOffline && _settings.apiKey.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Подключите переводчик в 1 клик или включите офлайн-модель в настройках',
          ),
        ),
      );
      return;
    }

    _queueController.startTranslation(
      bookId: book.id,
      bookTitle: book.title,
      currentReadingChapter: 0,
      mode: TranslateMode.fullBook,
      targetLanguage: _settings.targetLanguage,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Запущен фоновый перевод всей книги «${book.title}»'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteBook(Book book) async {
    if (_queueController.currentProgress.isRunning &&
        _queueController.currentProgress.activeBookId == book.id) {
      _queueController.stop();
    }
    await BookDatabase.instance.deleteBook(book.id);
    await _reloadBooks();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.auto_stories, color: accent, size: 22),
            const SizedBox(width: 8),
            const Text(
              'TransReader',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Настройки переводчика',
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _importBook,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF191613),
                ),
              )
            : const Icon(Icons.add),
        label: Text(
          _importing ? 'Загрузка...' : 'Добавить книгу',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: StreamBuilder<TranslationProgress>(
        stream: _queueController.progressStream,
        initialData: _queueController.currentProgress,
        builder: (context, snapshot) {
          final p = snapshot.data ?? const TranslationProgress();
          final hasActiveBanner = p.isRunning ||
              p.isPausedOffline ||
              p.rateLimitWaitSeconds > 0 ||
              p.errorMessage != null;

          return Column(
            children: [
              if (hasActiveBanner)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2B241E),
                    border: Border(
                      bottom: BorderSide(
                        color: accent.withOpacity(0.25),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (p.errorMessage != null)
                        const Icon(
                          Icons.error_outline,
                          color: Colors.redAccent,
                          size: 18,
                        )
                      else
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
                          p.errorMessage != null
                              ? 'Ошибка перевода «${p.activeBookTitle}»: ${p.errorMessage}'
                              : p.isPausedOffline
                                  ? 'Нет сети — перевод «${p.activeBookTitle}» на паузе...'
                                  : p.rateLimitWaitSeconds > 0
                                      ? 'Фоновый перевод «${p.activeBookTitle}»: ждём квоту ${p.rateLimitWaitSeconds} сек...'
                                      : 'Скачивается «${p.activeBookTitle}» — гл. ${p.currentChapter}/${p.totalChaptersInJob} (${p.translatedParagraphsInChapter}/${p.totalParagraphsInChapter})',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: p.errorMessage != null
                                ? Colors.redAccent
                                : const Color(0xFFF3ECE4),
                          ),
                        ),
                      ),
                      if (p.isRunning || p.rateLimitWaitSeconds > 0)
                        TextButton(
                          onPressed: _queueController.stop,
                          child: const Text('Стоп'),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: accent))
                    : _books.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.menu_book,
                                    size: 68,
                                    color: accent,
                                  ),
                                  const SizedBox(height: 14),
                                  const Text(
                                    'Ваша библиотека пуста',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFF3ECE4),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Нажмите «Добавить книгу», чтобы открыть файл .txt или .fb2',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Color(0xFFA89E93)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 84),
                            itemCount: _books.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final book = _books[index];
                              final isThisDownloading =
                                  (p.isRunning || p.rateLimitWaitSeconds > 0) &&
                                      p.activeBookId == book.id;

                              return Card(
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  leading: Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: accent.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(Icons.book, color: accent),
                                  ),
                                  title: Text(
                                    book.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFF3ECE4),
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      isThisDownloading
                                          ? 'Переводится: гл. ${p.currentChapter} (${p.translatedParagraphsInChapter}/${p.totalParagraphsInChapter})'
                                          : 'Формат: ${book.format.toUpperCase()} • Глав: ${book.totalChapters}',
                                      style: TextStyle(
                                        color: isThisDownloading
                                            ? accent
                                            : const Color(0xFFA89E93),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  onTap: () => _openBook(book),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isThisDownloading)
                                        IconButton(
                                          tooltip: 'Остановить загрузку',
                                          icon: Icon(
                                            Icons.stop_circle_outlined,
                                            color: accent,
                                          ),
                                          onPressed: _queueController.stop,
                                        )
                                      else
                                        IconButton(
                                          tooltip: 'Скачать всю книгу',
                                          icon: Icon(
                                            Icons.cloud_download_outlined,
                                            color: accent,
                                          ),
                                          onPressed: () =>
                                              _downloadFullBook(book),
                                        ),
                                      IconButton(
                                        tooltip: 'Удалить книгу',
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Color(0xFFA89E93),
                                        ),
                                        onPressed: () => _deleteBook(book),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          );
        },
      ),
    );
  }
}
