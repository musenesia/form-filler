import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/fill_profile.dart';
import '../models/run_record.dart';
import '../services/runner_service.dart';
import '../services/storage_service.dart';

/// Runs a profile and shows the live log, progress, and result.
class RunScreen extends StatefulWidget {
  const RunScreen({super.key, required this.profile});

  final FillProfile profile;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  final _storage = StorageService.instance;
  final _runner = RunnerService.instance;

  final List<String> _log = [];
  final ScrollController _scroll = ScrollController();

  bool _running = true;
  bool _success = false;
  String _resultMessage = '';
  String _screenshotPath = '';
  int _stepsTotal = 0;
  int _stepsDone = 0;
  StreamSubscription<RunnerEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _stepsTotal = widget.profile.steps.length;
    _start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _start() async {
    final settings = await _storage.loadSettings();
    final runnerDir = await _runner.resolveRunnerDir(settings);
    if (!mounted) return;
    if (runnerDir == null) {
      setState(() {
        _running = false;
        _resultMessage = 'Runner directory not found — check Settings.';
      });
      _append('ERROR: runner directory not found.');
      return;
    }
    final sessionPath = await _storage.sessionPath(widget.profile.id);
    final screenshots = await _storage.screenshotsDir;

    await _sub?.cancel();
    _sub = _runner
        .fill(
          settings,
          runnerDir,
          widget.profile,
          storagePath: sessionPath,
          screenshotDir: screenshots.path,
        )
        .listen(
          (event) {
            switch (event.kind) {
              case 'progress':
                _append(
                  '[${event.data['step']}/${event.data['total']}] '
                  '${event.data['action']} ${event.message}',
                );
                setState(() {
                  _stepsDone =
                      (event.data['step'] as num?)?.toInt() ?? _stepsDone;
                });
                break;
              case 'result':
                final ok = event.data['ok'] == true;
                setState(() {
                  _running = false;
                  _success = ok;
                  _stepsDone =
                      (event.data['steps'] as num?)?.toInt() ?? _stepsDone;
                  _resultMessage = ok
                      ? 'Completed $_stepsDone steps.'
                      : 'Failed: ${event.data['error'] ?? event.message}';
                  _screenshotPath = (event.data['screenshot'] as String?) ?? '';
                });
                _append(
                  ok
                      ? 'DONE: success'
                      : 'DONE: failed — ${event.data['error']}',
                );
                _recordRun(ok, ok ? '' : '${event.data['error']}');
                break;
              case 'error':
                setState(() {
                  _running = false;
                  _resultMessage = 'Error: ${event.message}';
                });
                _append('ERROR: ${event.message}');
                _recordRun(false, event.message);
                break;
              case 'data':
                _append('data: ${event.message}');
                break;
              default:
                if (event.message.isNotEmpty) _append(event.message);
            }
          },
          onDone: () {
            if (mounted && _running) {
              setState(() {
                _running = false;
                _resultMessage = 'Run finished.';
              });
            }
          },
          onError: (Object e) {
            if (mounted) {
              setState(() {
                _running = false;
                _resultMessage = 'Error: $e';
              });
              _append('ERROR: $e');
            }
          },
        );
  }

  Future<void> _recordRun(bool success, String error) async {
    await _storage.appendRun(
      RunRecord(
        profileId: widget.profile.id,
        profileName: widget.profile.name,
        success: success,
        steps: _stepsDone,
        error: error,
        screenshotPath: _screenshotPath,
      ),
    );
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    if (mounted) {
      setState(() {
        _running = false;
        _resultMessage = 'Stopped by user.';
      });
      _append('Stopped by user.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _stepsTotal > 0
        ? _stepsDone / _stepsTotal
        : (_running ? null : 1.0);
    return Scaffold(
      appBar: AppBar(
        title: Text('Run: ${widget.profile.name}'),
        actions: [
          if (_running)
            TextButton.icon(
              onPressed: _stop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: LinearProgressIndicator(value: progress)),
                const SizedBox(width: 12),
                Text('$_stepsDone/$_stepsTotal steps'),
              ],
            ),
            const SizedBox(height: 12),
            if (!_running)
              Card(
                color: _success
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(_success ? Icons.check_circle : Icons.error_outline),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_resultMessage)),
                      if (_screenshotPath.isNotEmpty)
                        TextButton(
                          onPressed: () => _showScreenshot(),
                          child: const Text('View screenshot'),
                        ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _log.clear();
                            _stepsDone = 0;
                            _running = true;
                            _resultMessage = '';
                            _screenshotPath = '';
                          });
                          _start();
                        },
                        child: const Text('Run again'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                child: Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (context, i) => SelectableText(
                      _log[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showScreenshot() {
    final file = File(_screenshotPath);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_screenshotPath.split(Platform.pathSeparator).last),
              const SizedBox(height: 8),
              Flexible(
                child: file.existsSync()
                    ? Image.file(file)
                    : const Text('Screenshot file not found.'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
