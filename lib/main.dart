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

void main() {
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
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _loading = true);
    final loadedSettings = await _settingsService.loadSettings();
    final books = await BookDatabase.instance.getBooks();
    if (!mounted) return;
    setState(() {
      _settings = loadedSettings;
      _books = books;
      _loading = false;
    });
  }

  Future<void> _refreshBooks() async {
    final books = await BookDatabase.instance.getBooks();
    if (!mounted) return;
    setState(() => _books = books);
  }

  String _decodeWindows1251(List<int> bytes) {
    const cp1251Extra = <int, int>{
      0x80: 0x0402, 0x81: 0x0403, 0x82: 0x201A, 0x83: 0x0453,
      0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
      0x88: 0x20AC, 0x89: 0x2030, 0x8A: 0x0409, 0x8B: 0x2039,
      0x8C: 0x040A, 0x8D: 0x040C, 0x8E: 0x040B, 0x8F: 0x040F,
      0x90: 0x0452, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
      0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x0020, 0x99: 0x2122, 0x9A: 0x0459, 0x9B: 0x203A,
      0x9C: 0x045A, 0x9D: 0x045C, 0x9E: 0x045B, 0x9F: 0x045F,
      0xA0: 0x00A0, 0xA1: 0x040E, 0xA2: 0x045E, 0xA3: 0x0408,
      0xA4: 0x00A4, 0xA5: 0x0490, 0xA6: 0x00A6, 0xA7: 0x00A7,
      0xA8: 0x0401, 0xA9: 0x00A9, 0xAA: 0x0404, 0xAB: 0x00AB,
      0xAC: 0x00AC, 0xAD: 0x00AD, 0xAE: 0x00AE, 0xAF: 0x0407,
      0xB0: 0x00B0, 0xB1: 0x00B1, 0xB2: 0x0406, 0xB3: 0x0456,
      0xB4: 0x0491, 0xB5: 0x00B5, 0xB6: 0x00B6, 0xB7: 0x00B7,
      0xB8: 0x0451, 0xB9: 0x2116, 0xBA: 0x0454, 0xBB: 0x00BB,
      0xBC: 0x0458, 0xBD: 0x0405, 0xBE: 0x0455, 0xBF: 0x0457,
    };

    final codes = List<int>.filled(bytes.length, 0);
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b < 0x80) {
        codes[i] = b;
      } else if (b >= 0xC0) {
        codes[i] = b + 0x350;
      } else {
        codes[i] = cp1251Extra[b] ?? 0x003F;
      }
    }
    return String.fromCharCodes(codes);
  }

  String _decodeBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return _decodeWindows1251(bytes);
    }
  }

  Future<void> _pickAndImportBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final lowerName = picked.name.toLowerCase();

    if (!lowerName.endsWith('.txt') && !lowerName.endsWith('.fb2')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выбери файл формата .txt или .fb2')),
      );
      return;
    }

    setState(() => _importing = true);

    try {
      List<int>? bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Не удалось прочитать файл');
      }

      final content = _decodeBytes(bytes);
      final bookId = DateTime.now().millisecondsSinceEpoch.toString();
      final parsed = BookParser.parse(
        bookId: bookId,
        fileName: picked.name,
        rawContent: content,
      );

      await BookDatabase.instance.insertBookWithChapters(
        parsed.book,
        parsed.chapters,
        parsed.paragraphs,
      );

      await _refreshBooks();

      if (!mounted) return;
      _openBook(parsed.book);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки книги: $e')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
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
    final translator = OpenAiCompatibleTranslator(
      endpoint: Uri.parse(_settings.endpointUrl),
      apiKey: _settings.apiKey,
      model: _settings.model,
    );

    final queue = TranslationQueueController(
      db: BookDatabase.instance,
      translator: translator,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          queueController: queue,
          targetLanguage: _settings.targetLanguage,
        ),
      ),
    );
  }

  Future<void> _confirmDeleteBook(Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить книгу?'),
        content: Text('«${book.title}» и весь её перевод будут удалены.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await BookDatabase.instance.deleteBook(book.id);
      await _refreshBooks();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мои книги'),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
            tooltip: 'Настройки переводчика',
          ),
          IconButton(
            onPressed: _refreshBooks,
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить список',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _pickAndImportBook,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_open),
        label: Text(_importing ? 'Импорт...' : 'Загрузить TXT / FB2'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Книг пока нет.\nНажми «Загрузить TXT / FB2», чтобы добавить книгу.',
                      textAlign: TextAlign.center,
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
                        leading: Icon(
                          book.format == 'fb2'
                              ? Icons.menu_book
                              : Icons.description,
                        ),
                        title: Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${book.format.toUpperCase()} • Глав: ${book.totalChapters}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Удалить',
                              onPressed: () => _confirmDeleteBook(book),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () => _openBook(book),
                      ),
                    );
                  },
                ),
    );
  }
}
