import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/fill_profile.dart';
import '../models/scan_field.dart';
import '../services/data_file_service.dart';
import '../services/runner_service.dart';
import '../services/storage_service.dart';

/// Edit a profile: its URLs and its ordered list of steps.
class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({super.key, this.profile});

  final FillProfile? profile;

  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  final _storage = StorageService.instance;
  final _runner = RunnerService.instance;

  late FillProfile _profile;
  late TextEditingController _name;
  late TextEditingController _url;
  late TextEditingController _loginUrl;

  bool _scanning = false;
  String _scanStatus = '';
  List<ScannedField> _scanFields = [];
  StreamSubscription<RunnerEvent>? _scanSub;

  // Data file (batch) state.
  late TextEditingController _sheet;
  List<String> _dataColumns = [];
  List<List<String>> _dataPreviewRows = [];
  int _dataTotalRows = 0;
  String _dataError = '';
  bool _loadingPreview = false;
  Map<String, String> _firstRow = {};

  @override
  void initState() {
    super.initState();
    _profile = widget.profile != null
        ? FillProfile.fromJson(widget.profile!.toJson())
        : FillProfile(name: '', url: '');
    _name = TextEditingController(text: _profile.name);
    _url = TextEditingController(text: _profile.url);
    _loginUrl = TextEditingController(text: _profile.loginUrl);
    _sheet = TextEditingController(text: _profile.batch.sheet);
    _loadDataPreview();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _loginUrl.dispose();
    _sheet.dispose();
    _scanSub?.cancel();
    super.dispose();
  }

  void _saveAndClose() {
    _profile.name = _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim();
    _profile.url = _url.text.trim();
    _profile.loginUrl = _loginUrl.text.trim();
    _profile.batch.sheet = _sheet.text.trim();
    Navigator.of(context).pop(_profile);
  }

  Future<void> _pickDataFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx'],
    );
    final path = file?.path;
    if (path == null) return;
    setState(() {
      _profile.batch.dataFilePath = path;
    });
    await _loadDataPreview();
  }

  void _clearDataFile() {
    setState(() {
      _profile.batch.dataFilePath = '';
      _dataColumns = [];
      _dataPreviewRows = [];
      _dataTotalRows = 0;
      _dataError = '';
      _firstRow = {};
    });
  }

  Future<void> _loadDataPreview() async {
    final path = _profile.batch.dataFilePath.trim();
    if (path.isEmpty) return;
    setState(() {
      _loadingPreview = true;
      _dataError = '';
    });
    try {
      final preview = await DataFileService.instance.preview(
        path,
        sheet: _profile.batch.sheet,
      );
      final first = await DataFileService.instance.firstRow(
        path,
        sheet: _profile.batch.sheet,
      );
      if (!mounted) return;
      setState(() {
        _dataColumns = preview.columns;
        _dataPreviewRows = preview.rows;
        _dataTotalRows = preview.totalRows;
        _firstRow = first;
        _loadingPreview = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dataError = '$e'.replaceFirst('Exception: ', '');
        _loadingPreview = false;
        _dataColumns = [];
        _dataPreviewRows = [];
        _firstRow = {};
      });
    }
  }

  /// Render {{ColumnName}} placeholders using the first data row.
  String _substitute(String template) {
    if (_firstRow.isEmpty) return template;
    return template.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (m) {
      final key = m.group(1)!.trim();
      return _firstRow[key] ?? m.group(0)!;
    });
  }

  bool _stepUsesPlaceholders(FieldStep step) {
    final combined = '${step.value} ${step.selector} ${step.url}';
    return combined.contains('{{');
  }

  Future<void> _editStep(FieldStep? step) async {
    final result = await showDialog<FieldStep>(
      context: context,
      builder: (_) => StepEditorDialog(step: step, columns: _dataColumns),
    );
    if (result == null) return;
    setState(() {
      final index = _profile.steps.indexWhere((s) => s.id == result.id);
      if (index >= 0) {
        _profile.steps[index] = result;
      } else {
        _profile.steps.add(result);
      }
    });
  }

  Future<void> _scanPage() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      _snack('Enter the page URL first.');
      return;
    }
    setState(() {
      _scanning = true;
      _scanStatus = 'Starting scan…';
      _scanFields = [];
    });

    final settings = await _storage.loadSettings();
    final runnerDir = await _runner.resolveRunnerDir(settings);
    if (runnerDir == null) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanStatus = 'Runner directory not found — check Settings.';
      });
      return;
    }
    final sessionPath = await _storage.sessionPath(_profile.id);
    await _scanSub?.cancel();
    _scanSub = _runner
        .scan(settings, runnerDir, url, storagePath: sessionPath)
        .listen(
          (event) {
            if (!mounted) return;
            setState(() {
              switch (event.kind) {
                case 'info':
                case 'progress':
                case 'log':
                  _scanStatus = event.message;
                  break;
                case 'field':
                  _scanStatus =
                      'Found ${_scanFields.length + 1} fields… (${event.message})';
                  break;
                case 'result':
                  final fields = (event.data['fields'] as List?) ?? [];
                  _scanFields = fields
                      .map(
                        (e) => ScannedField.fromJson(
                          Map<String, dynamic>.from(e as Map),
                        ),
                      )
                      .toList();
                  _scanStatus = 'Found ${_scanFields.length} fields.';
                  _scanning = false;
                  break;
                case 'error':
                  _scanStatus = 'Error: ${event.message}';
                  _scanning = false;
                  break;
              }
            });
          },
          onDone: () {
            if (mounted && _scanning) {
              setState(() {
                _scanning = false;
                if (_scanStatus.isEmpty || _scanStatus == 'Starting scan…') {
                  _scanStatus = 'Scan finished.';
                }
              });
            }
          },
          onError: (Object e) {
            if (mounted) {
              setState(() {
                _scanning = false;
                _scanStatus = 'Error: $e';
              });
            }
          },
        );
  }

  void _addFieldAsStep(ScannedField field) {
    final selector = field.css.isNotEmpty ? field.css : field.xpath;
    final selectorType = field.css.isNotEmpty ? 'css' : 'xpath';
    String action = 'fill';
    if (field.tag == 'select') {
      action = 'select';
    } else if (field.type == 'checkbox') {
      action = 'check';
    } else if (field.tag == 'button') {
      action = 'click';
    }
    setState(() {
      _profile.steps.add(
        FieldStep(
          action: action,
          selector: selector,
          selectorType: selectorType,
          note: field.displayName,
        ),
      );
    });
  }

  void _addAllFields() {
    for (final f in _scanFields) {
      _addFieldAsStep(f);
    }
    _snack('Added ${_scanFields.length} steps.');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildDataCard() {
    final dataPath = _profile.batch.dataFilePath;
    final fileName = dataPath.isEmpty
        ? ''
        : dataPath.split(Platform.pathSeparator).last;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Data file (batch runs)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Attach a CSV or Excel file to fill the form once per row. '
              'Use {{ColumnName}} in step values, selectors or URLs.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    fileName.isEmpty ? 'No file selected' : fileName,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickDataFile,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Choose file'),
                ),
                if (fileName.isNotEmpty)
                  IconButton(
                    tooltip: 'Remove data file',
                    icon: const Icon(Icons.close),
                    onPressed: _clearDataFile,
                  ),
              ],
            ),
            if (fileName.isNotEmpty && _profile.batch.isXlsx) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _sheet,
                  decoration: const InputDecoration(
                    labelText: 'Sheet name (empty = first sheet)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _loadDataPreview(),
                ),
              ),
            ],
            if (_loadingPreview)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              ),
            if (_dataError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _dataError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_dataColumns.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${_dataColumns.length} columns · $_dataTotalRows data rows',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 32,
                  dataRowMinHeight: 28,
                  dataRowMaxHeight: 32,
                  columns: _dataColumns
                      .map(
                        (c) => DataColumn(
                          label: Text(
                            c,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      )
                      .toList(),
                  rows: _dataPreviewRows
                      .map(
                        (row) => DataRow(
                          cells: row
                              .map(
                                (cell) => DataCell(
                                  Text(
                                    cell,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
            if (_firstRow.isNotEmpty &&
                _profile.steps.any(_stepUsesPlaceholders)) ...[
              const SizedBox(height: 12),
              Text(
                'First-row preview',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              ..._profile.steps
                  .where(_stepUsesPlaceholders)
                  .map(
                    (s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '• ${_substitute(s.describe())}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile == null ? 'New profile' : 'Edit profile'),
        actions: [
          TextButton.icon(
            onPressed: _saveAndClose,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left: profile fields + steps.
          Expanded(
            flex: 5,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Profile name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'Page URL',
                    hintText: 'https://example.com/form',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _loginUrl,
                  decoration: const InputDecoration(
                    labelText: 'Login URL (optional)',
                    hintText: 'https://example.com/login',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                _buildDataCard(),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Human-like execution'),
                  subtitle: const Text(
                    'Random delays, human typing, human-like mouse moves, '
                    'stealth evasions (from Settings defaults).',
                  ),
                  value: _profile.humanize.enabled,
                  onChanged: (v) =>
                      setState(() => _profile.humanize.enabled = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Steps',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: () => _editStep(null),
                      icon: const Icon(Icons.add),
                      label: const Text('Add step'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_profile.steps.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No steps yet. Add steps manually, or scan the page '
                      'and add discovered fields.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _profile.steps.length,
                    onReorderItem: (oldIndex, newIndex) {
                      setState(() {
                        final step = _profile.steps.removeAt(oldIndex);
                        _profile.steps.insert(newIndex, step);
                      });
                    },
                    itemBuilder: (context, i) {
                      final step = _profile.steps[i];
                      return Card(
                        key: ValueKey(step.id),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 14,
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          title: Text(step.describe()),
                          subtitle: step.note.isNotEmpty
                              ? Text(step.note)
                              : null,
                          trailing: Wrap(
                            spacing: 0,
                            children: [
                              IconButton(
                                tooltip: 'Edit step',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _editStep(step.copy()),
                              ),
                              IconButton(
                                tooltip: 'Delete step',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    setState(() => _profile.steps.removeAt(i)),
                              ),
                              const Icon(Icons.drag_handle),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          // Right: page scanner.
          Expanded(
            flex: 5,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Page scanner',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Loads the page URL in a headless browser and lists the '
                  'form fields it finds. Uses the saved login session if one exists.',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _scanning ? null : _scanPage,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.radar),
                      label: Text(_scanning ? 'Scanning…' : 'Scan page'),
                    ),
                    const SizedBox(width: 12),
                    if (_scanFields.isNotEmpty && !_scanning)
                      OutlinedButton.icon(
                        onPressed: _addAllFields,
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Add all as steps'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_scanStatus.isNotEmpty)
                  Text(
                    _scanStatus,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                ..._scanFields.map(
                  (f) => Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      title: Text(f.displayName),
                      subtitle: Text(
                        '${f.kindLabel} · ${f.css.isNotEmpty ? f.css : f.xpath}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Add as fill step',
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          _addFieldAsStep(f);
                          _snack('Added "${f.displayName}" as a step.');
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog to add or edit a single [FieldStep].
class StepEditorDialog extends StatefulWidget {
  const StepEditorDialog({super.key, this.step, this.columns = const []});

  final FieldStep? step;

  /// Data-file column names for {{Column}} placeholder insertion.
  final List<String> columns;

  @override
  State<StepEditorDialog> createState() => _StepEditorDialogState();
}

class _StepEditorDialogState extends State<StepEditorDialog> {
  late FieldStep _step;
  late TextEditingController _selector;
  late TextEditingController _value;
  late TextEditingController _key;
  late TextEditingController _url;
  late TextEditingController _timeout;
  late TextEditingController _note;

  @override
  void initState() {
    super.initState();
    _step = widget.step?.copy() ?? FieldStep(action: 'fill');
    _selector = TextEditingController(text: _step.selector);
    _value = TextEditingController(text: _step.value);
    _key = TextEditingController(text: _step.key);
    _url = TextEditingController(text: _step.url);
    _timeout = TextEditingController(text: _step.timeoutMs.toString());
    _note = TextEditingController(text: _step.note);
  }

  @override
  void dispose() {
    _selector.dispose();
    _value.dispose();
    _key.dispose();
    _url.dispose();
    _timeout.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    _step.selector = _selector.text.trim();
    _step.value = _value.text;
    _step.key = _key.text.trim();
    _step.url = _url.text.trim();
    _step.timeoutMs = int.tryParse(_timeout.text.trim()) ?? 30000;
    _step.note = _note.text.trim();
    Navigator.of(context).pop(_step);
  }

  void _insertColumnPlaceholder(String column) {
    final text = _value.text;
    final sel = _value.selection;
    final pos = sel.isValid ? sel.end : text.length;
    final placeholder = '{{$column}}';
    final updated = text.replaceRange(pos, pos, placeholder);
    _value.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: pos + placeholder.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needsSelector = FieldStep.selectorActions.contains(_step.action);
    final needsValue = FieldStep.valueActions.contains(_step.action);
    return AlertDialog(
      title: Text(widget.step == null ? 'Add step' : 'Edit step'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _step.action,
                decoration: const InputDecoration(
                  labelText: 'Action',
                  border: OutlineInputBorder(),
                ),
                items: FieldStep.actions
                    .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _step.action = v);
                },
              ),
              const SizedBox(height: 12),
              if (_step.action == 'goto')
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    border: OutlineInputBorder(),
                  ),
                ),
              if (needsSelector) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _selector,
                        decoration: const InputDecoration(
                          labelText: 'Selector',
                          hintText: '#email or //input[@name="q"]',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _step.selectorType,
                      items: const [
                        DropdownMenuItem(value: 'css', child: Text('CSS')),
                        DropdownMenuItem(value: 'xpath', child: Text('XPath')),
                        DropdownMenuItem(value: 'text', child: Text('Text')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _step.selectorType = v);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (needsValue)
                TextField(
                  controller: _value,
                  maxLines: _step.action == 'screenshot' ? 1 : 3,
                  decoration: InputDecoration(
                    labelText: _labelForValue(),
                    hintText: widget.columns.isNotEmpty
                        ? 'Supports {{ColumnName}} placeholders'
                        : null,
                    border: const OutlineInputBorder(),
                    suffixIcon: widget.columns.isEmpty
                        ? null
                        : PopupMenuButton<String>(
                            tooltip: 'Insert data column',
                            icon: const Icon(Icons.table_chart_outlined),
                            onSelected: _insertColumnPlaceholder,
                            itemBuilder: (context) => widget.columns
                                .map(
                                  (c) => PopupMenuItem(
                                    value: c,
                                    child: Text('{{$c}}'),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ),
              if (needsValue) const SizedBox(height: 12),
              if (_step.action == 'press')
                TextField(
                  controller: _key,
                  decoration: const InputDecoration(
                    labelText: 'Key (e.g. Enter, Tab, Escape)',
                    border: OutlineInputBorder(),
                  ),
                ),
              if (_step.action == 'press') const SizedBox(height: 12),
              TextField(
                controller: _timeout,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Timeout (ms)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save step')),
      ],
    );
  }

  String _labelForValue() {
    switch (_step.action) {
      case 'select':
        return 'Option value (or label)';
      case 'waitForTimeout':
        return 'Milliseconds';
      case 'screenshot':
        return 'File path (optional)';
      default:
        return 'Value';
    }
  }
}
