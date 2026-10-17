import 'humanize_settings.dart';

/// App-level settings, stored in the app-support directory.
class AppSettings {
  AppSettings({
    this.nodePath = '',
    this.runnerDir = '',
    HumanizeSettings? humanizeDefaults,
  }) : humanizeDefaults = humanizeDefaults ?? HumanizeSettings();

  /// Full path to the node executable. Empty = resolve from PATH.
  String nodePath;

  /// Directory containing scan.js / fill.js / login.js. Empty = auto-detect.
  String runnerDir;

  /// Humanization defaults applied to newly created profiles.
  HumanizeSettings humanizeDefaults;

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      nodePath: json['nodePath'] as String? ?? '',
      runnerDir: json['runnerDir'] as String? ?? '',
      humanizeDefaults: json['humanizeDefaults'] != null
          ? HumanizeSettings.fromJson(
              Map<String, dynamic>.from(json['humanizeDefaults'] as Map),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'nodePath': nodePath,
    'runnerDir': runnerDir,
    'humanizeDefaults': humanizeDefaults.toJson(),
  };
}
