import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/app_settings.dart';
import '../models/fill_profile.dart';
import 'storage_service.dart';

/// Event streamed from a runner script (JSONL over stdout).
class RunnerEvent {
  RunnerEvent(this.kind, this.message, {this.data = const {}});

  /// log | progress | info | field | result | error | step | data
  final String kind;
  final String message;
  final Map<String, dynamic> data;
}

/// Handle to a running login browser window.
class LoginSession {
  LoginSession(this.process, this.events, this.statePath);

  final Process process;
  final Stream<RunnerEvent> events;
  final String statePath;

  /// Tell login.js the user is done so it saves the session.
  void done() {
    try {
      process.stdin.writeln('done');
    } catch (_) {}
  }

  Future<void> kill() async {
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}

/// Handle to a running batch process.
class BatchHandle {
  BatchHandle(this.process, this.events, this.resultsDir);

  final Process process;
  final Stream<RunnerEvent> events;
  final String resultsDir;

  /// Ask batch.js to finish the current row and exit gracefully.
  void stop() {
    try {
      process.stdin.writeln('stop');
    } catch (_) {}
  }

  Future<void> kill() async {
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }
}

class PreflightResult {
  PreflightResult(this.ok, this.messages);

  final bool ok;
  final List<String> messages;
}

/// Spawns the local Node.js Playwright runner scripts and parses their JSONL.
class RunnerService {
  RunnerService._();
  static final RunnerService instance = RunnerService._();

  String _nodeExecutable(AppSettings s) =>
      s.nodePath.trim().isNotEmpty ? s.nodePath.trim() : _nodeOnPath();

  String _nodeOnPath() {
    if (Platform.isWindows) return 'node.exe';
    return 'node';
  }

  /// Resolve the runner directory: Settings override, then auto-detect.
  Future<String?> resolveRunnerDir(AppSettings settings) async {
    final override = settings.runnerDir.trim();
    if (override.isNotEmpty) {
      final dir = Directory(override);
      if (await dir.exists()) return dir.path;
      return null;
    }
    final candidates = <String>[];
    // 1. Current working directory (flutter run from project root).
    candidates.add('${Directory.current.path}${Platform.pathSeparator}runner');
    // 2. Next to the app executable.
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir${Platform.pathSeparator}runner');
      candidates.add(
        '$exeDir${Platform.pathSeparator}..${Platform.pathSeparator}runner',
      );
    } catch (_) {}
    for (final c in candidates) {
      final dir = Directory(c);
      if (!await dir.exists()) continue;
      if (await File('${dir.path}${Platform.pathSeparator}fill.js').exists()) {
        return dir.path;
      }
    }
    return null;
  }

  Stream<RunnerEvent> _streamFor(Process process) {
    final controller = StreamController<RunnerEvent>();
    final buffer = StringBuffer();
    void handleLine(String line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      try {
        final obj = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
        final type = (obj['type'] as String?) ?? 'log';
        final message =
            (obj['message'] as String?) ??
            (obj['action'] != null ? '${obj['action']}' : '');
        controller.add(RunnerEvent(type, message, data: obj));
      } catch (_) {
        controller.add(RunnerEvent('log', trimmed));
      }
    }

    process.stdout.transform(utf8.decoder).listen((chunk) {
      buffer.write(chunk);
      final text = buffer.toString();
      final lines = text.split('\n');
      buffer.clear();
      buffer.write(lines.removeLast());
      for (final line in lines) {
        handleLine(line);
      }
    });
    process.stderr.transform(utf8.decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) controller.add(RunnerEvent('log', 'stderr: $t'));
      }
    });
    unawaited(
      process.exitCode.then((code) {
        final rest = buffer.toString().trim();
        if (rest.isNotEmpty) handleLine(rest);
        controller.close();
      }),
    );
    return controller.stream;
  }

  Stream<RunnerEvent> _spawn(
    AppSettings settings,
    String runnerDir,
    String script,
    List<String> args, {
    Map<String, String>? env,
  }) async* {
    Process process;
    try {
      process = await Process.start(
        _nodeExecutable(settings),
        [script, ...args],
        workingDirectory: runnerDir,
        environment: env,
      );
    } catch (e) {
      yield RunnerEvent('error', 'Could not start Node: $e');
      return;
    }
    yield* _streamFor(process);
  }

  /// Scan a page and stream scan events. The final 'result' event carries fields.
  Stream<RunnerEvent> scan(
    AppSettings settings,
    String runnerDir,
    String url, {
    String? storagePath,
  }) {
    final args = ['--url', url];
    if (storagePath != null && storagePath.isNotEmpty) {
      args.addAll(['--storage', storagePath]);
    }
    return _spawn(settings, runnerDir, 'scan.js', args);
  }

  /// Run a fill job. Returns the event stream; the final 'result' event has the outcome.
  Stream<RunnerEvent> fill(
    AppSettings settings,
    String runnerDir,
    FillProfile profile, {
    String? storagePath,
    String? screenshotDir,
  }) async* {
    final job = profile.toJobMap(
      storagePath: storagePath,
      screenshotDir: screenshotDir,
    );
    final tmp = await Directory.systemTemp.createTemp('form_filler_job_');
    final jobFile = File('${tmp.path}${Platform.pathSeparator}job.json');
    await jobFile.writeAsString(jsonEncode(job));
    try {
      yield* _spawn(settings, runnerDir, 'fill.js', ['--job', jobFile.path]);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Run a data-driven batch. Returns a handle: listen to [BatchHandle.events]
  /// and call [BatchHandle.stop] for a graceful stop. The job file is kept in
  /// the results directory for inspection.
  Future<BatchHandle> runBatch(
    AppSettings settings,
    String runnerDir,
    FillProfile profile, {
    String? storagePath,
    int? startRow,
    int? maxRows,
    int? rowDelayMinMs,
    int? rowDelayMaxMs,
    bool? stopOnError,
  }) async {
    final batch = profile.batch;
    final dataFile = batch.dataFilePath.trim();
    if (dataFile.isEmpty) {
      throw Exception('No data file selected for this profile.');
    }
    final job = profile.toJobMap(storagePath: storagePath);

    final base = await StorageService.instance.baseDir;
    final resultsDir = Directory(
      '${base.path}${Platform.pathSeparator}batch_results'
      '${Platform.pathSeparator}${profile.id}_${DateTime.now().millisecondsSinceEpoch}',
    );
    await resultsDir.create(recursive: true);
    final jobFile = File('${resultsDir.path}${Platform.pathSeparator}job.json');
    await jobFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(job),
    );

    final args = <String>[
      '--job',
      jobFile.path,
      '--data',
      dataFile,
      '--results',
      resultsDir.path,
    ];
    final sr = startRow ?? batch.startRow;
    if (sr > 1) args.addAll(['--start-row', '$sr']);
    final mr = maxRows ?? batch.maxRows;
    if (mr > 0) args.addAll(['--max-rows', '$mr']);
    if (batch.sheet.trim().isNotEmpty) {
      args.addAll(['--sheet', batch.sheet.trim()]);
    }
    final rMin = rowDelayMinMs ?? batch.rowDelayMinMs;
    final rMax = rowDelayMaxMs ?? batch.rowDelayMaxMs;
    args.addAll(['--row-delay-min', '$rMin', '--row-delay-max', '$rMax']);
    if (stopOnError ?? batch.stopOnError) args.add('--stop-on-error');

    final process = await Process.start(_nodeExecutable(settings), [
      'batch.js',
      ...args,
    ], workingDirectory: runnerDir);
    return BatchHandle(process, _streamFor(process), resultsDir.path);
  }

  /// Open a folder in the OS file manager.
  Future<void> openFolder(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else {
        await Process.start('xdg-open', [path]);
      }
    } catch (_) {}
  }

  /// Open a headed browser for login; call [LoginSession.done] when finished.
  Future<LoginSession> startLogin(
    AppSettings settings,
    String runnerDir,
    String url,
    String statePath,
  ) async {
    final process = await Process.start(_nodeExecutable(settings), [
      'login.js',
      '--url',
      url,
      '--state',
      statePath,
    ], workingDirectory: runnerDir);
    final controller = StreamController<RunnerEvent>.broadcast();
    final buffer = StringBuffer();
    void handleLine(String line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      try {
        final obj = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
        final type = (obj['type'] as String?) ?? 'log';
        controller.add(
          RunnerEvent(type, (obj['message'] as String?) ?? '', data: obj),
        );
      } catch (_) {
        controller.add(RunnerEvent('log', trimmed));
      }
    }

    process.stdout.transform(utf8.decoder).listen((chunk) {
      buffer.write(chunk);
      final text = buffer.toString();
      final lines = text.split('\n');
      buffer.clear();
      buffer.write(lines.removeLast());
      for (final line in lines) {
        handleLine(line);
      }
    });
    process.stderr.transform(utf8.decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) controller.add(RunnerEvent('log', 'stderr: $t'));
      }
    });
    unawaited(process.exitCode.then((_) => controller.close()));
    return LoginSession(process, controller.stream, statePath);
  }

  Future<PreflightResult> preflight(AppSettings settings) async {
    final messages = <String>[];
    var ok = true;

    // 1. Node executable.
    try {
      final r = await Process.run(_nodeExecutable(settings), ['--version']);
      if (r.exitCode == 0) {
        messages.add('Node: ${(r.stdout as String).trim()}');
      } else {
        ok = false;
        messages.add('Node failed to run (--version exit ${r.exitCode}).');
      }
    } catch (e) {
      ok = false;
      messages.add('Node not found: $e');
    }

    // 2. Runner directory.
    final runnerDir = await resolveRunnerDir(settings);
    if (runnerDir == null) {
      ok = false;
      messages.add(
        'Runner directory not found. Set it in Settings (folder with scan.js, fill.js, batch.js, login.js).',
      );
    } else {
      messages.add('Runner: $runnerDir');
      for (final script in [
        'scan.js',
        'fill.js',
        'batch.js',
        'login.js',
        'executor.js',
      ]) {
        if (!await File('$runnerDir${Platform.pathSeparator}$script')
            .exists()) {
          ok = false;
          messages.add('Missing runner script: $script');
        }
      }
      if (!await Directory('$runnerDir${Platform.pathSeparator}node_modules')
          .exists()) {
        ok = false;
        messages.add(
          'runner/node_modules missing — run "Install npm dependencies".',
        );
      } else {
        messages.add('npm dependencies installed.');
      }

      // 3. Playwright browser binary.
      if (ok) {
        try {
          final r = await Process.run(_nodeExecutable(settings), [
            '-e',
            "const {chromium}=require('playwright');"
                "const fs=require('fs');"
                "const p=chromium.executablePath();"
                "console.log(p);"
                "console.log(fs.existsSync(p)?'BROWSER_OK':'BROWSER_MISSING');",
          ], workingDirectory: runnerDir);
          final out = (r.stdout as String).trim().split('\n');
          if (out.contains('BROWSER_OK')) {
            messages.add('Playwright Chromium installed.');
          } else {
            ok = false;
            messages.add(
              'Playwright Chromium not installed — run "Install Chromium".',
            );
          }
        } catch (e) {
          ok = false;
          messages.add('Could not check Playwright browser: $e');
        }
      }
    }

    // 4. Storage directory writable.
    try {
      final base = await StorageService.instance.baseDir;
      messages.add('Data directory: ${base.path}');
    } catch (e) {
      ok = false;
      messages.add('Cannot access data directory: $e');
    }

    return PreflightResult(ok, messages);
  }

  /// Run `npm install` in the runner dir, streaming output lines.
  Stream<String> npmInstall(AppSettings settings, String runnerDir) async* {
    Process process;
    try {
      process = await Process.start(_nodeExecutable(settings), [
        Platform.isWindows ? 'npm.cmd' : 'npm',
        'install',
        '--no-audit',
        '--no-fund',
      ], workingDirectory: runnerDir);
    } catch (e) {
      yield 'Could not start npm: $e';
      return;
    }
    yield* process.stdout.transform(utf8.decoder);
    yield* process.stderr.transform(utf8.decoder);
    final code = await process.exitCode;
    yield '\nDone (exit code $code).';
  }

  /// Run `npx playwright install chromium`, streaming output lines.
  Stream<String> installChromium(
    AppSettings settings,
    String runnerDir,
  ) async* {
    Process process;
    try {
      process = await Process.start(_nodeExecutable(settings), [
        Platform.isWindows ? 'npx.cmd' : 'npx',
        'playwright',
        'install',
        'chromium',
      ], workingDirectory: runnerDir);
    } catch (e) {
      yield 'Could not start npx: $e';
      return;
    }
    yield* process.stdout.transform(utf8.decoder);
    yield* process.stderr.transform(utf8.decoder);
    final code = await process.exitCode;
    yield '\nDone (exit code $code).';
  }
}
