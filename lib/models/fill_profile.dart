import 'batch_settings.dart';
import 'humanize_settings.dart';

/// A single automation step inside a [FillProfile].
///
/// Maps 1:1 onto the actions supported by runner/fill.js.
class FieldStep {
  FieldStep({
    String? id,
    required this.action,
    this.selector = '',
    this.selectorType = 'css',
    this.value = '',
    this.key = '',
    this.url = '',
    this.timeoutMs = 30000,
    this.note = '',
  }) : id = id ?? 'step_${DateTime.now().microsecondsSinceEpoch}';

  final String id;
  String action;
  String selector;
  String selectorType; // css | xpath | text
  String value;
  String key; // for press
  String url; // for goto
  int timeoutMs;
  String note;

  static const List<String> actions = [
    'goto',
    'fill',
    'type',
    'click',
    'select',
    'check',
    'uncheck',
    'press',
    'waitForSelector',
    'waitForTimeout',
    'screenshot',
    'dump',
  ];

  /// Actions that need a selector to locate an element.
  static const List<String> selectorActions = [
    'fill',
    'type',
    'click',
    'select',
    'check',
    'uncheck',
    'press',
    'waitForSelector',
  ];

  /// Actions that need a free-form value.
  static const List<String> valueActions = [
    'fill',
    'type',
    'select',
    'waitForTimeout',
    'screenshot',
  ];

  factory FieldStep.fromJson(Map<String, dynamic> json) {
    return FieldStep(
      id: json['id'] as String?,
      action: json['action'] as String? ?? 'fill',
      selector: json['selector'] as String? ?? '',
      selectorType: json['selectorType'] as String? ?? 'css',
      value: json['value'] as String? ?? '',
      key: json['key'] as String? ?? '',
      url: json['url'] as String? ?? '',
      timeoutMs: (json['timeoutMs'] as num?)?.toInt() ?? 30000,
      note: json['note'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action,
    'selector': selector,
    'selectorType': selectorType,
    'value': value,
    'key': key,
    'url': url,
    'timeoutMs': timeoutMs,
    'note': note,
  };

  /// Convert to the job-step format consumed by runner/fill.js.
  Map<String, dynamic> toJobStep() {
    final step = <String, dynamic>{'action': action};
    if (selectorActions.contains(action)) {
      step['selector'] = selector;
      step['selectorType'] = selectorType;
    }
    switch (action) {
      case 'goto':
        step['url'] = url;
        break;
      case 'fill':
      case 'type':
      case 'select':
        step['value'] = value;
        break;
      case 'press':
        step['key'] = key.isNotEmpty ? key : value;
        break;
      case 'waitForSelector':
        step['timeoutMs'] = timeoutMs;
        break;
      case 'waitForTimeout':
        step['value'] = value;
        break;
      case 'screenshot':
        if (value.isNotEmpty) step['value'] = value;
        break;
      case 'dump':
        step['selectors'] = value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        break;
    }
    if (action != 'waitForSelector' && action != 'waitForTimeout') {
      step['timeoutMs'] = timeoutMs;
    }
    return step;
  }

  String describe() {
    final target = selector.isNotEmpty ? ' `$selector`' : '';
    switch (action) {
      case 'goto':
        return 'Go to $url';
      case 'fill':
        return 'Fill$target with "${value.length > 40 ? '${value.substring(0, 40)}…' : value}"';
      case 'type':
        return 'Type into$target';
      case 'click':
        return 'Click$target';
      case 'select':
        return 'Select "$value" in$target';
      case 'check':
        return 'Check$target';
      case 'uncheck':
        return 'Uncheck$target';
      case 'press':
        return 'Press ${key.isNotEmpty ? key : value}$target';
      case 'waitForSelector':
        return 'Wait for$target';
      case 'waitForTimeout':
        return 'Wait ${value}ms';
      case 'screenshot':
        return 'Screenshot';
      case 'dump':
        return 'Read values';
      default:
        return action;
    }
  }

  FieldStep copy() => FieldStep.fromJson(toJson());
}

/// A saved automation: a target URL plus an ordered list of steps.
class FillProfile {
  FillProfile({
    String? id,
    required this.name,
    required this.url,
    this.loginUrl = '',
    List<FieldStep>? steps,
    DateTime? createdAt,
    BatchSettings? batch,
    HumanizeSettings? humanize,
  }) : id = id ?? 'profile_${DateTime.now().microsecondsSinceEpoch}',
       steps = steps ?? [],
       createdAt = createdAt ?? DateTime.now(),
       batch = batch ?? BatchSettings(),
       humanize = humanize ?? HumanizeSettings();

  final String id;
  String name;
  String url;
  String loginUrl;
  List<FieldStep> steps;
  DateTime createdAt;

  /// Data-driven batch settings (CSV/XLSX).
  BatchSettings batch;

  /// Human-like execution settings.
  HumanizeSettings humanize;

  factory FillProfile.fromJson(Map<String, dynamic> json) {
    return FillProfile(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Untitled',
      url: json['url'] as String? ?? '',
      loginUrl: json['loginUrl'] as String? ?? '',
      steps: ((json['steps'] as List?) ?? [])
          .map((e) => FieldStep.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      batch: json['batch'] != null
          ? BatchSettings.fromJson(
              Map<String, dynamic>.from(json['batch'] as Map),
            )
          : null,
      humanize: json['humanize'] != null
          ? HumanizeSettings.fromJson(
              Map<String, dynamic>.from(json['humanize'] as Map),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'loginUrl': loginUrl,
    'steps': steps.map((s) => s.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'batch': batch.toJson(),
    'humanize': humanize.toJson(),
  };

  /// Build the job map consumed by runner/fill.js and runner/batch.js.
  Map<String, dynamic> toJobMap({String? storagePath, String? screenshotDir}) {
    final job = <String, dynamic>{
      'url': url,
      'steps': steps.map((s) => s.toJobStep()).toList(),
      'options': {
        'humanize': humanize.toJobOptions(),
        'rowDelayMinMs': batch.rowDelayMinMs,
        'rowDelayMaxMs': batch.rowDelayMaxMs,
      },
    };
    if (storagePath != null && storagePath.isNotEmpty) {
      job['storageState'] = storagePath;
    }
    if (screenshotDir != null && screenshotDir.isNotEmpty) {
      job['screenshotDir'] = screenshotDir;
    }
    return job;
  }

  FillProfile duplicate() {
    final copy = FillProfile.fromJson(toJson());
    return FillProfile(
      name: '$name (copy)',
      url: url,
      loginUrl: loginUrl,
      steps: copy.steps,
      batch: copy.batch,
      humanize: copy.humanize,
    );
  }
}
