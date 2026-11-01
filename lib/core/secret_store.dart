import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Хранилище секретов (ссылка профиля с паролем).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android: данные шифруются AES-256-GCM, ключ лежит в Android Keystore.
class ChannelSecretStore implements SecretStore {
  static const _channel = MethodChannel('quiet/vpn');

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('secureGet', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('secureSet', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('secureDelete', {'key': key});
}

/// Остальные платформы (пока без шифрования; будет заменено на Keychain и т.д.).
class PrefsSecretStore implements SecretStore {
  PrefsSecretStore(this._prefs);

  final SharedPreferences _prefs;

  String _k(String key) => 'secret_$key';

  @override
  Future<String?> read(String key) async => _prefs.getString(_k(key));

  @override
  Future<void> write(String key, String value) async {
    await _prefs.setString(_k(key), value);
  }

  @override
  Future<void> delete(String key) async {
    await _prefs.remove(_k(key));
  }
}
