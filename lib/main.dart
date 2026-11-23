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
  runApp(const BookTranslatorApp());
}

class BookTranslatorApp extends StatelessWidget {
  const BookTranslatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Book Translator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
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
  List<Book> _books = [];
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    final loadedSettings = await _settingsService.loadSettings();
    final loadedBooks = await BookDatabase.instance.getAllBooks();
    if (!mounted) return;
    setState(() {
      _settings = loadedSettings;
      _books = loadedBooks;
      _loading = false;
    });
  }

  Future<void> _reloadBooks() async {
    final loadedBooks = await BookDatabase.instance.getAllBooks();
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
    const cp1251Extra = <int, int>{
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
        type: FileType.custom,
        allowedExtensions: ['txt', 'fb2'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      setState(() => _importing = true);
      final file = result.files.first;
      final ext = (file.extension ?? '').toLowerCase();
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);

      if (bytes == null) {
        throw Exception('Не удалось прочитать файл книги');
      }

      final rawContent = _decodeFileBytes(bytes);
      final bookId = DateTime.now().millisecondsSinceEpoch.toString();
      final fallbackTitle = file.name.replaceAll(
        RegExp(r'\.(txt|fb2)$', caseSensitive: false),
        '',
      );

      final parsed = ext == 'fb2'
          ? BookParser.parseFb2(
              bookId: bookId,
              xmlContent: rawContent,
              fallbackTitle: fallbackTitle,
            )
          : BookParser.parseTxt(
              bookId: bookId,
              textContent: rawContent,
              title: fallbackTitle,
            );

      await BookDatabase.instance.insertParsedBook(parsed);
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
      setState(() => _settings = updated);
    }
  }

  void _openBook(Book book) {
    final translator = TranslatorService(settings: _settings);
    final queueController = TranslationQueueController(
      db: BookDatabase.instance,
      translator: translator,
    );

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ReaderScreen(
              book: book,
              queueController: queueController,
              targetLanguage: _settings.targetLanguage,
            ),
          ),
        )
        .then((_) => _reloadBooks());
  }

  Future<void> _deleteBook(Book book) async {
    await BookDatabase.instance.deleteBook(book.id);
    await _reloadBooks();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Библиотека книг'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Настройки API',
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
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_importing ? 'Загрузка...' : 'Добавить книгу'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.menu_book, size: 64, color: Colors.teal),
                        const SizedBox(height: 12),
                        const Text(
                          'Пока нет загруженных книг',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Нажми «Добавить книгу», чтобы выбрать файл .txt или .fb2',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _books.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final book = _books[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.book, color: Colors.teal),
                        title: Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'Формат: ${book.format.toUpperCase()} • Глав: ${book.totalChapters}',
                        ),
                        onTap: () => _openBook(book),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteBook(book),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
