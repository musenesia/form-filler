/// One recorded run of a profile, appended to runs.jsonl.
class RunRecord {
  RunRecord({
    String? id,
    required this.profileId,
    required this.profileName,
    DateTime? startedAt,
    required this.success,
    required this.steps,
    this.error = '',
    this.screenshotPath = '',
    this.kind = 'single',
    this.totalRows = 0,
    this.succeeded = 0,
    this.failed = 0,
  }) : id = id ?? 'run_${DateTime.now().microsecondsSinceEpoch}',
       startedAt = startedAt ?? DateTime.now();

  final String id;
  final String profileId;
  final String profileName;
  final DateTime startedAt;
  final bool success;
  final int steps;
  final String error;
  final String screenshotPath;

  /// 'single' or 'batch'.
  final String kind;

  /// Batch-only stats.
  final int totalRows;
  final int succeeded;
  final int failed;

  factory RunRecord.fromJson(Map<String, dynamic> json) {
    return RunRecord(
      id: json['id'] as String?,
      profileId: json['profileId'] as String? ?? '',
      profileName: json['profileName'] as String? ?? '',
      startedAt: json['startedAt'] != null
          ? DateTime.parse(json['startedAt'] as String)
          : null,
      success: json['success'] as bool? ?? false,
      steps: (json['steps'] as num?)?.toInt() ?? 0,
      error: json['error'] as String? ?? '',
      screenshotPath: json['screenshotPath'] as String? ?? '',
      kind: json['kind'] as String? ?? 'single',
      totalRows: (json['totalRows'] as num?)?.toInt() ?? 0,
      succeeded: (json['succeeded'] as num?)?.toInt() ?? 0,
      failed: (json['failed'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'profileId': profileId,
    'profileName': profileName,
    'startedAt': startedAt.toIso8601String(),
    'success': success,
    'steps': steps,
    'error': error,
    'screenshotPath': screenshotPath,
    'kind': kind,
    'totalRows': totalRows,
    'succeeded': succeeded,
    'failed': failed,
  };
}
