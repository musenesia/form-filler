import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../services/runner_service.dart';
import '../services/storage_service.dart';

/// App settings: Node path, runner directory, setup actions, preflight check.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = StorageService.instance;
  final _runner = RunnerService.instance;

  late TextEditingController _nodePath;
  late TextEditingController _runnerDir;
  late TextEditingController _stepDelayMin;
  late TextEditingController _stepDelayMax;
  late TextEditingController _typeDelayMin;
  late TextEditingController _typeDelayMax;
  late TextEditingController _mouseSteps;
  late TextEditingController _viewportW;
  late TextEditingController _viewportH;
  late TextEditingController _userAgent;
  late TextEditingController _locale;
  late TextEditingController _timezone;
  AppSettings _settings = AppSettings();
  bool _loading = true;

  PreflightResult? _preflight;
  bool _checking = false;

  String _taskOutput = '';
  String? _taskName;
  StreamSubscription<String>? _taskSub;

  @override
  void initState() {
    super.initState();
    _nodePath = TextEditingController();
    _runnerDir = TextEditingController();
    _stepDelayMin = TextEditingController();
    _stepDelayMax = TextEditingController();
    _typeDelayMin = TextEditingController();
    _typeDelayMax = TextEditingController();
    _mouseSteps = TextEditingController();
    _viewportW = TextEditingController();
    _viewportH = TextEditingController();
    _userAgent = TextEditingController();
    _locale = TextEditingController();
    _timezone = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _nodePath.dispose();
    _runnerDir.dispose();
    _stepDelayMin.dispose();
    _stepDelayMax.dispose();
    _typeDelayMin.dispose();
    _typeDelayMax.dispose();
    _mouseSteps.dispose();
    _viewportW.dispose();
    _viewportH.dispose();
    _userAgent.dispose();
    _locale.dispose();
    _timezone.dispose();
    _taskSub?.cancel();
    super.dispose();
  }

  void _syncHumanizeControllers() {
    final h = _settings.humanizeDefaults;
    _stepDelayMin.text = '${h.stepDelayMinMs}';
    _stepDelayMax.text = '${h.stepDelayMaxMs}';
    _typeDelayMin.text = '${h.typeDelayMinMs}';
    _typeDelayMax.text = '${h.typeDelayMaxMs}';
    _mouseSteps.text = '${h.mouseSteps}';
    _viewportW.text = '${h.viewportW}';
    _viewportH.text = '${h.viewportH}';
    _userAgent.text = h.userAgent;
    _locale.text = h.locale;
    _timezone.text = h.timezoneId;
  }

  void _readHumanizeControllers() {
    final h = _settings.humanizeDefaults;
    int asInt(TextEditingController c, int fallback) =>
        int.tryParse(c.text.trim()) ?? fallback;
    h.stepDelayMinMs = asInt(_stepDelayMin, 400);
    h.stepDelayMaxMs = asInt(_stepDelayMax, 1200);
    h.typeDelayMinMs = asInt(_typeDelayMin, 40);
    h.typeDelayMaxMs = asInt(_typeDelayMax, 140);
    h.mouseSteps = asInt(_mouseSteps, 12);
    h.viewportW = asInt(_viewportW, 1280);
    h.viewportH = asInt(_viewportH, 800);
    h.userAgent = _userAgent.text.trim();
    h.locale = _locale.text.trim();
    h.timezoneId = _timezone.text.trim();
  }

  Future<void> _load() async {
    final settings = await _storage.loadSettings();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _nodePath.text = settings.nodePath;
      _runnerDir.text = settings.runnerDir;
      _loading = false;
    });
    _syncHumanizeControllers();
    _runPreflight();
  }

  Future<void> _save() async {
    _settings.nodePath = _nodePath.text.trim();
    _settings.runnerDir = _runnerDir.text.trim();
    _readHumanizeControllers();
    await _storage.saveSettings(_settings);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Settings saved.')));
    _runPreflight();
  }

  Future<void> _runPreflight() async {
    setState(() {
      _checking = true;
      _preflight = null;
    });
    final result = await _runner.preflight(_settings);
    if (!mounted) return;
    setState(() {
      _preflight = result;
      _checking = false;
    });
  }

  Future<void> _runTask(String name, Stream<String> Function() start) async {
    final runnerDir = await _runner.resolveRunnerDir(_settings);
    if (!mounted) return;
    if (runnerDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Runner directory not found — set it above first.'),
        ),
      );
      return;
    }
    await _taskSub?.cancel();
    setState(() {
      _taskName = name;
      _taskOutput = 'Starting $name…\n';
    });
    _taskSub = start().listen(
      (chunk) {
        if (!mounted) return;
        setState(() => _taskOutput += chunk);
      },
      onDone: () {
        if (mounted) _runPreflight();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _taskOutput += '\nError: $e\n');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Paths', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _nodePath,
                  decoration: const InputDecoration(
                    labelText: 'Node executable path',
                    hintText: 'Empty = use node from PATH',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _runnerDir,
                  decoration: const InputDecoration(
                    labelText: 'Runner directory',
                    hintText: 'Empty = auto-detect (folder with scan.js, fill.js, batch.js, login.js)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save settings'),
                  ),
                ),
                const Divider(height: 32),
                Text(
                  'Humanization defaults',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Applied to new profiles. Human-like timing makes automation '
                  'less obvious to naive bot checks, but nothing makes it '
                  'undetectable — keep volumes modest and respect site terms.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Human-like execution'),
                  subtitle: const Text(
                    'Random delays between steps, human-like typing and mouse moves',
                  ),
                  value: _settings.humanizeDefaults.enabled,
                  onChanged: (v) =>
                      setState(() => _settings.humanizeDefaults.enabled = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Stealth evasions'),
                  subtitle: const Text(
                    'Patch common headless/automation fingerprints (playwright-extra stealth)',
                  ),
                  value: _settings.humanizeDefaults.stealth,
                  onChanged: (v) =>
                      setState(() => _settings.humanizeDefaults.stealth = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use real Chrome if available'),
                  subtitle: const Text(
                    'Launch installed Chrome instead of bundled Chromium',
                  ),
                  value: _settings.humanizeDefaults.useRealChrome,
                  onChanged: (v) => setState(
                    () => _settings.humanizeDefaults.useRealChrome = v,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _stepDelayMin,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Step delay min (ms)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _stepDelayMax,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Step delay max (ms)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _typeDelayMin,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Typing delay min (ms)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _typeDelayMax,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Typing delay max (ms)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _mouseSteps,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Mouse move steps',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _viewportW,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Viewport width',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _viewportH,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Viewport height',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _userAgent,
                  decoration: const InputDecoration(
                    labelText: 'User agent override (empty = default)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _locale,
                        decoration: const InputDecoration(
                          labelText: 'Locale (e.g. en-US)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _timezone,
                        decoration: const InputDecoration(
                          labelText: 'Timezone (e.g. Asia/Jakarta)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 32),
                Text('Setup', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          _runTask('Install npm dependencies', () async* {
                            final dir =
                                await _runner.resolveRunnerDir(_settings) ?? '';
                            yield* _runner.npmInstall(_settings, dir);
                          }),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Install npm dependencies'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _runTask('Install Chromium', () async* {
                        final dir =
                            await _runner.resolveRunnerDir(_settings) ?? '';
                        yield* _runner.installChromium(_settings, dir);
                      }),
                      icon: const Icon(Icons.web_outlined),
                      label: const Text('Install Chromium'),
                    ),
                  ],
                ),
                if (_taskName != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _taskName!,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _taskOutput,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
                const Divider(height: 32),
                Row(
                  children: [
                    Text(
                      'Preflight check',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Re-run preflight',
                      icon: const Icon(Icons.refresh),
                      onPressed: _checking ? null : _runPreflight,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_checking)
                  const Center(child: CircularProgressIndicator())
                else if (_preflight != null)
                  Card(
                    color: _preflight!.ok
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _preflight!.ok
                                    ? Icons.check_circle
                                    : Icons.warning_amber,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _preflight!.ok
                                    ? 'Ready to run'
                                    : 'Needs attention',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ..._preflight!.messages.map(
                            (m) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text('• $m'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  'Only automate websites you are authorized to use. '
                  'Sessions and profiles are stored locally on this computer.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
