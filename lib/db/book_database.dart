import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/book_models.dart';

class SearchHit {
  final int chapterIndex;
  final String chapterTitle;
  final int orderIndex;
  final String snippet;

  const SearchHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.orderIndex,
    required this.snippet,
  });
}

class BookDatabase {
  static final BookDatabase instance = BookDatabase._();
  BookDatabase._();

  Database? _db;

  Future<String> getDatabaseFilePath() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, 'transreader_books.db');
  }

  Future<void> _ensureSchemaUpToDate(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS dictionary (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sourceText TEXT NOT NULL,
        translatedText TEXT NOT NULL,
        bookTitle TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bookId TEXT NOT NULL,
        chapterIndex INTEGER NOT NULL DEFAULT 0,
        chapterTitle TEXT NOT NULL DEFAULT '',
        pageIndex INTEGER NOT NULL DEFAULT 0,
        quoteText TEXT NOT NULL,
        noteText TEXT NOT NULL DEFAULT '',
        colorHex INTEGER NOT NULL DEFAULT 4294956367,
        createdAt INTEGER NOT NULL DEFAULT 0
      )
    ''');

    final bookColumns = await db.rawQuery('PRAGMA table_info(books)');
    final bookColNames = bookColumns.map((c) => c['name'].toString()).toSet();

    if (!bookColNames.contains('author')) {
      await db.execute(
        'ALTER TABLE books ADD COLUMN author TEXT NOT NULL DEFAULT ""',
      );
    }
    if (!bookColNames.contains('coverBase64')) {
      await db.execute(
        'ALTER TABLE books ADD COLUMN coverBase64 TEXT',
      );
    }
    if (!bookColNames.contains('lastChapterIndex')) {
      await db.execute(
        'ALTER TABLE books ADD COLUMN lastChapterIndex INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!bookColNames.contains('lastPageIndex')) {
      await db.execute(
        'ALTER TABLE books ADD COLUMN lastPageIndex INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!bookColNames.contains('lastScrollOffset')) {
      await db.execute(
        'ALTER TABLE books ADD COLUMN lastScrollOffset REAL NOT NULL DEFAULT 0.0',
      );
    }

    final paraColumns = await db.rawQuery('PRAGMA table_info(paragraphs)');
    final paraColNames = paraColumns.map((c) => c['name'].toString()).toSet();

    if (!paraColNames.contains('wordAlignJson')) {
      await db.execute(
        'ALTER TABLE paragraphs ADD COLUMN wordAlignJson TEXT',
      );
    }
  }

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    final path = await getDatabaseFilePath();
    _db = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE books (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            author TEXT NOT NULL DEFAULT '',
            format TEXT NOT NULL,
            coverBase64 TEXT,
            totalChapters INTEGER NOT NULL,
            lastChapterIndex INTEGER NOT NULL DEFAULT 0,
            lastPageIndex INTEGER NOT NULL DEFAULT 0,
            lastScrollOffset REAL NOT NULL DEFAULT 0.0
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
            translatedText TEXT,
            wordAlignJson TEXT
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_paragraphs_book_ch ON paragraphs (bookId, chapterIndex, orderIndex)',
        );

        await _ensureSchemaUpToDate(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _ensureSchemaUpToDate(db);
      },
      onOpen: (db) async {
        await _ensureSchemaUpToDate(db);
      },
    );
    return _db!;
  }

  Future<String?> exportBackup() async {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');

    final sourcePath = await getDatabaseFilePath();
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('Файл библиотеки ещё не создан');
    }

    final bytes = await sourceFile.readAsBytes();
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Сохранить резервную копию книг и словаря',
      fileName: 'TransReader_backup_$stamp.db',
      bytes: bytes,
    );

    return savedPath;
  }

  Future<bool> importBackup() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return false;

    final file = result.files.first;
    final bytes = file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);

    if (bytes == null || bytes.length < 16) {
      throw Exception('Выбран пустой или повреждённый файл');
    }

    final header = String.fromCharCodes(bytes.take(15));
    if (header != 'SQLite format 3') {
      throw Exception('Этот файл не является резервной копией TransReader (.db)');
    }

    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }

    final targetPath = await getDatabaseFilePath();
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('$targetPath$suffix');
      if (await f.exists()) {
        await f.delete();
      }
    }

    await File(targetPath).writeAsBytes(bytes, flush: true);
    await database;
    return true;
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

  Future<Book?> getBookById(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Book.fromMap(rows.first);
  }

  Future<void> updateBookReadingProgress({
    required String bookId,
    required int chapterIndex,
    required int pageIndex,
    required double scrollOffset,
  }) async {
    final db = await database;
    await db.update(
      'books',
      {
        'lastChapterIndex': chapterIndex,
        'lastPageIndex': pageIndex,
        'lastScrollOffset': scrollOffset,
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
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

  Future<List<SearchHit>> searchInBook(String bookId, String query) async {
    final clean = query.trim();
    if (clean.length < 2) return [];
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT p.chapterIndex, c.title AS chapterTitle, p.orderIndex, p.sourceText, p.translatedText
      FROM paragraphs p
      LEFT JOIN chapters c ON c.bookId = p.bookId AND c.chapterIndex = p.chapterIndex
      WHERE p.bookId = ? AND (p.sourceText LIKE ? OR p.translatedText LIKE ?)
      ORDER BY p.chapterIndex ASC, p.orderIndex ASC
      LIMIT 60
    ''', [bookId, '%$clean%', '%$clean%']);

    final lowerQ = clean.toLowerCase();
    return rows.map((r) {
      final tr = (r['translatedText'] as String?) ?? '';
      final src = (r['sourceText'] as String?) ?? '';
      final chosen = tr.toLowerCase().contains(lowerQ) ? tr : src;
      return SearchHit(
        chapterIndex: (r['chapterIndex'] as int?) ?? 0,
        chapterTitle: (r['chapterTitle'] as String?) ?? 'Глава',
        orderIndex: (r['orderIndex'] as int?) ?? 0,
        snippet: chosen,
      );
    }).toList();
  }

  Future<void> updateParagraphTranslation(
    int paragraphId,
    String translatedText, {
    Map<String, String> wordAlignMap = const {},
  }) async {
    final db = await database;
    await db.update(
      'paragraphs',
      {
        'translatedText': translatedText,
        'wordAlignJson': wordAlignMap.isEmpty ? null : jsonEncode(wordAlignMap),
      },
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

  Future<void> clearTranslationsForChapters(
    String bookId,
    List<int> chapterIndices,
  ) async {
    if (chapterIndices.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final chIdx in chapterIndices) {
        await txn.update(
          'paragraphs',
          {'translatedText': null, 'wordAlignJson': null},
          where: 'bookId = ? AND chapterIndex = ?',
          whereArgs: [bookId, chIdx],
        );
        await txn.update(
          'chapters',
          {'status': ChapterStatus.pending.index},
          where: 'bookId = ? AND chapterIndex = ?',
          whereArgs: [bookId, chIdx],
        );
      }
    });
  }

  Future<void> deleteBook(String bookId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('bookmarks', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('paragraphs', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('chapters', where: 'bookId = ?', whereArgs: [bookId]);
      await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
    });
  }

  Future<void> addBookmark(BookBookmark bookmark) async {
    final db = await database;
    await db.insert('bookmarks', bookmark.toMap());
  }

  Future<List<BookBookmark>> getBookmarksForBook(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'bookmarks',
      where: 'bookId = ?',
      whereArgs: [bookId],
      orderBy: 'chapterIndex ASC, pageIndex ASC, id DESC',
    );
    return rows.map((e) => BookBookmark.fromMap(e)).toList();
  }

  Future<void> deleteBookmark(int id) async {
    final db = await database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> addDictionaryEntry(DictionaryEntry entry) async {
    final db = await database;
    final cleanSource = entry.sourceText.trim();
    if (cleanSource.isEmpty) return;

    final existing = await db.query(
      'dictionary',
      where: 'LOWER(sourceText) = LOWER(?)',
      whereArgs: [cleanSource],
    );

    if (existing.isNotEmpty) {
      await db.update(
        'dictionary',
        {
          'translatedText': entry.translatedText.trim(),
          'bookTitle': entry.bookTitle,
          'createdAt': entry.createdAt,
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    } else {
      await db.insert('dictionary', entry.toMap());
    }
  }

  Future<List<DictionaryEntry>> getDictionaryEntries({String query = ''}) async {
    final db = await database;
    final clean = query.trim();
    final rows = clean.isEmpty
        ? await db.query('dictionary', orderBy: 'createdAt DESC, id DESC')
        : await db.query(
            'dictionary',
            where: 'sourceText LIKE ? OR translatedText LIKE ?',
            whereArgs: ['%$clean%', '%$clean%'],
            orderBy: 'createdAt DESC, id DESC',
          );
    return rows.map((e) => DictionaryEntry.fromMap(e)).toList();
  }

  Future<void> deleteDictionaryEntry(int id) async {
    final db = await database;
    await db.delete('dictionary', where: 'id = ?', whereArgs: [id]);
  }
}
