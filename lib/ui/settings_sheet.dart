import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';

/// Скрытые настройки. Открываются пятью нажатиями в левый нижний угол.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.app});

  final AppState app;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  AppState get app => widget.app;

  late final Future<bool?> _lockdown = app.vpn.lockdownEnabled();

  Future<void> _setKillSwitch(bool value) async {
    if (!value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Отключить kill switch?'),
          content: const Text(
              'Без него при сбое ядра VPN трафик пойдёт напрямую и зарубежные сайты увидят ваш настоящий IP.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: const Text('Оставить')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('Отключить')),
          ],
        ),
      );
      if (ok != true) return;
    }
    app.setFlag(Flag.killSwitch, value);
  }

  Future<void> _showLog() async {
    final text = await app.vpn.readLog();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Журнал ядра'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(text,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              child: const Text('Скопировать')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  Future<void> _showExcluded() async {
    final text = (await app.vpn.readExcludedApps()).trim();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Приложения без VPN'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
                text.isEmpty
                    ? 'Список появится после подключения. Приложения определяются при каждом подключении.'
                    : text,
                style: const TextStyle(fontSize: 13)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Расширенные настройки',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const ListTile(
              title: Text('Российский трафик напрямую'),
              subtitle: Text(
                  'Всегда включено. Всё российское идёт мимо VPN, остальное через VPN. Определяется автоматически.'),
              trailing: Icon(Icons.check_circle_outline),
            ),
            const ListTile(
              title: Text('Сервер вне туннеля'),
              subtitle: Text(
                  'Всегда включено. Адрес сервера идёт напрямую, чтобы VPN мог переподключиться.'),
              trailing: Icon(Icons.check_circle_outline),
            ),
            SwitchListTile(
              value: app.killSwitch,
              onChanged: _setKillSwitch,
              title: const Text('Kill switch'),
              subtitle: const Text(
                  'Если ядро VPN остановится или упадёт, весь трафик блокируется, пока соединение не восстановится или вы не отключите VPN. Приложение пытается переподключиться само.'),
            ),
            if (app.vpn.hasSystemKillSwitch)
              ListTile(
                title: const Text('Системная блокировка без VPN'),
                subtitle: FutureBuilder<bool?>(
                  future: _lockdown,
                  builder: (context, snap) {
                    final state = snap.data;
                    final status = state == null
                        ? 'Состояние станет известно после подключения.'
                        : state
                            ? 'Сейчас: включена.'
                            : 'Сейчас: выключена. Включите её, чтобы трафик не шёл напрямую, если систему закроет саму службу VPN.';
                    return Text(
                        'В настройках Android включите «Всегда включённый VPN» и «Блокировать соединения без VPN» для Quiet VPN. $status');
                  },
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: app.vpn.openSystemVpnSettings,
              ),
            SwitchListTile(
              value: app.dnsProtection,
              onChanged: (v) => app.setFlag(Flag.dnsProtection, v),
              title: const Text('Защита от утечек DNS'),
              subtitle: const Text(
                  'Российские домены разрешаются через DNS провайдера, остальные только внутри туннеля.'),
            ),
            SwitchListTile(
              value: app.blockIpv6,
              onChanged: (v) => app.setFlag(Flag.blockIpv6, v),
              title: const Text('Блокировать IPv6'),
              subtitle: const Text('Не даёт трафику обойти туннель по IPv6.'),
            ),
            SwitchListTile(
              value: app.autostart,
              onChanged: (v) => app.setFlag(Flag.autostart, v),
              title: const Text('Запускать при старте системы'),
              subtitle: const Text(
                  'После перезагрузки телефона VPN включится сам (нужно хотя бы раз подключиться вручную).'),
            ),
            if (app.vpn.hasAppExclusion) ...[
              SwitchListTile(
                value: app.excludeRuApps,
                onChanged: (v) => app.setFlag(Flag.excludeRuApps, v),
                title: const Text('Российские приложения без VPN'),
                subtitle: const Text(
                    'Банки, Госуслуги, магазины и другие российские приложения определяются автоматически и работают вне VPN, поэтому не видят его. Весь их трафик идёт напрямую.'),
              ),
              ListTile(
                title: const Text('Какие приложения без VPN'),
                trailing: const Icon(Icons.list_alt_outlined),
                onTap: _showExcluded,
              ),
            ],
            if (app.vpn.hasLog) ...[
              SwitchListTile(
                value: app.debugMode,
                onChanged: (v) => app.setFlag(Flag.debug, v),
                title: const Text('Режим диагностики'),
                subtitle: const Text(
                    'Подробный журнал и самопроверки. Открывает локальные порты, которые российские приложения могут обнаружить. Держите выключенным.'),
              ),
              ListTile(
                title: const Text('Журнал ядра'),
                subtitle: const Text(
                    'Для диагностики. Можно скопировать и отправить разработчику.'),
                trailing: const Icon(Icons.article_outlined),
                onTap: _showLog,
              ),
            ],
            const ListTile(
              title: Text('Версия 0.8.0'),
              subtitle: Text('Изменения настроек применяются при следующем подключении.'),
            ),
          ],
        ),
      ),
    );
  }
}
