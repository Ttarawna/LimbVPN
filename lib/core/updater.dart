import 'dart:convert';

import 'package:flutter/services.dart';

class UpdateInfo {
  const UpdateInfo(this.version, this.url, this.sha256);

  final String version;
  final String url;
  final String sha256;
}

/// Автообновление. На Android берёт новые версии из релизов GitHub.
abstract class UpdateService {
  /// Новая версия или null, если обновлений нет. При ошибке проверки бросает исключение.
  Future<UpdateInfo?> check();

  /// Скачивает и устанавливает обновление. Возвращает текст ошибки или null.
  /// [onProgress] получает проценты загрузки.
  Future<String?> install(UpdateInfo info, void Function(int percent) onProgress);

  void setErrorHandler(void Function(String message) handler);
}

class NoUpdateService implements UpdateService {
  @override
  Future<UpdateInfo?> check() async => throw UnsupportedError(
      'Проверка обновлений доступна только на Android');

  @override
  Future<String?> install(UpdateInfo info, void Function(int percent) onProgress) async =>
      'Обновление пока доступно только на Android';

  @override
  void setErrorHandler(void Function(String message) handler) {}
}

class AndroidUpdateService implements UpdateService {
  AndroidUpdateService() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('quiet/update');

  void Function(int percent)? _progress;
  void Function(String message)? _error;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'progress') {
      _progress?.call(call.arguments as int);
    } else if (call.method == 'status') {
      final s = call.arguments as String;
      if (s.startsWith('error:')) _error?.call(s.substring(6));
    }
  }

  @override
  void setErrorHandler(void Function(String message) handler) => _error = handler;

  @override
  Future<UpdateInfo?> check() async {
    final text = await _channel.invokeMethod<String>('check');
    if (text == null || text.isEmpty) return null;
    final m = jsonDecode(text) as Map<String, dynamic>;
    return UpdateInfo(
      m['version'] as String,
      m['url'] as String,
      (m['sha256'] as String?) ?? '',
    );
  }

  @override
  Future<String?> install(UpdateInfo info, void Function(int percent) onProgress) async {
    _progress = onProgress;
    try {
      final r = await _channel.invokeMethod<String>(
          'install', {'url': info.url, 'sha256': info.sha256});
      if (r == 'ok') return null;
      if (r == 'need_permission') {
        return 'Разрешите Limb VPN устанавливать приложения и нажмите «Обновить» ещё раз';
      }
      if (r != null && r.startsWith('error:')) return r.substring(6);
      return 'Не удалось установить обновление';
    } catch (e) {
      return 'Не удалось установить обновление: $e';
    } finally {
      _progress = null;
    }
  }
}
