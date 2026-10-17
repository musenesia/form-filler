import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

/// Preview of a CSV/XLSX data file: column names plus the first rows.
class DataPreview {
  DataPreview(this.columns, this.rows, this.totalRows);

  final List<String> columns;
  final List<List<String>> rows;
  final int totalRows;
}

/// Reads CSV/XLSX files for the profile editor's data preview and the
/// {{ColumnName}} placeholder insertion. The runner (Node) does the actual
/// batch parsing; this is only for UI previews.
class DataFileService {
  DataFileService._();
  static final DataFileService instance = DataFileService._();

  static String _cell(Object? v) {
    if (v == null) return '';
    final s = '$v'.trim();
    return s == 'null' ? '' : s;
  }

  /// Load up to [maxRows] preview rows plus column headers.
  Future<DataPreview> preview(
    String path, {
    int maxRows = 5,
    String sheet = '',
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Data file not found: $path');
    }
    final lower = path.toLowerCase();
    if (lower.endsWith('.csv')) {
      return _previewCsv(file, maxRows);
    }
    if (lower.endsWith('.xlsx')) {
      return _previewXlsx(file, maxRows, sheet);
    }
    throw Exception('Unsupported data file type (use .csv or .xlsx)');
  }

  Future<DataPreview> _previewCsv(File file, int maxRows) async {
    final text = (await file.readAsString()).replaceAll('﻿', '');
    // csv 8.x API: decode() returns List<List<dynamic>>; by default it
    // auto-detects the delimiter, skips empty lines, and keeps fields as text.
    final rows = Csv().decode(text);
    final nonEmpty = rows
        .where((r) => r.any((c) => _cell(c).isNotEmpty))
        .toList();
    if (nonEmpty.isEmpty) return DataPreview([], [], 0);
    final columns = nonEmpty.first.map(_cell).toList();
    final data = nonEmpty
        .skip(1)
        .take(maxRows)
        .map(
          (r) => List<String>.generate(
            columns.length,
            (i) => i < r.length ? _cell(r[i]) : '',
          ),
        )
        .toList();
    return DataPreview(columns, data, nonEmpty.length - 1);
  }

  Future<DataPreview> _previewXlsx(File file, int maxRows, String sheet) async {
    final bytes = await file.readAsBytes();
    final excel = Excel.decodeBytes(bytes);
    String? tableName;
    if (sheet.isNotEmpty && excel.tables.containsKey(sheet)) {
      tableName = sheet;
    } else {
      tableName = excel.tables.keys.isNotEmpty ? excel.tables.keys.first : null;
    }
    if (tableName == null) return DataPreview([], [], 0);
    final table = excel.tables[tableName]!;
    final rawRows = table.rows
        .map((row) => row.map((c) => _cell(c?.value)).toList())
        .where((r) => r.any((c) => c.isNotEmpty))
        .toList();
    if (rawRows.isEmpty) return DataPreview([], [], 0);
    final columns = rawRows.first;
    final data = rawRows
        .skip(1)
        .take(maxRows)
        .map(
          (r) => List<String>.generate(
            columns.length,
            (i) => i < r.length ? r[i] : '',
          ),
        )
        .toList();
    return DataPreview(columns, data, rawRows.length - 1);
  }

  /// First data row as a column->value map, for substituted-value previews.
  Future<Map<String, String>> firstRow(String path, {String sheet = ''}) async {
    final preview = await this.preview(path, maxRows: 1, sheet: sheet);
    if (preview.columns.isEmpty || preview.rows.isEmpty) return {};
    final row = preview.rows.first;
    final map = <String, String>{};
    for (var i = 0; i < preview.columns.length; i++) {
      map[preview.columns[i]] = i < row.length ? row[i] : '';
    }
    return map;
  }
}
