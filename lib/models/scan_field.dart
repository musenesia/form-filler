/// One form field discovered by runner/scan.js.
class ScannedField {
  ScannedField({
    required this.tag,
    required this.type,
    required this.name,
    required this.id,
    required this.placeholder,
    required this.label,
    required this.css,
    required this.xpath,
  });

  final String tag;
  final String type;
  final String name;
  final String id;
  final String placeholder;
  final String label;
  final String css;
  final String xpath;

  factory ScannedField.fromJson(Map<String, dynamic> json) {
    return ScannedField(
      tag: json['tag'] as String? ?? '',
      type: json['type'] as String? ?? '',
      name: json['name'] as String? ?? '',
      id: json['id'] as String? ?? '',
      placeholder: json['placeholder'] as String? ?? '',
      label: json['label'] as String? ?? '',
      css: json['css'] as String? ?? '',
      xpath: json['xpath'] as String? ?? '',
    );
  }

  /// Human-friendly display name: label, placeholder, name, or id.
  String get displayName {
    if (label.isNotEmpty) return label;
    if (placeholder.isNotEmpty) return placeholder;
    if (name.isNotEmpty) return name;
    if (id.isNotEmpty) return '#$id';
    return '$tag field';
  }

  String get kindLabel {
    final t = type.isNotEmpty ? type : tag;
    return t;
  }
}
