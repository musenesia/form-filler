import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/fill_profile.dart';
import '../models/run_record.dart';

/// Local persistence under the app-support directory:
/// (`form_filler` subfolder).
///
/// In widget tests, set [inMemoryForTests] to true to use an in-memory store
/// instead of touching the real filesystem (real async I/O does not complete
/// inside flutter_test's fake async zone).
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static bool _inMemoryForTests = false;

  /// Switch to an in-memory store for tests. Resets any stored state.
  @visibleForTesting
  static set inMemoryForTests(bool value) {
    _inMemoryForTests = value;
    if (value) {
      instance._resetMemory();
    }
  }

  Directory? _baseDir;

  // In-memory store (tests only).
  List<FillProfile> _memoryProfiles = [];
  AppSettings _memorySettings = AppSettings();
  final Map<String, DateTime> _memorySessions = {};
  final List<RunRecord> _memoryRuns = [];

  void _resetMemory() {
    _memoryProfiles = [];
    _memorySettings = AppSettings();
    _memorySessions.clear();
    _memoryRuns.clear();
    _baseDir = null;
  }

  Future<Directory> get _base async {
    if (_baseDir != null) return _baseDir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}form_filler',
    );
    await dir.create(recursive: true);
    _baseDir = dir;
    return dir;
  }

  /// App data directory. In tests, a temp path is returned without I/O.
  Future<Directory> get baseDir async =>
      _inMemoryForTests ? Directory.systemTemp : _base;

  Future<Directory> get sessionsDir async {
    if (_inMemoryForTests) return Directory.systemTemp;
    final dir = Directory(
      '${(await _base).path}${Platform.pathSeparator}sessions',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> get screenshotsDir async {
    if (_inMemoryForTests) return Directory.systemTemp;
    final dir = Directory(
      '${(await _base).path}${Platform.pathSeparator}screenshots',
    );
    await dir.create(recursive: true);
    return dir;
  }

  // ---------- Profiles ----------

  Future<List<FillProfile>> loadProfiles() async {
    if (_inMemoryForTests) {
      return _memoryProfiles
          .map((p) => FillProfile.fromJson(p.toJson()))
          .toList();
    }
    final file = File(
      '${(await _base).path}${Platform.pathSeparator}profiles.json',
    );
    if (!await file.exists()) return [];
    try {
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => FillProfile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<FillProfile> profiles) async {
    if (_inMemoryForTests) {
      _memoryProfiles = profiles
          .map((p) => FillProfile.fromJson(p.toJson()))
          .toList();
      return;
    }
    final file = File(
      '${(await _base).path}${Platform.pathSeparator}profiles.json',
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(profiles.map((p) => p.toJson()).toList()),
    );
  }

  // ---------- Settings ----------

  Future<AppSettings> loadSettings() async {
    if (_inMemoryForTests) {
      return AppSettings.fromJson(_memorySettings.toJson());
    }
    final file = File(
      '${(await _base).path}${Platform.pathSeparator}settings.json',
    );
    if (!await file.exists()) return AppSettings();
    try {
      final raw = await file.readAsString();
      return AppSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    if (_inMemoryForTests) {
      _memorySettings = AppSettings.fromJson(settings.toJson());
      return;
    }
    final file = File(
      '${(await _base).path}${Platform.pathSeparator}settings.json',
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }

  // ---------- Sessions ----------

  Future<String?> sessionPath(String profileId) async {
    if (_inMemoryForTests) {
      return _memorySessions.containsKey(profileId)
          ? 'memory:$profileId'
          : null;
    }
    final file = File(
      '${(await sessionsDir).path}${Platform.pathSeparator}$profileId.json',
    );
    return await file.exists() ? file.path : null;
  }

  Future<DateTime?> sessionModified(String profileId) async {
    if (_inMemoryForTests) return _memorySessions[profileId];
    final path = await sessionPath(profileId);
    if (path == null) return null;
    return File(path).lastModified();
  }

  Future<void> deleteSession(String profileId) async {
    if (_inMemoryForTests) {
      _memorySessions.remove(profileId);
      return;
    }
    final path = await sessionPath(profileId);
    if (path != null) await File(path).delete();
  }

  // ---------- Run history ----------

  Future<void> appendRun(RunRecord record) async {
    if (_inMemoryForTests) {
      _memoryRuns.add(RunRecord.fromJson(record.toJson()));
      return;
    }
    final file = File(
      '${(await _base).path}${Platform.pathSeparator}runs.jsonl',
    );
    await file.writeAsString(
      '${jsonEncode(record.toJson())}\n',
      mode: FileMode.append,
    );
  }

  Future<List<RunRecord>> loadRuns({int limit = 200}) async {
    if (_inMemoryForTests) {
      return _memoryRuns.reversed.take(limit).toList();
    }
    final file = File(
      '${(await _base).path}${Platform.pathSeparator}runs.jsonl',
    );
    if (!await file.exists()) return [];
    try {
      final lines = await file.readAsLines();
      final records = <RunRecord>[];
      for (final line in lines.reversed) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          records.add(
            RunRecord.fromJson(
              Map<String, dynamic>.from(jsonDecode(trimmed) as Map),
            ),
          );
        } catch (_) {
          // Skip corrupt lines.
        }
        if (records.length >= limit) break;
      }
      return records;
    } catch (_) {
      return [];
    }
  }
}
