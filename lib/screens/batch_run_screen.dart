import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/fill_profile.dart';
import '../models/run_record.dart';
import '../services/runner_service.dart';
import '../services/storage_service.dart';

enum RowStatus { pending, running, ok, failed, blockedCaptcha }

class _RowState {
  _RowState(this.rowNumber);

  final int rowNumber;
  RowStatus status = RowStatus.pending;
  String error = '';
}

/// Runs a profile once per data-file row and shows live per-row progress.
class BatchRunScreen extends StatefulWidget {
  const BatchRunScreen({super.key, required this.profile});

  final FillProfile profile;

  @override
  State<BatchRunScreen> createState() => _BatchRunScreenState();
}

class _BatchRunScreenState extends State<BatchRunScreen> {
  final _storage = StorageService.instance;
  final _runner = RunnerService.instance;

  late TextEditingController _startRow;
  late TextEditingController _maxRows;
  late TextEditingController _rowDelayMin;
  late TextEditingController _rowDelayMax;
  late bool _stopOnError;

  final List<String> _log = [];
  final ScrollController _scroll = ScrollController();
  final Map<int, _RowState> _rows = {};

  bool _running = false;
  bool _cancelling = false;
  int _totalRows = 0;
  Map<String, dynamic>? _summary;
  String _resultsDir = '';
  String _statusMessage = '';
  BatchHandle? _handle;
  StreamSubscription<RunnerEvent>? _sub;

  @override
  void initState() {
    super.initState();
    final b = widget.profile.batch;
    _startRow = TextEditingController(text: '${b.startRow}');
    _maxRows = TextEditingController(text: '${b.maxRows}');
    _rowDelayMin = TextEditingController(text: '${b.rowDelayMinMs}');
    _rowDelayMax = TextEditingController(text: '${b.rowDelayMaxMs}');
    _stopOnError = b.stopOnError;
  }

  @override
  void dispose() {
    _startRow.dispose();
    _maxRows.dispose();
    _rowDelayMin.dispose();
    _rowDelayMax.dispose();
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
    final dataFile = widget.profile.batch.dataFilePath.trim();
    if (dataFile.isEmpty) {
      _snack(
        'No data file selected — edit the profile and attach a CSV/XLSX file first.',
      );
      return;
    }
    final settings = await _storage.loadSettings();
    final runnerDir = await _runner.resolveRunnerDir(settings);
    if (!mounted) return;
    if (runnerDir == null) {
      _snack('Runner directory not found — check Settings.');
      return;
    }
    final sessionPath = await _storage.sessionPath(widget.profile.id);

    setState(() {
      _running = true;
      _cancelling = false;
      _rows.clear();
      _summary = null;
      _resultsDir = '';
      _statusMessage = 'Starting batch…';
    });
    _append('Starting batch run…');

    BatchHandle handle;
    try {
      handle = await _runner.runBatch(
        settings,
        runnerDir,
        widget.profile,
        storagePath: sessionPath,
        startRow: int.tryParse(_startRow.text.trim()),
        maxRows: int.tryParse(_maxRows.text.trim()),
        rowDelayMinMs: int.tryParse(_rowDelayMin.text.trim()),
        rowDelayMaxMs: int.tryParse(_rowDelayMax.text.trim()),
        stopOnError: _stopOnError,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _statusMessage = 'Could not start batch: $e';
      });
      _append('ERROR: $e');
      return;
    }
    _handle = handle;
    _resultsDir = handle.resultsDir;

    await _sub?.cancel();
    _sub = handle.events.listen(
      (event) {
        if (!mounted) return;
        switch (event.kind) {
          case 'batch_start':
            final total = (event.data['totalRows'] as num?)?.toInt() ?? 0;
            setState(() {
              _totalRows = total;
              for (var r = 1; r <= total; r++) {
                // Row numbers are 1-based over the source file; the runner
                // reports the actual number, so prefill sequentially and fix
                // up on row_start.
                _rows[r] ??= _RowState(r);
              }
              _statusMessage = 'Running 0/$total rows…';
            });
            _append('Batch started: $total rows.');
            break;
          case 'row_start':
            final n = (event.data['rowNumber'] as num?)?.toInt() ?? 0;
            setState(() {
              _rows[n] = _RowState(n)..status = RowStatus.running;
              _statusMessage = 'Running row $n…';
            });
            _append('— Row $n started');
            break;
          case 'row_result':
            final n = (event.data['rowNumber'] as num?)?.toInt() ?? 0;
            final ok = event.data['ok'] == true;
            final status =
                event.data['status'] as String? ?? (ok ? 'ok' : 'failed');
            setState(() {
              final row = _rows[n] ??= _RowState(n);
              row.status = status == 'blocked_captcha'
                  ? RowStatus.blockedCaptcha
                  : ok
                  ? RowStatus.ok
                  : RowStatus.failed;
              row.error = (event.data['error'] as String?) ?? '';
              final done = _rows.values
                  .where(
                    (r) =>
                        r.status != RowStatus.pending &&
                        r.status != RowStatus.running,
                  )
                  .length;
              _statusMessage = 'Completed $done/$_totalRows rows…';
            });
            _append(
              'Row $n: $status${(event.data['error'] as String?)?.isNotEmpty == true ? ' — ${event.data['error']}' : ''}',
            );
            break;
          case 'warning':
            _append('WARNING: ${event.message}');
            break;
          case 'captcha_detected':
            _append(
              'CAPTCHA detected on row ${event.data['rowNumber'] ?? '?'} — manual solve or skip.',
            );
            break;
          case 'awaiting_manual_captcha':
            _append('Awaiting manual CAPTCHA solve in the browser window…');
            setState(
              () => _statusMessage = 'Waiting for manual CAPTCHA solve…',
            );
            break;
          case 'batch_done':
            final summary = Map<String, dynamic>.from(event.data);
            final succeeded = (summary['succeeded'] as num?)?.toInt() ?? 0;
            final failed = (summary['failed'] as num?)?.toInt() ?? 0;
            final total = (summary['totalRows'] as num?)?.toInt() ?? _totalRows;
            setState(() {
              _running = false;
              _summary = summary;
              _statusMessage =
                  'Done: $succeeded ok, $failed failed of $total rows.';
            });
            _append('Batch done: $succeeded succeeded, $failed failed.');
            _recordRun(summary);
            break;
          case 'error':
            setState(() {
              _running = false;
              _statusMessage = 'Error: ${event.message}';
            });
            _append('ERROR: ${event.message}');
            break;
          default:
            if (event.message.isNotEmpty) _append(event.message);
        }
      },
      onDone: () {
        if (mounted && _running) {
          setState(() {
            _running = false;
            _statusMessage = _cancelling
                ? 'Stopped by user.'
                : 'Batch finished.';
          });
        }
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _running = false;
            _statusMessage = 'Error: $e';
          });
          _append('ERROR: $e');
        }
      },
    );
  }

  Future<void> _recordRun(Map<String, dynamic> summary) async {
    final total = (summary['totalRows'] as num?)?.toInt() ?? 0;
    final succeeded = (summary['succeeded'] as num?)?.toInt() ?? 0;
    final failed = (summary['failed'] as num?)?.toInt() ?? 0;
    await _storage.appendRun(
      RunRecord(
        profileId: widget.profile.id,
        profileName: widget.profile.name,
        success: failed == 0 && total > 0,
        steps: widget.profile.steps.length,
        kind: 'batch',
        totalRows: total,
        succeeded: succeeded,
        failed: failed,
      ),
    );
  }

  void _stop() {
    _handle?.stop();
    setState(() => _cancelling = true);
    _append('Stop requested — finishing the current row…');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Color _rowColor(RowStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case RowStatus.ok:
        return scheme.primary;
      case RowStatus.failed:
        return scheme.error;
      case RowStatus.blockedCaptcha:
        return scheme.tertiary;
      case RowStatus.running:
        return scheme.secondary;
      case RowStatus.pending:
        return scheme.outline;
    }
  }

  IconData _rowIcon(RowStatus status) {
    switch (status) {
      case RowStatus.ok:
        return Icons.check_circle;
      case RowStatus.failed:
        return Icons.error;
      case RowStatus.blockedCaptcha:
        return Icons.block;
      case RowStatus.running:
        return Icons.sync;
      case RowStatus.pending:
        return Icons.radio_button_unchecked;
    }
  }

  String _rowLabel(RowStatus status) {
    switch (status) {
      case RowStatus.ok:
        return 'ok';
      case RowStatus.failed:
        return 'failed';
      case RowStatus.blockedCaptcha:
        return 'blocked: captcha';
      case RowStatus.running:
        return 'running';
      case RowStatus.pending:
        return 'pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dataFile = widget.profile.batch.dataFilePath;
    return Scaffold(
      appBar: AppBar(
        title: Text('Batch run: ${widget.profile.name}'),
        actions: [
          if (_running)
            TextButton.icon(
              onPressed: _cancelling ? null : _stop,
              icon: const Icon(Icons.stop),
              label: Text(_cancelling ? 'Stopping…' : 'Stop'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left: options + rows.
            Expanded(
              flex: 5,
              child: ListView(
                children: [
                  if (dataFile.isEmpty)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'No data file attached. Edit the profile and choose '
                          'a CSV or XLSX file first.',
                        ),
                      ),
                    )
                  else
                    Text(
                      'Data: ${dataFile.split(Platform.pathSeparator).last}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Options',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _startRow,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Start row',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _maxRows,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Max rows (0 = all)',
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
                          controller: _rowDelayMin,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Row delay min (ms)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _rowDelayMax,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Row delay max (ms)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Stop on first failed row'),
                    value: _stopOnError,
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _stopOnError = v),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: (_running || dataFile.isEmpty) ? null : _start,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Run batch'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_statusMessage.isNotEmpty) Text(_statusMessage),
                  const SizedBox(height: 8),
                  if (_summary != null)
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Summary',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Rows: ${_summary!['totalRows']} · '
                              'Succeeded: ${_summary!['succeeded']} · '
                              'Failed: ${_summary!['failed']} · '
                              'Blocked by CAPTCHA: ${_summary!['blockedCaptcha'] ?? 0}',
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      _runner.openFolder(_resultsDir),
                                  icon: const Icon(Icons.folder_open_outlined),
                                  label: const Text('Open results folder'),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: _running ? null : _start,
                                  child: const Text('Run again'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  ..._rows.values.map(
                    (row) => Card(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          _rowIcon(row.status),
                          color: _rowColor(row.status, context),
                        ),
                        title: Text('Row ${row.rowNumber}'),
                        subtitle: row.error.isNotEmpty
                            ? Text(
                                row.error,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        trailing: Text(_rowLabel(row.status)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 24),
            // Right: live log.
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Log', style: Theme.of(context).textTheme.titleMedium),
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
          ],
        ),
      ),
    );
  }
}
