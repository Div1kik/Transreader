import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import '../models/book_models.dart';

class ParsedBookBundle {
  final Book book;
  final List<Chapter> chapters;
  final List<ParagraphItem> paragraphs;

  const ParsedBookBundle({
    required this.book,
    required this.chapters,
    required this.paragraphs,
  });
}

class BookParser {
  static Future<ParsedBookBundle> parseFromBytes({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final lowerName = fileName.toLowerCase();
    final bookId = DateTime.now().microsecondsSinceEpoch.toString();

    if (lowerName.endsWith('.epub')) {
      return _parseEpub(bytes, fileName, bookId);
    }

    final rawString = _decodeBytesSmart(bytes);

    if (lowerName.endsWith('.fb2') ||
        rawString.contains('<FictionBook')) {
      return _parseFb2(rawString, fileName, bookId);
    } else {
      return _parseTxt(rawString, fileName, bookId);
    }
  }

  static Future<ParsedBookBundle> parseFile(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final fileName = file.uri.pathSegments.last;
    return parseFromBytes(bytes: bytes, fileName: fileName);
  }

  static String _decodeBytesSmart(Uint8List bytes) {
    final headLimit = bytes.length < 400 ? bytes.length : 400;
    final headAscii = latin1.decode(bytes.sublist(0, headLimit)).toLowerCase();
    if (headAscii.contains('windows-1251') || headAscii.contains('cp1251')) {
      return _decodeWindows1251(bytes);
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return _decodeWindows1251(bytes);
    }
  }

  static String _decodeWindows1251(Uint8List bytes) {
    const cp1251High = <int>[
      0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
      0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
      0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
      0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
      0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
      0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
      0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ];

    final buffer = StringBuffer();
    for (final b in bytes) {
      if (b < 0x80) {
        buffer.writeCharCode(b);
      } else if (b < 0xC0) {
        buffer.writeCharCode(cp1251High[b - 0x80]);
      } else {
        buffer.writeCharCode(0x0410 + (b - 0xC0));
      }
    }
    return buffer.toString();
  }

  /// Полноценный парсер EPUB (извлекает название, автора, обложку и главы из OPF/spine)
  static ParsedBookBundle _parseEpub(
    Uint8List bytes,
    String fileName,
    String bookId,
  ) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final fileMap = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (f.isFile) {
        fileMap[f.name] = f;
      }
    }

    String title = fileName.replaceAll(
      RegExp(r'\.epub$', caseSensitive: false),
      '',
    );
    String author = '';
    String? coverBase64;
    final chapters = <Chapter>[];
    final paragraphs = <ParagraphItem>[];

    // 1. Ищем путь к content.opf через META-INF/container.xml
    String? opfPath;
    final containerFile = fileMap['META-INF/container.xml'];
    if (containerFile != null) {
      try {
        final containerXml =
            XmlDocument.parse(utf8.decode(containerFile.content as List<int>));
        final rootFileEl = containerXml.findAllElements('rootfile').firstOrNull;
        opfPath = rootFileEl?.getAttribute('full-path');
      } catch (_) {}
    }

    opfPath ??= fileMap.keys
        .where((k) => k.toLowerCase().endsWith('.opf'))
        .firstOrNull;

    final spineHrefs = <String>[];
    String baseDir = '';

    if (opfPath != null && fileMap.containsKey(opfPath)) {
      final lastSlash = opfPath.lastIndexOf('/');
      baseDir = lastSlash >= 0 ? opfPath.substring(0, lastSlash + 1) : '';

      try {
        final opfXml = XmlDocument.parse(
          utf8.decode(fileMap[opfPath]!.content as List<int>),
        );

        final dcTitle = opfXml
            .findAllElements('*')
            .where((e) => e.name.local == 'title')
            .firstOrNull
            ?.innerText
            .trim();
        if (dcTitle != null && dcTitle.isNotEmpty) {
          title = dcTitle;
        }

        final dcCreator = opfXml
            .findAllElements('*')
            .where((e) => e.name.local == 'creator')
            .firstOrNull
            ?.innerText
            .trim();
        if (dcCreator != null && dcCreator.isNotEmpty) {
          author = dcCreator;
        }

        final manifestMap = <String, String>{};
        String? coverHref;
        String? coverId;

        for (final meta in opfXml.findAllElements('*').where((e) => e.name.local == 'meta')) {
          if (meta.getAttribute('name') == 'cover') {
            coverId = meta.getAttribute('content');
          }
        }

        for (final item in opfXml.findAllElements('*').where((e) => e.name.local == 'item')) {
          final id = item.getAttribute('id') ?? '';
          final href = item.getAttribute('href') ?? '';
          final props = item.getAttribute('properties') ?? '';
          if (id.isNotEmpty && href.isNotEmpty) {
            manifestMap[id] = Uri.decodeFull(href);
          }
          if (props.contains('cover-image') ||
              (coverId != null && id == coverId) ||
              id.toLowerCase().contains('cover') &&
                  (href.endsWith('.jpg') ||
                      href.endsWith('.jpeg') ||
                      href.endsWith('.png'))) {
            coverHref ??= Uri.decodeFull(href);
          }
        }

        if (coverHref != null) {
          final fullCoverPath = '$baseDir$coverHref';
          final coverFile = fileMap[fullCoverPath] ?? fileMap[coverHref];
          if (coverFile != null) {
            final rawCoverBytes = coverFile.content as List<int>;
            if (rawCoverBytes.length < 1500000) {
              coverBase64 = base64Encode(rawCoverBytes);
            }
          }
        }

        for (final itemref
            in opfXml.findAllElements('*').where((e) => e.name.local == 'itemref')) {
          final idref = itemref.getAttribute('idref');
          if (idref != null && manifestMap.containsKey(idref)) {
            spineHrefs.add('$baseDir${manifestMap[idref]}');
          }
        }
      } catch (_) {}
    }

    if (spineHrefs.isEmpty) {
      spineHrefs.addAll(
        fileMap.keys
            .where((k) =>
                k.toLowerCase().endsWith('.xhtml') ||
                k.toLowerCase().endsWith('.html'))
            .toList()
          ..sort(),
      );
    }

    int chIdx = 0;
    for (final href in spineHrefs) {
      final htmlFile = fileMap[href];
      if (htmlFile == null) continue;
      final lowerHref = href.toLowerCase();
      if (lowerHref.contains('nav.') ||
          lowerHref.contains('toc.') ||
          lowerHref.contains('cover.')) {
        continue;
      }

      try {
        final htmlStr = utf8.decode(
          htmlFile.content as List<int>,
          allowMalformed: true,
        );
        final doc = XmlDocument.parse(htmlStr);
        final headingEl = doc
            .findAllElements('*')
            .where((e) =>
                e.name.local == 'h1' ||
                e.name.local == 'h2' ||
                e.name.local == 'h3')
            .firstOrNull;
        String chTitle = headingEl?.innerText.replaceAll(RegExp(r'\s+'), ' ').trim() ??
            'Глава ${chIdx + 1}';
        if (chTitle.isEmpty) chTitle = 'Глава ${chIdx + 1}';

        final pNodes = doc
            .findAllElements('*')
            .where((e) => e.name.local == 'p' || e.name.local == 'div')
            .toList();

        final chParagraphs = <String>[];
        for (final node in pNodes) {
          if (node.name.local == 'div' &&
              node.findElements('*').any((c) => c.name.local == 'p')) {
            continue;
          }
          final txt = node.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (txt.isNotEmpty && txt != chTitle) {
            chParagraphs.add(txt);
          }
        }

        if (chParagraphs.isEmpty) continue;

        chapters.add(
          Chapter(
            bookId: bookId,
            index: chIdx,
            title: chTitle,
            status: ChapterStatus.pending,
          ),
        );

        for (int i = 0; i < chParagraphs.length; i++) {
          paragraphs.add(
            ParagraphItem(
              bookId: bookId,
              chapterIndex: chIdx,
              orderIndex: i,
              sourceText: chParagraphs[i],
            ),
          );
        }
        chIdx++;
      } catch (_) {}
    }

    if (chapters.isEmpty) {
      return _parseTxt(
        'Не удалось извлечь главы из EPUB-файла.',
        fileName,
        bookId,
      );
    }

    return ParsedBookBundle(
      book: Book(
        id: bookId,
        title: title,
        author: author,
        format: 'EPUB',
        coverBase64: coverBase64,
        totalChapters: chapters.length,
      ),
      chapters: chapters,
      paragraphs: paragraphs,
    );
  }

  static ParsedBookBundle _parseFb2(
    String xmlContent,
    String fileName,
    String bookId,
  ) {
    final document = XmlDocument.parse(xmlContent);

    final titleElement = document.findAllElements('book-title').firstOrNull;
    final bookTitle = (titleElement != null && titleElement.innerText.trim().isNotEmpty)
        ? titleElement.innerText.trim()
        : fileName.replaceAll(RegExp(r'\.fb2$', caseSensitive: false), '');

    String author = '';
    final authorEl = document.findAllElements('author').firstOrNull;
    if (authorEl != null) {
      final first = authorEl.findElements('first-name').firstOrNull?.innerText.trim() ?? '';
      final last = authorEl.findElements('last-name').firstOrNull?.innerText.trim() ?? '';
      author = '$first $last'.trim();
    }

    // Извлекаем обложку из <binary id="cover.jpg">
    String? coverBase64;
    final coverImgEl = document.findAllElements('coverpage').firstOrNull?.findAllElements('image').firstOrNull;
    String? targetBinaryId;
    if (coverImgEl != null) {
      for (final attr in coverImgEl.attributes) {
        if (attr.name.local == 'href') {
          targetBinaryId = attr.value.replaceFirst('#', '');
          break;
        }
      }
    }

    for (final bin in document.findAllElements('binary')) {
      final id = bin.getAttribute('id') ?? '';
      final contentType = bin.getAttribute('content-type') ?? '';
      if ((targetBinaryId != null && id == targetBinaryId) ||
          (targetBinaryId == null && contentType.startsWith('image/'))) {
        final cleanedB64 = bin.innerText.replaceAll(RegExp(r'\s+'), '');
        if (cleanedB64.isNotEmpty && cleanedB64.length < 2000000) {
          coverBase64 = cleanedB64;
          break;
        }
      }
    }

    final chapters = <Chapter>[];
    final paragraphs = <ParagraphItem>[];

    final body = document.findAllElements('body').firstOrNull;
    if (body == null) {
      return _parseTxt(xmlContent, fileName, bookId);
    }

    final leafSections = body
        .findAllElements('section')
        .where((s) => s.findElements('section').isEmpty)
        .toList();

    if (leafSections.isEmpty) {
      final allParagraphs = body
          .findAllElements('p')
          .map((e) => e.innerText.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      return _buildChunkedFromParagraphs(
        allParagraphs,
        bookTitle,
        'FB2',
        bookId,
        author: author,
        coverBase64: coverBase64,
      );
    }

    int chapterIdx = 0;
    for (final section in leafSections) {
      final sectionTitleEl = section.findElements('title').firstOrNull;
      String chapterTitle = sectionTitleEl != null
          ? sectionTitleEl.innerText.replaceAll(RegExp(r'\s+'), ' ').trim()
          : 'Глава ${chapterIdx + 1}';

      if (chapterTitle.isEmpty) {
        chapterTitle = 'Глава ${chapterIdx + 1}';
      }

      final pElements = section.findAllElements('p').where((p) {
        return !p.ancestors.any((anc) =>
            anc is XmlElement &&
            anc.name.local == 'title' &&
            anc.parent == section);
      }).toList();

      final chapterParagraphTexts = <String>[];
      for (final p in pElements) {
        final text = p.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isNotEmpty) {
          chapterParagraphTexts.add(text);
        }
      }

      if (chapterParagraphTexts.isEmpty) continue;

      chapters.add(
        Chapter(
          bookId: bookId,
          index: chapterIdx,
          title: chapterTitle,
          status: ChapterStatus.pending,
        ),
      );

      for (int i = 0; i < chapterParagraphTexts.length; i++) {
        paragraphs.add(
          ParagraphItem(
            bookId: bookId,
            chapterIndex: chapterIdx,
            orderIndex: i,
            sourceText: chapterParagraphTexts[i],
          ),
        );
      }
      chapterIdx++;
    }

    if (chapters.isEmpty) {
      return _parseTxt(xmlContent, fileName, bookId);
    }

    return ParsedBookBundle(
      book: Book(
        id: bookId,
        title: bookTitle,
        author: author,
        format: 'FB2',
        coverBase64: coverBase64,
        totalChapters: chapters.length,
      ),
      chapters: chapters,
      paragraphs: paragraphs,
    );
  }

  static ParsedBookBundle _parseTxt(
    String content,
    String fileName,
    String bookId,
  ) {
    final cleanTitle =
        fileName.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');
    final lines = content.split(RegExp(r'\r?\n'));

    final chapterRegex = RegExp(
      r'^(Глава\s+\d+|ГЛАВА\s+\d+|Chapter\s+\d+|CHAPTER\s+\d+|Part\s+\d+|Часть\s+\d+)\b.*$',
      caseSensitive: false,
    );

    final chapters = <Chapter>[];
    final paragraphs = <ParagraphItem>[];

    String currentTitle = 'Глава 1';
    List<String> currentBuffer = [];
    int chapterIdx = 0;

    void flushChapter() {
      if (currentBuffer.isEmpty) return;
      chapters.add(
        Chapter(
          bookId: bookId,
          index: chapterIdx,
          title: currentTitle,
          status: ChapterStatus.pending,
        ),
      );
      for (int i = 0; i < currentBuffer.length; i++) {
        paragraphs.add(
          ParagraphItem(
            bookId: bookId,
            chapterIndex: chapterIdx,
            orderIndex: i,
            sourceText: currentBuffer[i],
          ),
        );
      }
      chapterIdx++;
      currentBuffer = [];
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (chapterRegex.hasMatch(line) && line.length < 90) {
        flushChapter();
        currentTitle = line;
      } else {
        currentBuffer.add(line);
      }
    }
    flushChapter();

    if (chapters.length <= 1 && paragraphs.length > 60) {
      final allTexts = paragraphs.map((p) => p.sourceText).toList();
      return _buildChunkedFromParagraphs(allTexts, cleanTitle, 'TXT', bookId);
    }

    if (chapters.isEmpty) {
      chapters.add(
        Chapter(
          bookId: bookId,
          index: 0,
          title: 'Глава 1',
          status: ChapterStatus.pending,
        ),
      );
      paragraphs.add(
        ParagraphItem(
          bookId: bookId,
          chapterIndex: 0,
          orderIndex: 0,
          sourceText: content.trim().isEmpty ? 'Пустой файл' : content.trim(),
        ),
      );
    }

    return ParsedBookBundle(
      book: Book(
        id: bookId,
        title: cleanTitle,
        format: 'TXT',
        totalChapters: chapters.length,
      ),
      chapters: chapters,
      paragraphs: paragraphs,
    );
  }

  static ParsedBookBundle _buildChunkedFromParagraphs(
    List<String> allTexts,
    String bookTitle,
    String format,
    String bookId, {
    String author = '',
    String? coverBase64,
  }) {
    const chunkSize = 40;
    final chapters = <Chapter>[];
    final paragraphs = <ParagraphItem>[];

    int chapterIdx = 0;
    for (int i = 0; i < allTexts.length; i += chunkSize) {
      final end = (i + chunkSize < allTexts.length) ? i + chunkSize : allTexts.length;
      final slice = allTexts.sublist(i, end);

      chapters.add(
        Chapter(
          bookId: bookId,
          index: chapterIdx,
          title: 'Часть ${chapterIdx + 1}',
          status: ChapterStatus.pending,
        ),
      );

      for (int j = 0; j < slice.length; j++) {
        paragraphs.add(
          ParagraphItem(
            bookId: bookId,
            chapterIndex: chapterIdx,
            orderIndex: j,
            sourceText: slice[j],
          ),
        );
      }
      chapterIdx++;
    }

    return ParsedBookBundle(
      book: Book(
        id: bookId,
        title: bookTitle,
        author: author,
        format: format,
        coverBase64: coverBase64,
        totalChapters: chapters.length,
      ),
      chapters: chapters,
      paragraphs: paragraphs,
    );
  }
}
