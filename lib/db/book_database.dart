import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/book_models.dart';

class BookDatabase {
  static final BookDatabase instance = BookDatabase._init();
  static Database? _database;

  BookDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'book_translator.db');
    _database = await openDatabase(path, version: 1, onCreate: _createDB);
    return _database!;
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE books (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        format TEXT NOT NULL,
        totalChapters INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE chapters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bookId TEXT NOT NULL,
        chapterIndex INTEGER NOT NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE paragraphs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bookId TEXT NOT NULL,
        chapterIndex INTEGER NOT NULL,
        orderIndex INTEGER NOT NULL,
        sourceText TEXT NOT NULL,
        translatedText TEXT
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_paragraphs_chapter ON paragraphs(bookId, chapterIndex, orderIndex)',
    );
  }

  Future<List<Book>> getBooks() async {
    final db = await instance.database;
    final rows = await db.query('books');
    return rows
        .map(
          (r) => Book(
            id: r['id'] as String,
            title: r['title'] as String,
            format: r['format'] as String,
            totalChapters: r['totalChapters'] as int,
          ),
        )
        .toList();
  }

  Future<void> deleteBook(String bookId) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.delete('paragraphs', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('chapters', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
    });
  }

  Future<void> insertBookWithChapters(
    Book book,
    List<Chapter> chapters,
    List<ParagraphItem> paragraphs,
  ) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.insert('books', {
        'id': book.id,
        'title': book.title,
        'format': book.format,
        'totalChapters': book.totalChapters,
      });

      for (final ch in chapters) {
        await txn.insert('chapters', {
          'bookId': ch.bookId,
          'chapterIndex': ch.index,
          'title': ch.title,
          'status': ch.status.name,
        });
      }

      final batch = txn.batch();
      for (final p in paragraphs) {
        batch.insert('paragraphs', {
          'bookId': p.bookId,
          'chapterIndex': p.chapterIndex,
          'orderIndex': p.orderIndex,
          'sourceText': p.sourceText,
          'translatedText': p.translatedText,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Chapter>> getChapters(String bookId) async {
    final db = await instance.database;
    final rows = await db.query(
      'chapters',
      where: 'bookId = ?',
      whereArgs: [bookId],
      orderBy: 'chapterIndex ASC',
    );
    return rows
        .map(
          (r) => Chapter(
            id: r['id'] as int,
            bookId: r['bookId'] as String,
            index: r['chapterIndex'] as int,
            title: r['title'] as String,
            status: ChapterStatus.values.byName(r['status'] as String),
          ),
        )
        .toList();
  }

  Future<void> updateChapterStatus(
    String bookId,
    int chapterIndex,
    ChapterStatus status,
  ) async {
    final db = await instance.database;
    await db.update(
      'chapters',
      {'status': status.name},
      where: 'bookId = ? AND chapterIndex = ?',
      whereArgs: [bookId, chapterIndex],
    );
  }

  Future<List<ParagraphItem>> getChapterParagraphs(
    String bookId,
    int chapterIndex,
  ) async {
    final db = await instance.database;
    final rows = await db.query(
      'paragraphs',
      where: 'bookId = ? AND chapterIndex = ?',
      whereArgs: [bookId, chapterIndex],
      orderBy: 'orderIndex ASC',
    );
    return rows
        .map(
          (r) => ParagraphItem(
            id: r['id'] as int,
            bookId: r['bookId'] as String,
            chapterIndex: r['chapterIndex'] as int,
            orderIndex: r['orderIndex'] as int,
            sourceText: r['sourceText'] as String,
            translatedText: r['translatedText'] as String?,
          ),
        )
        .toList();
  }

  Future<void> saveParagraphTranslation(int id, String translatedText) async {
    final db = await instance.database;
    await db.update(
      'paragraphs',
      {'translatedText': translatedText},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
