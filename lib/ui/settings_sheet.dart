import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';

/// Скрытые настройки. Открываются пятью нажатиями в левый нижний угол.
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key, required this.app});

  final AppState app;

  Future<void> _setKillSwitch(BuildContext context, bool value) async {
    if (!value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Отключить kill switch?'),
          content: const Text(
              'Без него при обрыве VPN зарубежные сайты увидят ваш настоящий IP.'),
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

  Future<void> _showLog(BuildContext context) async {
    final text = await app.vpn.readLog();
    if (!context.mounted) return;
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
            const SwitchListTile(
              value: true,
              onChanged: null,
              title: Text('Российский трафик напрямую'),
              subtitle: Text(
                  'Всё российское идёт мимо VPN, даже в зарубежных и российских приложениях. Остальное идёт через VPN. Определяется автоматически.'),
            ),
            const SwitchListTile(
              value: true,
              onChanged: null,
              title: Text('Сервер вне туннеля'),
              subtitle: Text(
                  'Адрес сервера всегда идёт напрямую, а kill switch его пропускает, чтобы VPN мог переподключиться.'),
            ),
            SwitchListTile(
              value: app.killSwitch,
              onChanged: (v) => _setKillSwitch(context, v),
              title: const Text('Kill switch'),
              subtitle: const Text(
                  'Если VPN оборвётся, зарубежный трафик блокируется. Российский и адрес сервера продолжают идти напрямую.'),
            ),
            if (app.vpn.hasSystemKillSwitch)
              ListTile(
                title: const Text('Системная блокировка без VPN'),
                subtitle: const Text(
                    'Включите в настройках Android «Блокировать соединения без VPN» для Quiet VPN. Это единственный способ полностью исключить утечки, если приложение будет закрыто системой.'),
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
            ),
            if (app.vpn.hasLog)
              ListTile(
                title: const Text('Журнал ядра'),
                subtitle: const Text(
                    'Для диагностики. Можно скопировать и отправить разработчику.'),
                trailing: const Icon(Icons.article_outlined),
                onTap: () => _showLog(context),
              ),
            const ListTile(
              title: Text('Версия 0.6.1'),
              subtitle: Text(
                  'Изменения настроек применяются при следующем подключении.'),
            ),
          ],
        ),
      ),
    );
  }
}
