import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderColorTheme {
  warmDark,
  sepia,
  paperWhite,
  amoledBlack,
}

enum ReaderPageMode {
  scroll,
  pageSlide,
  pageCurl,
}

enum ReaderTextDisplay {
  translationOnly,
  bilingual,
  originalOnly,
}

enum ReaderFontFamily {
  system,
  serif,
  monospace,
}

class ReaderPalette {
  final String name;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color text;
  final Color secondaryText;
  final Color accent;

  const ReaderPalette({
    required this.name,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.text,
    required this.secondaryText,
    required this.accent,
  });

  static ReaderPalette of(ReaderColorTheme theme) {
    switch (theme) {
      case ReaderColorTheme.warmDark:
        return const ReaderPalette(
          name: 'Ночь',
          brightness: Brightness.dark,
          background: Color(0xFF14110F),
          surface: Color(0xFF211C18),
          text: Color(0xFFEBE3D5),
          secondaryText: Color(0xFFA89E93),
          accent: Color(0xFFD98A3C),
        );
      case ReaderColorTheme.sepia:
        return const ReaderPalette(
          name: 'Сепия',
          brightness: Brightness.light,
          background: Color(0xFFF4ECD8),
          surface: Color(0xFFE9DEC4),
          text: Color(0xFF33291E),
          secondaryText: Color(0xFF6E5D4A),
          accent: Color(0xFF8C4A19),
        );
      case ReaderColorTheme.paperWhite:
        return const ReaderPalette(
          name: 'Бумага',
          brightness: Brightness.light,
          background: Color(0xFFFAF9F5),
          surface: Color(0xFFEEECE6),
          text: Color(0xFF1E1E1E),
          secondaryText: Color(0xFF666666),
          accent: Color(0xFF2B6CB0),
        );
      case ReaderColorTheme.amoledBlack:
        return const ReaderPalette(
          name: 'AMOLED',
          brightness: Brightness.dark,
          background: Color(0xFF000000),
          surface: Color(0xFF121212),
          text: Color(0xFFD8D8D8),
          secondaryText: Color(0xFF888888),
          accent: Color(0xFFD98A3C),
        );
    }
  }
}

class ReaderAppearance {
  final double fontSize;
  final double lineHeight;
  final double horizontalMargin;
  final bool justifyText;
  final bool paragraphIndent;
  final double blueLightFilter;
  final bool volumeButtonsTurnPages;
  final ReaderFontFamily fontFamily;
  final ReaderColorTheme colorTheme;
  final ReaderPageMode pageMode;
  final ReaderTextDisplay textDisplay;

  const ReaderAppearance({
    this.fontSize = 18.0,
    this.lineHeight = 1.55,
    this.horizontalMargin = 20.0,
    this.justifyText = true,
    this.paragraphIndent = true,
    this.blueLightFilter = 0.0,
    this.volumeButtonsTurnPages = true,
    this.fontFamily = ReaderFontFamily.serif,
    this.colorTheme = ReaderColorTheme.sepia,
    this.pageMode = ReaderPageMode.pageCurl,
    this.textDisplay = ReaderTextDisplay.bilingual,
  });

  bool get showOriginal => textDisplay == ReaderTextDisplay.bilingual;
  bool get isOriginalOnly => textDisplay == ReaderTextDisplay.originalOnly;

  String? get flutterFontFamily {
    switch (fontFamily) {
      case ReaderFontFamily.system:
        return null;
      case ReaderFontFamily.serif:
        return 'serif';
      case ReaderFontFamily.monospace:
        return 'monospace';
    }
  }

  TextAlign get textAlign =>
      justifyText ? TextAlign.justify : TextAlign.left;

  ReaderAppearance copyWith({
    double? fontSize,
    double? lineHeight,
    double? horizontalMargin,
    bool? justifyText,
    bool? paragraphIndent,
    double? blueLightFilter,
    bool? volumeButtonsTurnPages,
    ReaderFontFamily? fontFamily,
    ReaderColorTheme? colorTheme,
    ReaderPageMode? pageMode,
    ReaderTextDisplay? textDisplay,
  }) {
    return ReaderAppearance(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      horizontalMargin: horizontalMargin ?? this.horizontalMargin,
      justifyText: justifyText ?? this.justifyText,
      paragraphIndent: paragraphIndent ?? this.paragraphIndent,
      blueLightFilter: blueLightFilter ?? this.blueLightFilter,
      volumeButtonsTurnPages:
          volumeButtonsTurnPages ?? this.volumeButtonsTurnPages,
      fontFamily: fontFamily ?? this.fontFamily,
      colorTheme: colorTheme ?? this.colorTheme,
      pageMode: pageMode ?? this.pageMode,
      textDisplay: textDisplay ?? this.textDisplay,
    );
  }

  static const _kFontSize = 'reader_font_size';
  static const _kLineHeight = 'reader_line_height';
  static const _kHorizontalMargin = 'reader_h_margin';
  static const _kJustifyText = 'reader_justify_text';
  static const _kParagraphIndent = 'reader_para_indent';
  static const _kBlueLight = 'reader_blue_light';
  static const _kVolumeTurn = 'reader_volume_turn';
  static const _kFontFamily = 'reader_font_family';
  static const _kTheme = 'reader_color_theme';
  static const _kPageMode = 'reader_page_mode';
  static const _kTextDisplay = 'reader_text_display';
  static const _kLegacyShowOriginal = 'reader_show_original';

  static Future<ReaderAppearance> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIdx = prefs.getInt(_kTheme) ?? ReaderColorTheme.sepia.index;
    final modeIdx = prefs.getInt(_kPageMode) ?? ReaderPageMode.pageCurl.index;
    final fontIdx =
        prefs.getInt(_kFontFamily) ?? ReaderFontFamily.serif.index;

    int displayIdx;
    if (prefs.containsKey(_kTextDisplay)) {
      displayIdx =
          prefs.getInt(_kTextDisplay) ?? ReaderTextDisplay.bilingual.index;
    } else {
      final oldShowOrig = prefs.getBool(_kLegacyShowOriginal) ?? true;
      displayIdx = oldShowOrig
          ? ReaderTextDisplay.bilingual.index
          : ReaderTextDisplay.translationOnly.index;
    }

    return ReaderAppearance(
      fontSize: prefs.getDouble(_kFontSize) ?? 18.0,
      lineHeight: prefs.getDouble(_kLineHeight) ?? 1.55,
      horizontalMargin: prefs.getDouble(_kHorizontalMargin) ?? 20.0,
      justifyText: prefs.getBool(_kJustifyText) ?? true,
      paragraphIndent: prefs.getBool(_kParagraphIndent) ?? true,
      blueLightFilter: prefs.getDouble(_kBlueLight) ?? 0.0,
      volumeButtonsTurnPages: prefs.getBool(_kVolumeTurn) ?? true,
      fontFamily: ReaderFontFamily
          .values[fontIdx.clamp(0, ReaderFontFamily.values.length - 1)],
      colorTheme: ReaderColorTheme
          .values[themeIdx.clamp(0, ReaderColorTheme.values.length - 1)],
      pageMode: ReaderPageMode
          .values[modeIdx.clamp(0, ReaderPageMode.values.length - 1)],
      textDisplay: ReaderTextDisplay
          .values[displayIdx.clamp(0, ReaderTextDisplay.values.length - 1)],
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontSize, fontSize);
    await prefs.setDouble(_kLineHeight, lineHeight);
    await prefs.setDouble(_kHorizontalMargin, horizontalMargin);
    await prefs.setBool(_kJustifyText, justifyText);
    await prefs.setBool(_kParagraphIndent, paragraphIndent);
    await prefs.setDouble(_kBlueLight, blueLightFilter);
    await prefs.setBool(_kVolumeTurn, volumeButtonsTurnPages);
    await prefs.setInt(_kFontFamily, fontFamily.index);
    await prefs.setInt(_kTheme, colorTheme.index);
    await prefs.setInt(_kPageMode, pageMode.index);
    await prefs.setInt(_kTextDisplay, textDisplay.index);
  }
}
