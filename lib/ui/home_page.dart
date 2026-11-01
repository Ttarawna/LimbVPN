import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/mieru_link.dart';
import '../core/vpn_controller.dart';
import 'settings_sheet.dart';

class _Palette {
  const _Palette(this.bg, this.fg, this.muted, this.ring, this.btn, this.btnFg);

  final Color bg, fg, muted, ring, btn, btnFg;

  factory _Palette.of(bool on, Brightness brightness) {
    if (on) {
      return const _Palette(Color(0xFF0E3A44), Color(0xFFE6F4F1), Color(0xFF8FB7B5),
          Color(0xFF2C6670), Color(0xFFE6F4F1), Color(0xFF0E3A44));
    }
    if (brightness == Brightness.dark) {
      return const _Palette(Color(0xFF14191C), Color(0xFFDDE6E9), Color(0xFF8A9BA2),
          Color(0xFF2A363B), Color(0xFFDDE6E9), Color(0xFF14191C));
    }
    return const _Palette(Color(0xFFE8EDEF), Color(0xFF12303A), Color(0xFF5F7680),
        Color(0xFFB9C8CE), Color(0xFF12303A), Color(0xFFE8EDEF));
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});

  final AppState app;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _url = TextEditingController();
  String? _error;
  bool _confirmDelete = false;
  int _taps = 0;
  Timer? _tapTimer;
  Timer? _deleteTimer;

  @override
  void dispose() {
    _url.dispose();
    _tapTimer?.cancel();
    _deleteTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final message = await widget.app.toggle();
    if (message != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _add() {
    try {
      widget.app.importLink(_url.text);
      _url.clear();
      // Ссылка с паролем не должна оставаться в буфере обмена.
      Clipboard.setData(const ClipboardData(text: ''));
      setState(() => _error = null);
    } on LinkFormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) _url.text = data!.text!.trim();
  }

  void _setAutostart(bool value) {
    widget.app.setFlag(Flag.autostart, value);
    if (value && widget.app.vpn.hasAutostart) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: const Text(
              'Если после перезагрузки VPN не включится сам, разрешите автозапуск для Limb VPN в настройках телефона.'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: widget.app.vpn.openAutostartSettings,
          ),
        ),
      );
    }
  }

  Future<void> _delete() async {
    if (!_confirmDelete) {
      setState(() => _confirmDelete = true);
      _deleteTimer?.cancel();
      _deleteTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _confirmDelete = false);
      });
      return;
    }
    _deleteTimer?.cancel();
    setState(() => _confirmDelete = false);
    await widget.app.deleteProfile();
  }

  /// Скрытое меню: 5 нажатий в левый нижний угол в течение 2 секунд.
  void _cornerTap() {
    _taps++;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(seconds: 2), () => _taps = 0);
    if (_taps >= 5) {
      _taps = 0;
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SettingsSheet(app: widget.app),
      );
    }
  }

  String _statusText(VpnStatus s) => switch (s) {
        VpnStatus.off => 'Отключено',
        VpnStatus.connecting => 'Подключаю…',
        VpnStatus.on => 'Подключено',
        VpnStatus.disconnecting => 'Отключаю…',
        VpnStatus.blocked => 'Трафик заблокирован',
      };

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final status = widget.app.vpn.status;
        final on = status == VpnStatus.on;
        final c = _Palette.of(on, brightness);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          color: c.bg,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _power(c, status),
                          const SizedBox(height: 28),
                          Text(_statusText(status),
                              style: TextStyle(
                                  color: c.fg, fontSize: 22, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          _subtitle(c, status),
                          const SizedBox(height: 28),
                          _profileArea(c),
                        ],
                      ),
                    ),
                  ),
                ),
                // Невидимая зона в левом нижнем углу.
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _cornerTap,
                    child: const SizedBox(width: 72, height: 72),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _power(_Palette c, VpnStatus status) {
    final on = status == VpnStatus.on;
    final busy = status == VpnStatus.connecting || status == VpnStatus.disconnecting;
    return Semantics(
      button: true,
      label: (on || status == VpnStatus.blocked) ? 'Выключить VPN' : 'Включить VPN',
      child: GestureDetector(
        onTap: busy ? null : _toggle,
        child: SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 200,
                  height: 200,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.muted),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 176,
                height: 176,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? c.btn : Colors.transparent,
                  border: Border.all(color: on ? c.btn : c.ring, width: 2),
                ),
                child: Icon(Icons.power_settings_new,
                    size: 56, color: on ? c.btnFg : c.fg),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subtitle(_Palette c, VpnStatus status) {
    final style = TextStyle(color: c.muted, fontSize: 14);
    if (status == VpnStatus.on) {
      return StreamBuilder<int>(
        stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
        builder: (context, _) {
          final since = widget.app.vpn.since ?? DateTime.now();
          final d = DateTime.now().difference(since).inSeconds;
          final mm = (d ~/ 60).toString().padLeft(2, '0');
          final ss = (d % 60).toString().padLeft(2, '0');
          return Text('РФ напрямую, остальное через VPN. $mm:$ss',
              textAlign: TextAlign.center, style: style);
        },
      );
    }
    if (status == VpnStatus.blocked) {
      return Text('Связь потеряна, пробую восстановить. Нажмите кнопку, чтобы отключить.',
          textAlign: TextAlign.center, style: style);
    }
    if (widget.app.profile == null && status == VpnStatus.off) {
      return Text('Добавьте профиль, чтобы начать', style: style);
    }
    return Text('', style: style);
  }

  Widget _profileArea(_Palette c) {
    final p = widget.app.profile;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: p != null
          ? Column(
              children: [
                Text(p.maskedName,
                    style: TextStyle(
                        color: c.fg, fontSize: 16, fontWeight: FontWeight.w500)),
                Text('Профиль хранится в зашифрованном виде',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.muted, fontSize: 14)),
                TextButton(
                  onPressed: _delete,
                  child: Text(_confirmDelete ? 'Точно удалить?' : 'Удалить профиль',
                      style: TextStyle(color: c.muted)),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text('Запускать при старте телефона',
                          style: TextStyle(color: c.muted, fontSize: 14)),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: widget.app.autostart,
                      onChanged: _setAutostart,
                    ),
                  ],
                ),
              ],
            )
          : Column(
              children: [
                TextField(
                  controller: _url,
                  style: TextStyle(color: c.fg),
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: 'Вставьте ссылку на профиль',
                    hintStyle: TextStyle(color: c.muted),
                    suffixIcon: IconButton(
                      tooltip: 'Вставить из буфера',
                      icon: Icon(Icons.content_paste, color: c.muted),
                      onPressed: _paste,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: c.ring),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: c.fg),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: c.fg, foregroundColor: c.bg),
                  onPressed: _add,
                  child: const Text('Добавить'),
                ),
                SizedBox(
                  height: 40,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error ?? '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFFC0463A), fontSize: 14)),
                  ),
                ),
              ],
            ),
    );
  }
}
