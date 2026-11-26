import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../db/book_database.dart';
import '../services/offline_translator_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final TranslatorSettings initialSettings;

  const SettingsScreen({
    super.key,
    required this.initialSettings,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final SettingsService _settingsService = SettingsService();
  late TranslationEngineMode _engineMode;
  late List<ApiProviderProfile> _providers;
  late bool _fallbackToOfflineOnError;
  late TextEditingController _langController;

  bool _downloadingOfflineModel = false;
  String? _offlineStatusStep;
  bool _offlineModelReady = false;
  bool _backupBusy = false;
  bool _waitingForGroqKey = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engineMode = widget.initialSettings.engineMode;
    _providers = List<ApiProviderProfile>.from(
      widget.initialSettings.effectiveProviders,
    );
    _fallbackToOfflineOnError =
        widget.initialSettings.fallbackToOfflineOnError;
    _langController =
        TextEditingController(text: widget.initialSettings.targetLanguage);

    _checkOfflineModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForGroqKey) {
      _waitingForGroqKey = false;
      _tryPasteGroqKeyFromClipboard(silentIfNotFound: true);
    }
  }

  Future<void> _openGroqKeysPage() async {
    _waitingForGroqKey = true;
    final uri = Uri.parse('https://console.groq.com/keys');
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.inAppBrowserView,
    );
    if (!launched && mounted) {
      _waitingForGroqKey = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть console.groq.com')),
      );
    }
  }

  Future<void> _tryPasteGroqKeyFromClipboard({
    bool silentIfNotFound = false,
  }) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final clipText = data?.text?.trim() ?? '';

    if (clipText.startsWith('gsk_') && clipText.length > 20) {
      if (!mounted) return;
      setState(() {
        _engineMode = TranslationEngineMode.groqCloud;
        final existingIdx = _providers.indexWhere(
          (p) => p.endpointUrl.contains('groq.com'),
        );
        final updatedGroq = ApiProviderProfile(
          id: existingIdx >= 0
              ? _providers[existingIdx].id
              : 'groq_${DateTime.now().millisecondsSinceEpoch}',
          name: 'Groq Free',
          endpointUrl: 'https://api.groq.com/openai/v1/chat/completions',
          apiKey: clipText,
          models: existingIdx >= 0 && _providers[existingIdx].models.isNotEmpty
              ? _providers[existingIdx].models
              : const [
                  'llama-3.3-70b-versatile',
                  'openai/gpt-oss-120b',
                  'openai/gpt-oss-20b',
                  'meta-llama/llama-4-scout-17b-16e-instruct',
                ],
          enabled: true,
        );

        if (existingIdx >= 0) {
          _providers[existingIdx] = updatedGroq;
        } else {
          _providers.insert(0, updatedGroq);
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ключ Groq (gsk_...) подхвачен и сохранён!'),
        ),
      );
      await _save();
    } else if (!silentIfNotFound && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'В буфере обмена пока нет ключа Groq (должен начинаться с gsk_)',
          ),
        ),
      );
    }
  }

  void _openProviderEditor({ApiProviderProfile? existing, int? index}) {
    final nameCtrl = TextEditingController(
      text: existing?.name ?? 'Groq / OpenRouter',
    );
    final endpointCtrl = TextEditingController(
      text: existing?.endpointUrl ??
          'https://api.groq.com/openai/v1/chat/completions',
    );
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final modelsCtrl = TextEditingController(
      text: existing?.models.join(', ') ??
          'llama-3.3-70b-versatile, openai/gpt-oss-120b',
    );
    bool obscure = true;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      existing == null
                          ? 'Добавить ИИ-провайдера'
                          : 'Настройка провайдера',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        ActionChip(
                          label: const Text('Шаблон Groq'),
                          onPressed: () {
                            setModalState(() {
                              nameCtrl.text = 'Groq Free';
                              endpointCtrl.text =
                                  'https://api.groq.com/openai/v1/chat/completions';
                              modelsCtrl.text =
                                  'llama-3.3-70b-versatile, openai/gpt-oss-120b, openai/gpt-oss-20b, meta-llama/llama-4-scout-17b-16e-instruct';
                            });
                          },
                        ),
                        ActionChip(
                          label: const Text('Шаблон OpenRouter'),
                          onPressed: () {
                            setModalState(() {
                              nameCtrl.text = 'OpenRouter Free';
                              endpointCtrl.text =
                                  'https://openrouter.ai/api/v1/chat/completions';
                              modelsCtrl.text =
                                  'meta-llama/llama-3.3-70b-instruct:free, google/gemma-3-27b-it:free, mistralai/mistral-small-3.1-24b-instruct:free';
                            });
                          },
                        ),
                        ActionChip(
                          label: const Text('Шаблон Gemini OpenAI'),
                          onPressed: () {
                            setModalState(() {
                              nameCtrl.text = 'Google Gemini';
                              endpointCtrl.text =
                                  'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';
                              modelsCtrl.text =
                                  'gemini-2.5-flash, gemini-2.0-flash';
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Название (например, Groq 1 или OpenRouter)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: endpointCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Endpoint URL',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: keyCtrl,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () =>
                              setModalState(() => obscure = !obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: modelsCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Модели через запятую (в порядке приоритета)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        final modelsList = modelsCtrl.text
                            .split(',')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList();
                        if (keyCtrl.text.trim().isEmpty || modelsList.isEmpty) {
                          return;
                        }
                        final profile = ApiProviderProfile(
                          id: existing?.id ??
                              DateTime.now().microsecondsSinceEpoch.toString(),
                          name: nameCtrl.text.trim().isEmpty
                              ? 'API Провайдер'
                              : nameCtrl.text.trim(),
                          endpointUrl: endpointCtrl.text.trim(),
                          apiKey: keyCtrl.text.trim(),
                          models: modelsList,
                          enabled: existing?.enabled ?? true,
                        );
                        setState(() {
                          _engineMode = TranslationEngineMode.groqCloud;
                          if (index != null) {
                            _providers[index] = profile;
                          } else {
                            _providers.add(profile);
                          }
                        });
                        Navigator.of(ctx).pop();
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Применить'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _checkOfflineModel() async {
    final ready = await OfflineTranslatorService.instance.isPairDownloaded(
      targetLanguage: _langController.text.trim().isEmpty
          ? 'Russian'
          : _langController.text.trim(),
    );
    if (mounted) {
      setState(() => _offlineModelReady = ready);
    }
  }

  Future<void> _downloadOfflineModel() async {
    setState(() {
      _downloadingOfflineModel = true;
      _offlineStatusStep = 'Подготовка загрузки...';
    });
    try {
      await OfflineTranslatorService.instance.downloadLanguagePair(
        targetLanguage: _langController.text.trim().isEmpty
            ? 'Russian'
            : _langController.text.trim(),
        onProgress: (step) {
          if (mounted) setState(() => _offlineStatusStep = step);
        },
      );
      if (!mounted) return;
      setState(() {
        _offlineModelReady = true;
        _offlineStatusStep = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Офлайн-модель скачана и готова к работе!'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _offlineStatusStep = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _downloadingOfflineModel = false);
      }
    }
  }

  Future<void> _handleExportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final path = await BookDatabase.instance.exportBackup();
      if (!mounted) return;
      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Резервная копия книг, прогресса и словаря сохранена!'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка экспорта: $e')),
      );
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _handleImportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final restored = await BookDatabase.instance.importBackup();
      if (!mounted) return;
      if (restored) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Библиотека, прогресс и словарь восстановлены!'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка восстановления: $e')),
      );
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _langController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final activeFirst = _providers.where((p) => p.enabled).firstOrNull ??
        (_providers.isNotEmpty ? _providers.first : null);

    final updated = TranslatorSettings(
      engineMode: _engineMode,
      endpointUrl: activeFirst?.endpointUrl ??
          'https://api.groq.com/openai/v1/chat/completions',
      apiKey: activeFirst?.apiKey ?? '',
      model: activeFirst?.models.firstOrNull ?? 'llama-3.3-70b-versatile',
      fallbackModels: activeFirst != null && activeFirst.models.length > 1
          ? activeFirst.models.sublist(1)
          : const [
              'openai/gpt-oss-120b',
              'openai/gpt-oss-20b',
              'meta-llama/llama-4-scout-17b-16e-instruct',
            ],
      providers: _providers,
      fallbackToOfflineOnError: _fallbackToOfflineOnError,
      targetLanguage: _langController.text.trim().isEmpty
          ? 'Russian'
          : _langController.text.trim(),
    );
    await _settingsService.saveSettings(updated);
    if (!mounted) return;
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки переводчика'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Сохранить',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // БЛОК 1: Подключённые ИИ-провайдеры и автопереключение между ними
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.hub_outlined, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'ИИ-провайдеры и автопереключение',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Добавьте один или несколько ключей (Groq, OpenRouter, Gemini). Если одна модель или провайдер выдаст ошибку или лимит — переводчик сам переключится на следующий.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 12),

                  if (_providers.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF191613),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Пока не добавлено ни одного ключа. Нажмите кнопку ниже, чтобы получить ключ Groq или добавить провайдера вручную.',
                        style: TextStyle(fontSize: 12, color: Color(0xFFA89E93)),
                      ),
                    )
                  else
                    for (int i = 0; i < _providers.length; i++)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF191613),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _providers[i].enabled
                                ? accent.withOpacity(0.4)
                                : Colors.white12,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 11,
                                  backgroundColor: accent.withOpacity(0.2),
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: accent,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _providers[i].name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                Switch(
                                  activeColor: accent,
                                  value: _providers[i].enabled,
                                  onChanged: (v) {
                                    setState(() {
                                      _providers[i] =
                                          _providers[i].copyWith(enabled: v);
                                    });
                                  },
                                ),
                              ],
                            ),
                            Text(
                              'Модели: ${_providers[i].models.join(', ')}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFA89E93),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (i > 0)
                                  IconButton(
                                    tooltip: 'Поднять приоритет',
                                    icon: const Icon(Icons.arrow_upward, size: 18),
                                    onPressed: () {
                                      setState(() {
                                        final item = _providers.removeAt(i);
                                        _providers.insert(i - 1, item);
                                      });
                                    },
                                  ),
                                IconButton(
                                  tooltip: 'Редактировать',
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  onPressed: () => _openProviderEditor(
                                    existing: _providers[i],
                                    index: i,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Удалить',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () {
                                    setState(() => _providers.removeAt(i));
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _openGroqKeysPage,
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: const Text('Ключ Groq'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openProviderEditor(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Добавить API'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _tryPasteGroqKeyFromClipboard(silentIfNotFound: false),
                      icon: const Icon(Icons.content_paste_go, size: 18),
                      label: const Text('Вставить ключ Groq из буфера'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeColor: accent,
                    title: const Text(
                      'Страховка: переходить на офлайн-словарь при сбое всех ИИ',
                      style: TextStyle(fontSize: 13),
                    ),
                    value: _fallbackToOfflineOnError,
                    onChanged: (v) =>
                        setState(() => _fallbackToOfflineOnError = v),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // БЛОК 2: Встроенный офлайн-переводчик (Google ML Kit)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.offline_pin_outlined, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Встроенный офлайн-переводчик',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Switch(
                        activeColor: accent,
                        value:
                            _engineMode == TranslationEngineMode.offlineLocal,
                        onChanged: (val) async {
                          if (val) {
                            setState(() {
                              _engineMode = TranslationEngineMode.offlineLocal;
                            });
                            if (!_offlineModelReady) {
                              await _downloadOfflineModel();
                            }
                          } else {
                            setState(() {
                              _engineMode = TranslationEngineMode.groqCloud;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Работает без интернета и ключей. Переключать режим (ИИ / Офлайн) можно также прямо в верхней панели читалки.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _offlineStatusStep ??
                              (_offlineModelReady
                                  ? 'Статус: языковая модель загружена'
                                  : 'Статус: модель ещё не загружена'),
                          style: TextStyle(
                            fontSize: 12,
                            color: _offlineStatusStep != null
                                ? accent
                                : _offlineModelReady
                                    ? Colors.greenAccent
                                    : const Color(0xFFA89E93),
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _downloadingOfflineModel
                            ? null
                            : _downloadOfflineModel,
                        icon: _downloadingOfflineModel
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download, size: 18),
                        label: Text(
                          _offlineModelReady ? 'Проверить' : 'Скачать модель',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // БЛОК 3: Резервное копирование библиотеки книг, прогресса и словаря
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.backup_outlined, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Резервная копия книг, прогресса и словаря',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Сохраняет все книги, места остановки чтения, переводы и личный словарь в один файл .db.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _backupBusy ? null : _handleExportBackup,
                          icon: const Icon(Icons.upload_file, size: 18),
                          label: const Text('Сохранить копию'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _backupBusy ? null : _handleImportBackup,
                          icon: const Icon(Icons.restore_page, size: 18),
                          label: const Text('Восстановить'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // БЛОК 4: Язык перевода
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _langController,
                onChanged: (_) => _checkOfflineModel(),
                decoration: const InputDecoration(
                  labelText: 'Язык перевода',
                  hintText: 'Russian',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Сохранить настройки'),
          ),
        ],
      ),
    );
  }
}
