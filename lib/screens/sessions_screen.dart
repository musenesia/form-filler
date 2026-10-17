import 'dart:async';

import 'package:flutter/material.dart';

import '../models/fill_profile.dart';
import '../services/runner_service.dart';
import '../services/storage_service.dart';

/// Manage per-profile login sessions (saved browser storage state).
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _storage = StorageService.instance;
  final _runner = RunnerService.instance;

  List<FillProfile> _profiles = [];
  Map<String, DateTime?> _sessions = {};
  bool _loading = true;

  LoginSession? _active;
  String _activeProfileId = '';
  final List<String> _loginLog = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _active?.kill();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final profiles = await _storage.loadProfiles();
    final sessions = <String, DateTime?>{};
    for (final p in profiles) {
      sessions[p.id] = await _storage.sessionModified(p.id);
    }
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _sessions = sessions;
      _loading = false;
    });
  }

  Future<void> _startLogin(FillProfile profile) async {
    if (profile.loginUrl.trim().isEmpty) {
      _snack('Set a login URL for "${profile.name}" first (edit the profile).');
      return;
    }
    final settings = await _storage.loadSettings();
    final runnerDir = await _runner.resolveRunnerDir(settings);
    if (runnerDir == null) {
      _snack('Runner directory not found — check Settings.');
      return;
    }
    final sessionsDir = await _storage.sessionsDir;
    final statePath = '${sessionsDir.path}/${profile.id}.json';
    try {
      final session = await _runner.startLogin(
        settings,
        runnerDir,
        profile.loginUrl,
        statePath,
      );
      setState(() {
        _active = session;
        _activeProfileId = profile.id;
        _loginLog.clear();
      });
      session.events.listen(
        (event) {
          if (!mounted) return;
          setState(() => _loginLog.add(event.message));
        },
        onDone: () async {
          if (!mounted) return;
          setState(() => _active = null);
          await _reload();
          _snack('Login window closed for "${profile.name}".');
        },
      );
    } catch (e) {
      _snack('Could not open login browser: $e');
    }
  }

  Future<void> _doneLogin() async {
    final session = _active;
    if (session == null) return;
    session.done();
    // Give login.js a moment to write the state file, then close the stream.
    await Future.delayed(const Duration(seconds: 2));
    await session.kill();
    if (!mounted) return;
    setState(() => _active = null);
    await _reload();
  }

  Future<void> _deleteSession(FillProfile profile) async {
    await _storage.deleteSession(profile.id);
    await _reload();
    _snack('Session deleted for "${profile.name}".');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login sessions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Log in once per site in a real browser window; the session '
                  '(cookies, local storage) is saved locally and reused by scans and runs.',
                ),
                const SizedBox(height: 12),
                ..._profiles.map((p) {
                  final modified = _sessions[p.id];
                  final isActive = _activeProfileId == p.id && _active != null;
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p.name,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    Text(
                                      modified != null
                                          ? 'Logged in · saved ${_formatDate(modified)}'
                                          : 'No session saved',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              if (isActive)
                                FilledButton.icon(
                                  onPressed: _doneLogin,
                                  icon: const Icon(Icons.check),
                                  label: const Text('Done — save session'),
                                )
                              else
                                FilledButton.tonalIcon(
                                  onPressed: _active != null
                                      ? null
                                      : () => _startLogin(p),
                                  icon: const Icon(Icons.login),
                                  label: const Text('Log in'),
                                ),
                              const SizedBox(width: 8),
                              if (modified != null && !isActive)
                                IconButton(
                                  tooltip: 'Delete session',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _deleteSession(p),
                                ),
                            ],
                          ),
                          if (isActive) ...[
                            const SizedBox(height: 8),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 140),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ListView.builder(
                                padding: const EdgeInsets.all(8),
                                itemCount: _loginLog.length,
                                itemBuilder: (context, i) => Text(
                                  _loginLog[i],
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'A browser window opened. Log in there, then press '
                              '"Done — save session".',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ],
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
