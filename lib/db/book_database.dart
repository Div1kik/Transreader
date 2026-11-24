import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/book_models.dart';

class BookDatabase {
  static final BookDatabase instance = BookDatabase._();
  BookDatabase._();

  Database? _db;

  Future<String> getDatabaseFilePath() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, 'transreader_books.db');
  }

  Future<void> _ensureDictionaryTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS dictionary (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sourceText TEXT NOT NULL,
        translatedText TEXT NOT NULL,
        bookTitle TEXT NOT NULL DEFAULT '',
        createdAt INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    final path = await getDatabaseFilePath();
    _db = await openDatabase(
      path,
      version: 2,
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

        await _ensureDictionaryTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _ensureDictionaryTable(db);
        }
      },
      onOpen: (db) async {
        // Гарантируем наличие таблицы словаря даже при восстановлении старого v1 бэкапа
        await _ensureDictionaryTable(db);
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

  // --- Методы личного словаря ---

  Future<void> addDictionaryEntry(DictionaryEntry entry) async {
    final db = await database;
    final cleanSource = entry.sourceText.trim();
    if (cleanSource.isEmpty) return;

    // Если слово уже есть — обновляем перевод и поднимаем наверх
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
    final List> rows;
    if (clean.isEmpty) {
      rows = await db.query('dictionary', orderBy: 'createdAt DESC, id DESC');
    } else {
      rows = await db.query(
        'dictionary',
        where: 'sourceText LIKE ? OR translatedText LIKE ?',
        whereArgs: ['%$clean%', '%$clean%'],
        orderBy: 'createdAt DESC, id DESC',
      );
    }
    return rows.map((e) => DictionaryEntry.fromMap(e)).toList();
  }

  Future<void> deleteDictionaryEntry(int id) async {
    final db = await database;
    await db.delete('dictionary', where: 'id = ?', whereArgs: [id]);
  }
}
