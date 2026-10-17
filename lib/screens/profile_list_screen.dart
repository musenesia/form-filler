import 'package:flutter/material.dart';

import '../models/fill_profile.dart';
import '../services/storage_service.dart';
import 'batch_run_screen.dart';
import 'history_screen.dart';
import 'profile_editor_screen.dart';
import 'run_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';

/// Home screen: the list of saved fill profiles.
class ProfileListScreen extends StatefulWidget {
  const ProfileListScreen({super.key});

  @override
  State<ProfileListScreen> createState() => _ProfileListScreenState();
}

class _ProfileListScreenState extends State<ProfileListScreen> {
  final _storage = StorageService.instance;
  List<FillProfile> _profiles = [];
  Map<String, bool> _hasSession = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final profiles = await _storage.loadProfiles();
    final sessions = <String, bool>{};
    for (final p in profiles) {
      sessions[p.id] = await _storage.sessionPath(p.id) != null;
    }
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _hasSession = sessions;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _storage.saveProfiles(_profiles);
  }

  Future<void> _openEditor(FillProfile? profile) async {
    FillProfile? toEdit = profile;
    if (toEdit == null) {
      // New profiles inherit the humanization defaults from Settings.
      final settings = await _storage.loadSettings();
      if (!mounted) return;
      toEdit = FillProfile(
        name: '',
        url: '',
        humanize: settings.humanizeDefaults.copy(),
      );
    }
    final result = await Navigator.of(context).push<FillProfile>(
      MaterialPageRoute(builder: (_) => ProfileEditorScreen(profile: toEdit)),
    );
    if (result == null) return;
    setState(() {
      final index = _profiles.indexWhere((p) => p.id == result.id);
      if (index >= 0) {
        _profiles[index] = result;
      } else {
        _profiles.add(result);
      }
    });
    await _save();
    await _reload();
  }

  Future<void> _delete(FillProfile profile) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('Delete "${profile.name}" and its steps?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _profiles.removeWhere((p) => p.id == profile.id));
    await _save();
  }

  void _run(FillProfile profile) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RunScreen(profile: profile)));
  }

  void _batchRun(FillProfile profile) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => BatchRunScreen(profile: profile)));
  }

  void _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Filler'),
        actions: [
          IconButton(
            tooltip: 'Login sessions',
            icon: const Icon(Icons.key_outlined),
            onPressed: () => _push(const SessionsScreen()),
          ),
          IconButton(
            tooltip: 'Run history',
            icon: const Icon(Icons.history),
            onPressed: () => _push(const RunHistoryScreen()),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _push(const SettingsScreen()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(null),
        icon: const Icon(Icons.add),
        label: const Text('New profile'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.assignment_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No profiles yet',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Create a profile for a website you are authorized to use, '
                      'add fill steps (or scan the page to discover fields), '
                      'then run it.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _profiles.length,
              itemBuilder: (context, i) {
                final p = _profiles[i];
                final session = _hasSession[p.id] ?? false;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    leading: session
                        ? Icon(
                            Icons.verified_user_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : const Icon(Icons.web_asset_outlined),
                    title: Text(p.name),
                    subtitle: Text(
                      '${p.url}\n${p.steps.length} step${p.steps.length == 1 ? '' : 's'}'
                      '${session ? ' · logged in' : ''}',
                    ),
                    isThreeLine: true,
                    trailing: Wrap(
                      spacing: 0,
                      children: [
                        IconButton(
                          tooltip: 'Run',
                          icon: const Icon(Icons.play_arrow),
                          color: Theme.of(context).colorScheme.primary,
                          onPressed: () => _run(p),
                        ),
                        IconButton(
                          tooltip: 'Batch run (data file)',
                          icon: const Icon(Icons.table_rows_outlined),
                          onPressed: () => _batchRun(p),
                        ),
                        IconButton(
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _openEditor(p),
                        ),
                        IconButton(
                          tooltip: 'Duplicate',
                          icon: const Icon(Icons.copy_outlined),
                          onPressed: () async {
                            setState(() => _profiles.add(p.duplicate()));
                            await _save();
                          },
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(p),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
