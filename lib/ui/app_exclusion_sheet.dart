import 'package:flutter/material.dart';

import '../core/vpn_controller.dart';

class AppExclusionSheet extends StatefulWidget {
  const AppExclusionSheet({
    super.key,
    required this.apps,
    required this.onSave,
  });

  final List<AppExclusionEntry> apps;
  final Future<void> Function(Set<String> packageNames) onSave;

  @override
  State<AppExclusionSheet> createState() => _AppExclusionSheetState();
}

class _AppExclusionSheetState extends State<AppExclusionSheet> {
  final _search = TextEditingController();
  late final Set<String> _selected = widget.apps
      .where((app) => app.excluded)
      .map((app) => app.packageName)
      .toSet();
  bool _saving = false;
  String? _error;

  List<AppExclusionEntry> get _filteredApps {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.apps;
    return widget.apps
        .where(
          (app) =>
              app.label.toLowerCase().contains(query) ||
              app.packageName.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_selected);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Не удалось сохранить выбор: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apps = _filteredApps;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Приложения без VPN',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text('${_selected.length}'),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Отмеченные приложения подключаются напрямую и не используют VPN или его DNS-защиту. Каталог предлагает известные точные package ID; список можно исправить вручную. Изменения применятся при следующем подключении.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Найти приложение',
                ),
              ),
            ),
            Expanded(
              child: widget.apps.isEmpty
                  ? const Center(
                      child: Text(
                        'Проверка ещё не завершена или приложений нет.',
                      ),
                    )
                  : apps.isEmpty
                      ? const Center(child: Text('Ничего не найдено'))
                      : ListView.builder(
                          itemCount: apps.length,
                          itemBuilder: (context, index) {
                            final app = apps[index];
                            final selected =
                                _selected.contains(app.packageName);
                            return CheckboxListTile(
                              value: selected,
                              onChanged: _saving
                                  ? null
                                  : (value) {
                                      setState(() {
                                        if (value == true) {
                                          _selected.add(app.packageName);
                                        } else {
                                          _selected.remove(app.packageName);
                                        }
                                      });
                                    },
                              title: Text(app.label),
                              subtitle: Text(
                                app.inRussianCatalog
                                    ? 'Каталог Limb VPN · ${app.packageName}'
                                    : app.packageName,
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Сохраняю…' : 'Сохранить'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
