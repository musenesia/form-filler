import 'package:flutter/material.dart';

import '../models/run_record.dart';
import '../services/storage_service.dart';

/// Simple list of past runs from runs.jsonl.
class RunHistoryScreen extends StatefulWidget {
  const RunHistoryScreen({super.key});

  @override
  State<RunHistoryScreen> createState() => _RunHistoryScreenState();
}

class _RunHistoryScreenState extends State<RunHistoryScreen> {
  final _storage = StorageService.instance;
  List<RunRecord> _runs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final runs = await _storage.loadRuns();
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run history')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _runs.isEmpty
          ? const Center(child: Text('No runs recorded yet.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _runs.length,
              itemBuilder: (context, i) {
                final r = _runs[i];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      r.success ? Icons.check_circle : Icons.error_outline,
                      color: r.success
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(r.profileName),
                    subtitle: Text(
                      '${_formatDate(r.startedAt)} · ${r.kind == 'batch' ? 'batch: ${r.totalRows} rows (${r.succeeded} ok, ${r.failed} failed)' : '${r.steps} steps'}'
                      '${r.success ? '' : '\n${r.error}'}',
                    ),
                    isThreeLine: !r.success,
                  ),
                );
              },
            ),
    );
  }

  String _formatDate(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
