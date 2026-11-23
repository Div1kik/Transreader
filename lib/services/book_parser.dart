import 'package:xml/xml.dart';
import '../models/book_models.dart';

class ParsedBookData {
  final Book book;
  final List<Chapter> chapters;
  final List<ParagraphItem> paragraphs;

  ParsedBookData({
    required this.book,
    required this.chapters,
    required this.paragraphs,
  });
}

class BookParser {
  static ParsedBookData parse({
    required String bookId,
    required String fileName,
    required String rawContent,
  }) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.fb2') || rawContent.contains('<FictionBook')) {
      return _parseFb2(
        bookId: bookId,
        fileName: fileName,
        xmlContent: rawContent,
      );
    }
    return _parseTxt(
      bookId: bookId,
      fileName: fileName,
      textContent: rawContent,
    );
  }

  static ParsedBookData _parseFb2({
    required String bookId,
    required String fileName,
    required String xmlContent,
  }) {
    final doc = XmlDocument.parse(xmlContent);
    final bookTitleEl = doc.findAllElements('book-title').firstOrNull;
    final cleanFileName =
        fileName.replaceAll(RegExp(r'\.fb2$', caseSensitive: false), '');
    final title = bookTitleEl?.innerText.trim().isNotEmpty == true
        ? bookTitleEl!.innerText.trim()
        : cleanFileName;

    final body = doc.findAllElements('body').firstOrNull;
    final allSections = body?.findAllElements('section').toList() ?? [];
    final leafSections = allSections
        .where((sec) => sec.findElements('section').isEmpty)
        .toList();
    final targetSections =
        leafSections.isNotEmpty ? leafSections : allSections;

    final chapters = <Chapter>[];
    final paragraphs = <ParagraphItem>[];

    int chapterIdx = 0;
    for (final sec in targetSections) {
      final pElements = sec.findElements('p').toList();
      if (pElements.isEmpty) continue;

      final secTitle = sec
              .findElements('title')
              .firstOrNull
              ?.innerText
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim() ??
          '';
      final chapterTitle =
          secTitle.isNotEmpty ? secTitle : 'Глава ${chapterIdx + 1}';

      chapters.add(
        Chapter(
          bookId: bookId,
          index: chapterIdx,
          title: chapterTitle,
        ),
      );

      int order = 0;
      for (final p in pElements) {
        final text = p.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty) continue;
        paragraphs.add(
          ParagraphItem(
            bookId: bookId,
            chapterIndex: chapterIdx,
            orderIndex: order++,
            sourceText: text,
          ),
        );
      }
      chapterIdx++;
    }

    if (chapters.isEmpty) {
      return _parseTxt(
        bookId: bookId,
        fileName: title,
        textContent: doc.rootElement.innerText,
      );
    }

    return ParsedBookData(
      book: Book(
        id: bookId,
        title: title,
        format: 'fb2',
        totalChapters: chapters.length,
      ),
      chapters: chapters,
      paragraphs: paragraphs,
    );
  }

  static ParsedBookData _parseTxt({
    required String bookId,
    required String fileName,
    required String textContent,
  }) {
    final normalized =
        textContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rawBlocks = normalized
        .split(RegExp(r'\n\s*\n+'))
        .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final chapterHeaderRegex = RegExp(
      r'^(chapter|глава|часть|part)\s+(\d+|[ivxlcdm]+)\b.*',
      caseSensitive: false,
    );

    final chapters = <Chapter>[];
    final paragraphs = <ParagraphItem>[];

    List<String> currentChapterLines = [];
    String currentChapterTitle = 'Глава 1';

    void flushChapter() {
      if (currentChapterLines.isEmpty) return;
      final chIndex = chapters.length;
      chapters.add(
        Chapter(bookId: bookId, index: chIndex, title: currentChapterTitle),
      );
      for (int i = 0; i < currentChapterLines.length; i++) {
        paragraphs.add(
          ParagraphItem(
            bookId: bookId,
            chapterIndex: chIndex,
            orderIndex: i,
            sourceText: currentChapterLines[i],
          ),
        );
      }
      currentChapterLines = [];
    }

    for (final block in rawBlocks) {
      if (chapterHeaderRegex.hasMatch(block) && block.length < 100) {
        flushChapter();
        currentChapterTitle = block;
      } else {
        currentChapterLines.add(block);
        if (currentChapterLines.length >= 120) {
          flushChapter();
          currentChapterTitle = 'Часть ${chapters.length + 1}';
        }
      }
    }
    flushChapter();

    return ParsedBookData(
      book: Book(
        id: bookId,
        title: fileName,
        format: 'txt',
        totalChapters: chapters.length,
      ),
      chapters: chapters,
      paragraphs: paragraphs,
    );
  }
}
