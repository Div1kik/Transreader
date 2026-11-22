import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'db/book_database.dart';
import 'models/book_models.dart';
import 'services/book_parser.dart';
import 'services/translation_queue.dart';
import 'services/translator_service.dart';
import 'screens/reader_screen.dart';

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
  List<Book> _books = [];
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() => _loading = true);
    final books = await BookDatabase.instance.getBooks();
    if (!mounted) return;
    setState(() {
      _books = books;
      _loading = false;
    });
  }

  String _decodeBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // Фолбэк для однобайтовых кодировок (например, Windows-1251)
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  Future<void> _pickAndImportBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'fb2'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;

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

      await _loadBooks();

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

  void _openBook(Book book) {
    // Подставь свой рабочий endpoint, ключ и модель перед сборкой
    final translator = OpenAiCompatibleTranslator(
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
      apiKey: 'YOUR_API_KEY',
      model: 'gpt-4o-mini',
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мои книги'),
        actions: [
          IconButton(
            onPressed: _loadBooks,
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
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openBook(book),
                      ),
                    );
                  },
                ),
    );
  }
}
