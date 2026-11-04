import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/mieru_link.dart';
import '../core/vpn_controller.dart';
import 'app_exclusion_sheet.dart';
import 'settings_sheet.dart';

class _Palette {
  const _Palette(
    this.bg,
    this.fg,
    this.muted,
    this.ring,
    this.panel,
    this.accent,
  );

  final Color bg, fg, muted, ring, panel, accent;

  factory _Palette.of(bool on, Brightness brightness) {
    if (on) {
      return const _Palette(
        Color(0xFFEAF4F1),
        Color(0xFF153C37),
        Color(0xFF58756F),
        Color(0xFFBFD8D1),
        Color(0xFFFFFFFF),
        Color(0xFF176B5B),
      );
    }
    if (brightness == Brightness.dark) {
      return const _Palette(
        Color(0xFF14191C),
        Color(0xFFE0E8EB),
        Color(0xFF91A0A6),
        Color(0xFF344147),
        Color(0xFF1E262A),
        Color(0xFF8ED6C1),
      );
    }
    return const _Palette(
      Color(0xFFF3F6F7),
      Color(0xFF1C3038),
      Color(0xFF657980),
      Color(0xFFD5E0E3),
      Color(0xFFFFFFFF),
      Color(0xFF1A6C5E),
    );
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
  void initState() {
    super.initState();
    widget.app.addListener(_onAppChanged);
  }

  /// Показывает сообщения приложения (например, ошибку установки обновления).
  void _onAppChanged() {
    final message = widget.app.notice;
    if (message != null && mounted) {
      widget.app.notice = null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmUpdate() async {
    final info = widget.app.update;
    if (info == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Обновить до версии ${info.version}?'),
        content: const Text(
          'Приложение скачает обновление и попросит подтвердить установку. На время установки VPN отключится и включится снова сам.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Позже'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final error = await widget.app.installUpdate();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Widget _updateControl(_Palette c) {
    final app = widget.app;
    final progress = app.updateProgress;
    final info = app.update;
    final message = app.updateCheckMessage;
    final buttonStyle = TextButton.styleFrom(foregroundColor: c.fg);

    if (progress != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextButton.icon(
          onPressed: null,
          icon: const Icon(Icons.downloading),
          label: Text('Загрузка обновления: $progress%'),
        ),
      );
    }
    if (app.updateChecking) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextButton.icon(
          onPressed: null,
          icon: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: const Text('Проверяем обновления…'),
        ),
      );
    }
    if (info != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextButton.icon(
          style: buttonStyle,
          onPressed: _confirmUpdate,
          icon: const Icon(Icons.system_update_alt),
          label: Text('Доступна версия ${info.version} · Обновить'),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            style: buttonStyle,
            onPressed: () => app.checkForUpdate(force: true),
            icon: const Icon(Icons.refresh),
            label: Text(
              message == null ? 'Проверить обновления' : 'Проверить снова',
            ),
          ),
          if (message != null)
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    _url.dispose();
    _tapTimer?.cancel();
    _deleteTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final message = await widget.app.toggle();
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _manageAppExclusions() async {
    final app = widget.app;
    if (!app.appScanComplete || app.appScanInProgress) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AppExclusionSheet(
        apps: app.installedApps,
        onSave: app.saveExcludedApps,
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Выбор сохранён и применится при следующем подключении',
          ),
        ),
      );
    }
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
        final vpnStatus = widget.app.vpn.status;
        final status =
            widget.app.vpnOperationInProgress && vpnStatus == VpnStatus.off
                ? VpnStatus.connecting
                : vpnStatus;
        final on = status == VpnStatus.on;
        final c = _Palette.of(on, brightness);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          color: c.bg,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _brand(c),
                            const SizedBox(height: 20),
                            _connectionCard(c, status),
                            const SizedBox(height: 16),
                            _profileArea(c),
                            if (widget.app.vpn.hasAppExclusion) ...[
                              const SizedBox(height: 12),
                              _appExclusionControl(c),
                            ],
                            Align(
                              alignment: Alignment.center,
                              child: _updateControl(c),
                            ),
                          ],
                        ),
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

  Widget _appExclusionControl(_Palette c) {
    final app = widget.app;
    final progress = app.appScanTotalCount > 0
        ? app.appScanCompletedCount / app.appScanTotalCount
        : null;
    final excludedCount =
        app.installedApps.where((entry) => entry.excluded).length;
    final summary = app.appScanInProgress
        ? app.appScanTotalCount == 0
            ? 'Подготовка списка приложений…'
            : 'Проверено ${app.appScanCompletedCount} из '
                '${app.appScanTotalCount} приложений'
        : app.excludeRuApps
            ? 'Без VPN: $excludedCount приложений'
            : 'Исключения выключены';
    return _panel(
      c,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _iconBadge(c, Icons.apps_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Приложения без VPN',
                      style: TextStyle(
                        color: c.fg,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(summary, style: TextStyle(color: c.muted)),
                  ],
                ),
              ),
            ],
          ),
          if (!app.appScanInProgress && app.appScanComplete) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: app.scanInstalledApps,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Проверить приложения'),
                ),
                TextButton.icon(
                  onPressed: _manageAppExclusions,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Настроить исключения'),
                ),
              ],
            ),
          ],
          if (app.appScanInProgress) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
          ],
          if (app.appScanError != null) ...[
            const SizedBox(height: 8),
            Text(
              app.appScanError!,
              style: const TextStyle(color: Color(0xFFC0463A)),
            ),
          ],
          if (!app.appScanComplete && !app.appScanInProgress) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: app.scanInstalledApps,
              icon: const Icon(Icons.manage_search),
              label: const Text('Проверить приложения'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _brand(_Palette c) => Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.shield_outlined, color: c.accent),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Limb VPN',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Защищённое подключение',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
            ],
          ),
        ],
      );

  Widget _connectionCard(_Palette c, VpnStatus status) {
    final icon = switch (status) {
      VpnStatus.on => Icons.check_circle_outline,
      VpnStatus.blocked => Icons.warning_amber_rounded,
      VpnStatus.connecting || VpnStatus.disconnecting => Icons.sync_rounded,
      VpnStatus.off => Icons.shield_outlined,
    };
    final Widget subtitle = switch (status) {
      VpnStatus.on => _subtitle(c, status),
      VpnStatus.connecting => Text('Подготавливаем защищённое соединение'),
      VpnStatus.disconnecting => Text('Завершаем подключение'),
      VpnStatus.blocked => _subtitle(c, status),
      VpnStatus.off => widget.app.profile == null
          ? const Text('Добавьте профиль, чтобы начать')
          : const Text('Трафик сейчас не защищён VPN'),
    };
    final busy =
        status == VpnStatus.connecting || status == VpnStatus.disconnecting;
    return _panel(
      c,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: Column(
        children: [
          Row(
            children: [
              _iconBadge(c, icon, active: status == VpnStatus.on),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status == VpnStatus.on ? 'Защита включена' : 'Состояние',
                      style: TextStyle(color: c.muted, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusText(status),
                      style: TextStyle(
                        color: c.fg,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (status == VpnStatus.on)
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: c.accent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _power(c, status),
          const SizedBox(height: 12),
          DefaultTextStyle(
            style: TextStyle(color: c.muted, fontSize: 14, height: 1.4),
            textAlign: TextAlign.center,
            child: subtitle,
          ),
          if (busy) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ],
          if (status == VpnStatus.on) ...[
            const SizedBox(height: 18),
            Divider(height: 1, color: c.ring),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.public, size: 17, color: c.accent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Россия — напрямую · остальное — через VPN',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _panel(
    _Palette c, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: c.panel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: c.ring.withValues(alpha: 0.65)),
        ),
        child: child,
      );

  Widget _iconBadge(_Palette c, IconData icon, {bool active = false}) =>
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: (active ? c.accent : c.muted).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: active ? c.accent : c.muted, size: 22),
      );

  Widget _power(_Palette c, VpnStatus status) {
    final on = status == VpnStatus.on;
    final busy =
        status == VpnStatus.connecting || status == VpnStatus.disconnecting;
    return Semantics(
      button: true,
      label: (on || status == VpnStatus.blocked)
          ? 'Выключить VPN'
          : 'Включить VPN',
      child: GestureDetector(
        onTap: busy ? null : _toggle,
        child: SizedBox(
          width: 144,
          height: 144,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 144,
                  height: 144,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? c.accent : c.bg,
                  border: Border.all(color: on ? c.accent : c.ring, width: 1),
                  boxShadow: [
                    if (on)
                      BoxShadow(
                        color: c.accent.withValues(alpha: 0.2),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                  ],
                ),
                child: Icon(
                  Icons.power_settings_new,
                  size: 48,
                  color: on ? Colors.white : c.fg,
                ),
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
      return _Uptime(
        since: widget.app.vpn.since ?? DateTime.now(),
        style: style,
      );
    }
    if (status == VpnStatus.blocked) {
      return Text(
        'Связь потеряна, пробую восстановить. Нажмите кнопку, чтобы отключить.',
        textAlign: TextAlign.center,
        style: style,
      );
    }
    if (widget.app.profile == null && status == VpnStatus.off) {
      return Text('Добавьте профиль, чтобы начать', style: style);
    }
    return Text('', style: style);
  }

  Widget _profileArea(_Palette c) {
    final p = widget.app.profile;
    return _panel(
      c,
      child: p != null
          ? Row(
              children: [
                _iconBadge(c, Icons.vpn_key_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.maskedName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Профиль сохранён безопасно',
                        style: TextStyle(color: c.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _confirmDelete
                      ? 'Подтвердить удаление'
                      : 'Удалить профиль',
                  onPressed: _delete,
                  icon: Icon(
                    _confirmDelete
                        ? Icons.delete_forever_outlined
                        : Icons.delete_outline,
                  ),
                  color: _confirmDelete
                      ? Theme.of(context).colorScheme.error
                      : c.muted,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _iconBadge(c, Icons.add_link),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Добавить профиль',
                            style: TextStyle(
                              color: c.fg,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Вставьте ссылку подключения',
                            style: TextStyle(color: c.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
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
                      icon: Icon(Icons.content_paste, color: c.accent),
                      onPressed: _paste,
                    ),
                    filled: true,
                    fillColor: c.bg,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: c.ring),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: c.accent, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить профиль'),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFC0463A),
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Время работы VPN. Таймер идёт только пока приложение открыто на экране,
/// в фоне он остановлен, чтобы не будить процессор.
class _Uptime extends StatefulWidget {
  const _Uptime({required this.since, required this.style});

  final DateTime since;
  final TextStyle style;

  @override
  State<_Uptime> createState() => _UptimeState();
}

class _UptimeState extends State<_Uptime> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
      setState(() {});
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since).inSeconds;
    final mm = (d ~/ 60).toString().padLeft(2, '0');
    final ss = (d % 60).toString().padLeft(2, '0');
    return Text(
      'РФ напрямую, остальное через VPN. $mm:$ss',
      textAlign: TextAlign.center,
      style: widget.style,
    );
  }
}
