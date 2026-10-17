/// Settings for a data-driven batch run: one job execution per data row.
class BatchSettings {
  BatchSettings({
    this.dataFilePath = '',
    this.sheet = '',
    this.startRow = 1,
    this.maxRows = 0,
    this.rowDelayMinMs = 1000,
    this.rowDelayMaxMs = 3000,
    this.stopOnError = false,
  });

  /// Path to the .csv or .xlsx file. Empty = no data file chosen yet.
  String dataFilePath;

  /// XLSX sheet name. Empty = first sheet.
  String sheet;

  /// 1-based first data row to process.
  int startRow;

  /// Max rows to process. 0 = all rows.
  int maxRows;

  /// Random pause between rows, uniform in [rowDelayMinMs, rowDelayMaxMs].
  int rowDelayMinMs;
  int rowDelayMaxMs;

  bool stopOnError;

  bool get isXlsx => dataFilePath.toLowerCase().endsWith('.xlsx');

  factory BatchSettings.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v, int fallback) =>
        v is num ? v.toInt() : int.tryParse('$v') ?? fallback;
    return BatchSettings(
      dataFilePath: json['dataFilePath'] as String? ?? '',
      sheet: json['sheet'] as String? ?? '',
      startRow: asInt(json['startRow'], 1),
      maxRows: asInt(json['maxRows'], 0),
      rowDelayMinMs: asInt(json['rowDelayMinMs'], 1000),
      rowDelayMaxMs: asInt(json['rowDelayMaxMs'], 3000),
      stopOnError: json['stopOnError'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'dataFilePath': dataFilePath,
    'sheet': sheet,
    'startRow': startRow,
    'maxRows': maxRows,
    'rowDelayMinMs': rowDelayMinMs,
    'rowDelayMaxMs': rowDelayMaxMs,
    'stopOnError': stopOnError,
  };

  BatchSettings copy() => BatchSettings.fromJson(toJson());
}
