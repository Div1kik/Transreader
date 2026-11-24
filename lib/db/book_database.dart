import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/book_models.dart';

class BookDatabase {
  static final BookDatabase instance = BookDatabase._();
  BookDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'transreader_books.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
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
            bookId TEXT NOT NULL,
            chapterIndex INTEGER NOT NULL,
            title TEXT NOT NULL,
            status INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (bookId, chapterIndex)
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
          'CREATE INDEX idx_paragraphs_book_ch ON paragraphs (bookId, chapterIndex, orderIndex)',
        );
      },
    );
    return _db!;
  }

  Future<void> insertBookWithChapters(
    Book book,
    List<Chapter> chapters,
    List<ParagraphItem> paragraphs,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('books', book.toMap());
      for (final ch in chapters) {
        await txn.insert('chapters', ch.toMap());
      }
      final batch = txn.batch();
      for (final p in paragraphs) {
        batch.insert('paragraphs', p.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Book>> getBooks() async {
    final db = await database;
    final rows = await db.query('books', orderBy: 'rowid DESC');
    return rows.map((e) => Book.fromMap(e)).toList();
  }

  Future<List<Chapter>> getChapters(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'chapters',
      where: 'bookId = ?',
      whereArgs: [bookId],
      orderBy: 'chapterIndex ASC',
    );
    return rows.map((e) => Chapter.fromMap(e)).toList();
  }

  Future<List<ParagraphItem>> getChapterParagraphs(
    String bookId,
    int chapterIndex,
  ) async {
    final db = await database;
    final rows = await db.query(
      'paragraphs',
      where: 'bookId = ? AND chapterIndex = ?',
      whereArgs: [bookId, chapterIndex],
      orderBy: 'orderIndex ASC',
    );
    return rows.map((e) => ParagraphItem.fromMap(e)).toList();
  }

  Future<void> updateParagraphTranslation(
    int paragraphId,
    String translatedText,
  ) async {
    final db = await database;
    await db.update(
      'paragraphs',
      {'translatedText': translatedText},
      where: 'id = ?',
      whereArgs: [paragraphId],
    );
  }

  Future<void> updateChapterStatus(
    String bookId,
    int chapterIndex,
    ChapterStatus status,
  ) async {
    final db = await database;
    await db.update(
      'chapters',
      {'status': status.index},
      where: 'bookId = ? AND chapterIndex = ?',
      whereArgs: [bookId, chapterIndex],
    );
  }

  Future<void> deleteBook(String bookId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('paragraphs', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('chapters', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
    });
  }
}
