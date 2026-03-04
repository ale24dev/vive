import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../data/storage_service.dart';
import '../../domain/dance_class.dart';
import '../theme/vive_theme.dart';
import 'class_detail_screen.dart';

class ClassesScreen extends StatefulWidget {
  final ViveDatabase db;
  final StorageService storage;
  final bool hasSDCard;

  const ClassesScreen({
    super.key,
    required this.db,
    required this.storage,
    this.hasSDCard = false,
  });

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  List<DanceClass> _classes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadClasses();
  }

  Future<void> _loadClasses() async {
    final classes = await widget.db.getAllClasses();
    setState(() {
      _classes = classes;
      _loading = false;
    });
  }

  Future<void> _createClass() async {
    final nameController = TextEditingController();
    DateTime selectedDate = DateTime.now();

    final result = await showDialog<DanceClass?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nueva Clase'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Nombre de la clase',
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),
                  );
                  if (date != null) {
                    setDialogState(() => selectedDate = date);
                  }
                },
                icon: const Icon(Icons.calendar_today),
                label: Text(_formatDate(selectedDate)),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  if (nameController.text.trim().isEmpty) return;
                  Navigator.pop(
                    context,
                    DanceClass(
                      name: nameController.text.trim(),
                      date: selectedDate,
                      createdAt: DateTime.now(),
                    ),
                  );
                },
                child: const Text('Crear'),
              ),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await widget.db.insertClass(result);
      await _loadClasses();
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      body: _classes.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.event_outlined,
                    size: 64,
                    color: ViveTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Sin clases',
                    style: TextStyle(
                      color: ViveTheme.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Creá tu primera clase de baile',
                    style: TextStyle(
                      color: ViveTheme.textSecondary.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadClasses,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _classes.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, index) {
                  final danceClass = _classes[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: ViveTheme.primaryPale,
                      child: Icon(Icons.music_note, color: ViveTheme.primary),
                    ),
                    title: Text(
                      danceClass.name,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      _formatDate(danceClass.date),
                      style: TextStyle(color: ViveTheme.textSecondary),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ClassDetailScreen(
                            db: widget.db,
                            danceClass: danceClass,
                            storage: widget.storage,
                            hasSDCard: widget.hasSDCard,
                          ),
                        ),
                      );
                      await _loadClasses();
                    },
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'classes_create_fab',
        onPressed: _createClass,
        child: const Icon(Icons.add),
      ),
    );
  }
}
