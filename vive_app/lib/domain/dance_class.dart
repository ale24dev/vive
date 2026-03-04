class DanceClass {
  final int? id;
  final String name;
  final DateTime date;
  final DateTime createdAt;

  const DanceClass({
    this.id,
    required this.name,
    required this.date,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name': name,
    'date': date.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };

  factory DanceClass.fromMap(Map<String, dynamic> map) => DanceClass(
    id: map['id'] as int,
    name: map['name'] as String,
    date: DateTime.parse(map['date'] as String),
    createdAt: DateTime.parse(map['created_at'] as String),
  );

  DanceClass copyWith({
    int? id,
    String? name,
    DateTime? date,
    DateTime? createdAt,
  }) => DanceClass(
    id: id ?? this.id,
    name: name ?? this.name,
    date: date ?? this.date,
    createdAt: createdAt ?? this.createdAt,
  );
}
