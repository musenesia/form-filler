/// Human-like execution settings, mapped to runner job.options.humanize.
///
/// These reduce the chance of tripping naive bot checks (instant fills,
/// perfectly straight mouse moves, headless fingerprints). Nothing makes
/// automation undetectable — keep volumes and pacing human-like and respect
/// each site's terms of use.
class HumanizeSettings {
  HumanizeSettings({
    this.enabled = false,
    this.stepDelayMinMs = 400,
    this.stepDelayMaxMs = 1200,
    this.typeDelayMinMs = 40,
    this.typeDelayMaxMs = 140,
    this.mouseSteps = 12,
    this.stealth = true,
    this.useRealChrome = false,
    this.viewportW = 1280,
    this.viewportH = 800,
    this.userAgent = '',
    this.locale = '',
    this.timezoneId = '',
  });

  bool enabled;
  int stepDelayMinMs;
  int stepDelayMaxMs;
  int typeDelayMinMs;
  int typeDelayMaxMs;
  int mouseSteps;
  bool stealth;
  bool useRealChrome;
  int viewportW;
  int viewportH;
  String userAgent;
  String locale;
  String timezoneId;

  factory HumanizeSettings.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v, int fallback) =>
        v is num ? v.toInt() : int.tryParse('$v') ?? fallback;
    return HumanizeSettings(
      enabled: json['enabled'] as bool? ?? false,
      stepDelayMinMs: asInt(json['stepDelayMinMs'], 400),
      stepDelayMaxMs: asInt(json['stepDelayMaxMs'], 1200),
      typeDelayMinMs: asInt(json['typeDelayMinMs'], 40),
      typeDelayMaxMs: asInt(json['typeDelayMaxMs'], 140),
      mouseSteps: asInt(json['mouseSteps'], 12),
      stealth: json['stealth'] as bool? ?? true,
      useRealChrome: json['useRealChrome'] as bool? ?? false,
      viewportW: asInt(json['viewportW'], 1280),
      viewportH: asInt(json['viewportH'], 800),
      userAgent: json['userAgent'] as String? ?? '',
      locale: json['locale'] as String? ?? '',
      timezoneId: json['timezoneId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'stepDelayMinMs': stepDelayMinMs,
    'stepDelayMaxMs': stepDelayMaxMs,
    'typeDelayMinMs': typeDelayMinMs,
    'typeDelayMaxMs': typeDelayMaxMs,
    'mouseSteps': mouseSteps,
    'stealth': stealth,
    'useRealChrome': useRealChrome,
    'viewportW': viewportW,
    'viewportH': viewportH,
    'userAgent': userAgent,
    'locale': locale,
    'timezoneId': timezoneId,
  };

  /// Shape consumed by runner/executor.js as job.options.humanize.
  Map<String, dynamic> toJobOptions() => {
    'enabled': enabled,
    'stepDelayMinMs': stepDelayMinMs,
    'stepDelayMaxMs': stepDelayMaxMs,
    'typeDelayMinMs': typeDelayMinMs,
    'typeDelayMaxMs': typeDelayMaxMs,
    'mouseSteps': mouseSteps,
    'stealth': stealth,
    'channel': useRealChrome ? 'chrome' : 'chromium',
    'viewportW': viewportW,
    'viewportH': viewportH,
    'userAgent': userAgent,
    'locale': locale,
    'timezoneId': timezoneId,
  };

  HumanizeSettings copy() => HumanizeSettings.fromJson(toJson());
}
