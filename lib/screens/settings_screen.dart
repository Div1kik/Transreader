import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../db/book_database.dart';
import '../services/offline_translator_service.dart';
import '../services/settings_service.dart';

class _ProviderWizardStep {
  final String fixedId;
  final String title;
  final String url;
  final String keyPrefixHint;

  const _ProviderWizardStep({
    required this.fixedId,
    required this.title,
    required this.url,
    required this.keyPrefixHint,
  });
}

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
  late bool _fallbackToOfflineOnError;
  late TextEditingController _langController;

  late TextEditingController _groqKeyCtrl;
  late TextEditingController _groqModelsCtrl;
  bool _groqEnabled = true;
  bool _obscureGroq = true;

  late TextEditingController _geminiKeyCtrl;
  late TextEditingController _geminiModelsCtrl;
  bool _geminiEnabled = true;
  bool _obscureGemini = true;

  late TextEditingController _openRouterKeyCtrl;
  late TextEditingController _openRouterModelsCtrl;
  bool _openRouterEnabled = true;
  bool _obscureOpenRouter = true;

  late List<ApiProviderProfile> _extraProviders;

  bool _downloadingOfflineModel = false;
  String? _offlineStatusStep;
  bool _offlineModelReady = false;
  bool _backupBusy = false;

  bool _waitingForClipboardKey = false;
  bool _wizardActive = false;
  int _wizardStepIndex = 0;

  static const String _groqEndpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static const String _geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';
  static const String _openRouterEndpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  static const List<String> _defaultGroqModels = [
    'llama-3.3-70b-versatile',
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
    'meta-llama/llama-4-scout-17b-16e-instruct',
  ];

  static const List<String> _defaultGeminiModels =
      SettingsService.defaultGeminiModels;

  static const List<String> _defaultOpenRouterModels = [
    'meta-llama/llama-3.3-70b-instruct:free',
    'google/gemma-3-27b-it:free',
    'mistralai/mistral-small-3.1-24b-instruct:free',
  ];

  static const List<_ProviderWizardStep> _wizardSteps = [
    _ProviderWizardStep(
      fixedId: 'groq_fixed',
      title: 'Groq Free (самый быстрый)',
      url: 'https://console.groq.com/keys',
      keyPrefixHint: 'gsk_...',
    ),
    _ProviderWizardStep(
      fixedId: 'gemini_fixed',
      title: 'Google Gemini Free (через ваш Google)',
      url: 'https://aistudio.google.com/app/apikey',
      keyPrefixHint: 'AIza...',
    ),
    _ProviderWizardStep(
      fixedId: 'openrouter_fixed',
      title: 'OpenRouter Free (резервный пул)',
      url: 'https://openrouter.ai/settings/keys',
      keyPrefixHint: 'sk-or-...',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engineMode = widget.initialSettings.engineMode;
    _fallbackToOfflineOnError =
        widget.initialSettings.fallbackToOfflineOnError;
    _langController =
        TextEditingController(text: widget.initialSettings.targetLanguage);

    final existing = widget.initialSettings.effectiveProviders;

    final groqP = existing
        .where((p) => p.endpointUrl.contains('groq.com'))
        .firstOrNull;
    _groqKeyCtrl = TextEditingController(text: groqP?.apiKey ?? '');
    _groqModelsCtrl = TextEditingController(
      text: (groqP != null && groqP.models.isNotEmpty
              ? groqP.models
              : _defaultGroqModels)
          .join(', '),
    );
    _groqEnabled = groqP?.enabled ?? true;

    final geminiP = existing
        .where((p) => p.endpointUrl.contains('generativelanguage.googleapis.com'))
        .firstOrNull;
    _geminiKeyCtrl = TextEditingController(text: geminiP?.apiKey ?? '');
    _geminiModelsCtrl = TextEditingController(
      text: (geminiP != null && geminiP.models.isNotEmpty
              ? geminiP.models
              : _defaultGeminiModels)
          .join(', '),
    );
    _geminiEnabled = geminiP?.enabled ?? true;

    final orP = existing
        .where((p) => p.endpointUrl.contains('openrouter.ai'))
        .firstOrNull;
    _openRouterKeyCtrl = TextEditingController(text: orP?.apiKey ?? '');
    _openRouterModelsCtrl = TextEditingController(
      text: (orP != null && orP.models.isNotEmpty
              ? orP.models
              : _defaultOpenRouterModels)
          .join(', '),
    );
    _openRouterEnabled = orP?.enabled ?? true;

    _extraProviders = existing
        .where((p) =>
            !p.endpointUrl.contains('groq.com') &&
            !p.endpointUrl.contains('generativelanguage.googleapis.com') &&
            !p.endpointUrl.contains('openrouter.ai'))
        .toList();

    _checkOfflineModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForClipboardKey) {
      _waitingForClipboardKey = false;
      _onReturnedFromBrowser();
    }
  }

  Future<void> _onReturnedFromBrowser() async {
    final addedName = await _tryAutoDetectAndAddKeyFromClipboard(
      silentIfNotFound: true,
    );

    if (!_wizardActive || !mounted) return;

    final nextStep = _wizardStepIndex + 1;
    if (nextStep >= _wizardSteps.length) {
      setState(() {
        _wizardActive = false;
        _wizardStepIndex = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Мастер подключения завершён! Все ключи сохранены.'),
        ),
      );
      return;
    }

    final stepInfo = _wizardSteps[nextStep];
    final continueWizard = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(
          addedName != null
              ? 'Подключено: $addedName'
              : 'Шаг ${_wizardStepIndex + 1} из ${_wizardSteps.length}',
        ),
        content: Text(
          'Переходим к следующему провайдеру (${nextStep + 1}/${_wizardSteps.length}):\n'
          '${stepInfo.title}\n\n'
          'Создайте и скопируйте ключ (${stepInfo.keyPrefixHint}), затем закройте вкладку крестиком «✕».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Завершить'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.arrow_forward, size: 18),
            label: Text('Открыть ${stepInfo.title.split(' ').first}'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (continueWizard == true) {
      setState(() => _wizardStepIndex = nextStep);
      await _launchProviderTab(stepInfo.url);
    } else {
      setState(() {
        _wizardActive = false;
        _wizardStepIndex = 0;
      });
    }
  }

  Future<void> _launchProviderTab(String url) async {
    _waitingForClipboardKey = true;
    final uri = Uri.parse(url);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.inAppBrowserView,
    );
    if (!launched && mounted) {
      _waitingForClipboardKey = false;
      _wizardActive = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть $url')),
      );
    }
  }

  Future<void> _startSingleOneClickConnect() async {
    setState(() {
      _wizardActive = false;
      _wizardStepIndex = 0;
    });
    await _launchProviderTab('https://console.groq.com/keys');
  }

  Future<void> _startMultiModelConnectWizard() async {
    setState(() {
      _wizardActive = true;
      _wizardStepIndex = 0;
    });
    await _launchProviderTab(_wizardSteps.first.url);
  }

  Future<String?> _tryAutoDetectAndAddKeyFromClipboard({
    bool silentIfNotFound = false,
  }) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final clipText = data?.text?.trim() ?? '';

    String? detectedName;

    if (clipText.startsWith('gsk_') && clipText.length > 20) {
      detectedName = 'Groq Free';
      if (mounted) {
        setState(() {
          _engineMode = TranslationEngineMode.groqCloud;
          _groqKeyCtrl.text = clipText;
          _groqEnabled = true;
        });
      }
    } else if (clipText.startsWith('AIza') && clipText.length > 25) {
      detectedName = 'Google Gemini Free';
      if (mounted) {
        setState(() {
          _engineMode = TranslationEngineMode.groqCloud;
          _geminiKeyCtrl.text = clipText;
          _geminiEnabled = true;
        });
      }
    } else if (clipText.startsWith('sk-or-') && clipText.length > 20) {
      detectedName = 'OpenRouter Free';
      if (mounted) {
        setState(() {
          _engineMode = TranslationEngineMode.groqCloud;
          _openRouterKeyCtrl.text = clipText;
          _openRouterEnabled = true;
        });
      }
    }

    if (detectedName != null) {
      await _persistSettingsSilently();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Ключ $detectedName распознан и вставлен в своё поле!',
            ),
          ),
        );
      }
      return detectedName;
    } else if (!silentIfNotFound && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'В буфере обмена не найден ключ (поддерживаются gsk_..., AIza..., sk-or-...)',
          ),
        ),
      );
    }
    return null;
  }

  void _openExtraProviderEditor({ApiProviderProfile? existing, int? index}) {
    final nameCtrl = TextEditingController(
      text: existing?.name ?? 'Дополнительный API',
    );
    final endpointCtrl = TextEditingController(
      text: existing?.endpointUrl ?? '',
    );
    final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final modelsCtrl = TextEditingController(
      text: existing?.models.join(', ') ?? '',
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
                          ? 'Добавить свой OpenAI-совместимый API'
                          : 'Настройка провайдера',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Название провайдера',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: endpointCtrl,
                      decoration: const InputDecoration(
                        labelText:
                            'Endpoint URL (https://.../v1/chat/completions)',
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
                        labelText: 'Модели через запятую',
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
                        if (keyCtrl.text.trim().isEmpty ||
                            endpointCtrl.text.trim().isEmpty ||
                            modelsList.isEmpty) {
                          return;
                        }
                        final profile = ApiProviderProfile(
                          id: existing?.id ??
                              'extra_${DateTime.now().microsecondsSinceEpoch}',
                          name: nameCtrl.text.trim().isEmpty
                              ? 'Свой API'
                              : nameCtrl.text.trim(),
                          endpointUrl: endpointCtrl.text.trim(),
                          apiKey: keyCtrl.text.trim(),
                          models: modelsList,
                          enabled: existing?.enabled ?? true,
                        );
                        setState(() {
                          _engineMode = TranslationEngineMode.groqCloud;
                          if (index != null) {
                            _extraProviders[index] = profile;
                          } else {
                            _extraProviders.add(profile);
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

  List<String> _parseModels(String raw, List<String> fallback) {
    final parsed = raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parsed.isNotEmpty ? parsed : fallback;
  }

  List<ApiProviderProfile> _collectAllProviders() {
    final list = <ApiProviderProfile>[];

    if (_groqKeyCtrl.text.trim().isNotEmpty) {
      list.add(
        ApiProviderProfile(
          id: 'groq_fixed',
          name: 'Groq Free',
          endpointUrl: _groqEndpoint,
          apiKey: _groqKeyCtrl.text.trim(),
          models: _parseModels(_groqModelsCtrl.text, _defaultGroqModels),
          enabled: _groqEnabled,
        ),
      );
    }

    if (_geminiKeyCtrl.text.trim().isNotEmpty) {
      list.add(
        ApiProviderProfile(
          id: 'gemini_fixed',
          name: 'Google Gemini Free',
          endpointUrl: _geminiEndpoint,
          apiKey: _geminiKeyCtrl.text.trim(),
          models: _parseModels(_geminiModelsCtrl.text, _defaultGeminiModels),
          enabled: _geminiEnabled,
        ),
      );
    }

    if (_openRouterKeyCtrl.text.trim().isNotEmpty) {
      list.add(
        ApiProviderProfile(
          id: 'openrouter_fixed',
          name: 'OpenRouter Free',
          endpointUrl: _openRouterEndpoint,
          apiKey: _openRouterKeyCtrl.text.trim(),
          models:
              _parseModels(_openRouterModelsCtrl.text, _defaultOpenRouterModels),
          enabled: _openRouterEnabled,
        ),
      );
    }

    list.addAll(_extraProviders);
    return list;
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

  TranslatorSettings _buildUpdatedSettings() {
    final collected = _collectAllProviders();
    final activeFirst = collected.where((p) => p.enabled).firstOrNull ??
        (collected.isNotEmpty ? collected.first : null);

    return TranslatorSettings(
      engineMode: _engineMode,
      endpointUrl: activeFirst?.endpointUrl ?? _groqEndpoint,
      apiKey: activeFirst?.apiKey ?? '',
      model: activeFirst?.models.firstOrNull ?? 'llama-3.3-70b-versatile',
      fallbackModels: activeFirst != null && activeFirst.models.length > 1
          ? activeFirst.models.sublist(1)
          : _defaultGroqModels.sublist(1),
      providers: collected,
      fallbackToOfflineOnError: _fallbackToOfflineOnError,
      targetLanguage: _langController.text.trim().isEmpty
          ? 'Russian'
          : _langController.text.trim(),
    );
  }

  Future<void> _persistSettingsSilently() async {
    final updated = _buildUpdatedSettings();
    await _settingsService.saveSettings(updated);
  }

  Future<void> _save() async {
    final updated = _buildUpdatedSettings();
    await _settingsService.saveSettings(updated);
    if (!mounted) return;
    Navigator.of(context).pop(updated);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _langController.dispose();
    _groqKeyCtrl.dispose();
    _groqModelsCtrl.dispose();
    _geminiKeyCtrl.dispose();
    _geminiModelsCtrl.dispose();
    _openRouterKeyCtrl.dispose();
    _openRouterModelsCtrl.dispose();
    super.dispose();
  }

  Widget _buildDedicatedProviderBox({
    required Color accent,
    required int orderNumber,
    required String title,
    required String keyHint,
    required String portalUrl,
    required TextEditingController keyController,
    required TextEditingController modelsController,
    required bool enabled,
    required ValueChanged<bool> onToggleEnabled,
    required bool obscureKey,
    required VoidCallback onToggleObscure,
  }) {
    final hasKey = keyController.text.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF191613),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (hasKey && enabled)
              ? accent.withOpacity(0.45)
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
                  '$orderNumber',
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
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Открыть сайт для получения ключа',
                icon: Icon(Icons.open_in_new, size: 18, color: accent),
                onPressed: () {
                  _wizardActive = false;
                  _launchProviderTab(portalUrl);
                },
              ),
              Switch(
                activeColor: accent,
                value: enabled,
                onChanged: onToggleEnabled,
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: keyController,
            obscureText: obscureKey,
            onChanged: (_) {
              if (keyController.text.trim().isNotEmpty) {
                _engineMode = TranslationEngineMode.groqCloud;
              }
              setState(() {});
            },
            decoration: InputDecoration(
              labelText: 'API Key ($keyHint)',
              hintText: keyHint,
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Вставить из буфера',
                    icon: const Icon(Icons.content_paste, size: 18),
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      final txt = data?.text?.trim() ?? '';
                      if (txt.isNotEmpty) {
                        setState(() {
                          keyController.text = txt;
                          _engineMode = TranslationEngineMode.groqCloud;
                        });
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      obscureKey ? Icons.visibility : Icons.visibility_off,
                      size: 18,
                    ),
                    onPressed: onToggleObscure,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: modelsController,
            maxLines: 2,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Модели (через запятую)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.bolt, color: accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Подключение бесплатных ИИ-моделей',
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
                    'Каждый провайдер имеет своё отдельное поле для ключа. При ошибке или лимите одного провайдера переводчик сам переключится на следующий.',
                    style: TextStyle(fontSize: 13, color: Color(0xFFA89E93)),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _startSingleOneClickConnect,
                          icon: const Icon(Icons.flash_on, size: 18),
                          label: const Text(
                            'В 1 клик\n(Groq)',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, height: 1.2),
                          ),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 8,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _startMultiModelConnectWizard,
                          icon: const Icon(Icons.layers, size: 18),
                          label: const Text(
                            'Несколько\nмоделей сразу',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, height: 1.2),
                          ),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 8,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  _buildDedicatedProviderBox(
                    accent: accent,
                    orderNumber: 1,
                    title: 'Groq Free (Основной)',
                    keyHint: 'gsk_...',
                    portalUrl: 'https://console.groq.com/keys',
                    keyController: _groqKeyCtrl,
                    modelsController: _groqModelsCtrl,
                    enabled: _groqEnabled,
                    onToggleEnabled: (v) => setState(() => _groqEnabled = v),
                    obscureKey: _obscureGroq,
                    onToggleObscure: () =>
                        setState(() => _obscureGroq = !_obscureGroq),
                  ),

                  _buildDedicatedProviderBox(
                    accent: accent,
                    orderNumber: 2,
                    title: 'Google Gemini Free',
                    keyHint: 'AIza...',
                    portalUrl: 'https://aistudio.google.com/app/apikey',
                    keyController: _geminiKeyCtrl,
                    modelsController: _geminiModelsCtrl,
                    enabled: _geminiEnabled,
                    onToggleEnabled: (v) => setState(() => _geminiEnabled = v),
                    obscureKey: _obscureGemini,
                    onToggleObscure: () =>
                        setState(() => _obscureGemini = !_obscureGemini),
                  ),

                  _buildDedicatedProviderBox(
                    accent: accent,
                    orderNumber: 3,
                    title: 'OpenRouter Free',
                    keyHint: 'sk-or-...',
                    portalUrl: 'https://openrouter.ai/settings/keys',
                    keyController: _openRouterKeyCtrl,
                    modelsController: _openRouterModelsCtrl,
                    enabled: _openRouterEnabled,
                    onToggleEnabled: (v) =>
                        setState(() => _openRouterEnabled = v),
                    obscureKey: _obscureOpenRouter,
                    onToggleObscure: () =>
                        setState(() => _obscureOpenRouter = !_obscureOpenRouter),
                  ),

                  for (int i = 0; i < _extraProviders.length; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF191613),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${i + 4}. ${_extraProviders[i].name}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => _openExtraProviderEditor(
                              existing: _extraProviders[i],
                              index: i,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.redAccent,
                            ),
                            onPressed: () =>
                                setState(() => _extraProviders.removeAt(i)),
                          ),
                        ],
                      ),
                    ),

                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _openExtraProviderEditor(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Добавить свой API'),
                    ),
                  ),

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
