/// Разбор простой ссылки mieru:
/// mierus://логин:пароль@сервер?port=6666&port=9998-9999&protocol=TCP&protocol=UDP
///
/// Порты и протоколы в ссылке идут парами по порядку: port[i] работает по protocol[i].
library;

class LinkFormatException implements Exception {
  LinkFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PortBinding {
  const PortBinding(this.port, this.protocol);

  /// "6666" или диапазон "9998-9999".
  final String port;

  /// "TCP" или "UDP".
  final String protocol;

  bool get isRange => port.contains('-');
}

class MieruProfile {
  const MieruProfile({
    required this.link,
    required this.server,
    required this.username,
    required this.password,
    required this.bindings,
    this.multiplexing,
  });

  /// Исходная ссылка (по ней профиль сохраняется и восстанавливается).
  final String link;
  final String server;
  final String username;
  final String password;
  final List<PortBinding> bindings;

  /// Например MULTIPLEXING_HIGH. Может отсутствовать.
  final String? multiplexing;

  String get name => server;

  static MieruProfile parse(String raw) {
    final text = raw.trim();
    if (text.startsWith('mieru://')) {
      throw LinkFormatException(
          'Ссылки mieru:// пока не поддерживаются. Нужна простая ссылка вида mierus://');
    }
    if (!text.startsWith('mierus://')) {
      throw LinkFormatException('Ссылка должна начинаться с mierus://');
    }
    final uri = Uri.tryParse(text);
    if (uri == null) {
      throw LinkFormatException('Не удалось разобрать ссылку');
    }
    if (uri.host.isEmpty) {
      throw LinkFormatException('В ссылке не указан адрес сервера');
    }

    final info = uri.userInfo;
    final colon = info.indexOf(':');
    if (colon <= 0 || colon == info.length - 1) {
      throw LinkFormatException('В ссылке нет логина или пароля');
    }
    final username = _decode(info.substring(0, colon));
    final password = _decode(info.substring(colon + 1));

    final ports = uri.queryParametersAll['port'] ?? const <String>[];
    final protocols = uri.queryParametersAll['protocol'] ?? const <String>[];
    if (ports.isEmpty) {
      throw LinkFormatException('В ссылке не указан порт');
    }
    if (ports.length != protocols.length) {
      throw LinkFormatException(
          'Число портов и протоколов в ссылке не совпадает');
    }

    final bindings = <PortBinding>[];
    for (var i = 0; i < ports.length; i++) {
      final port = ports[i].trim();
      final protocol = protocols[i].trim().toUpperCase();
      if (!_validPort(port)) {
        throw LinkFormatException('Неверный порт в ссылке: $port');
      }
      if (protocol != 'TCP' && protocol != 'UDP') {
        throw LinkFormatException('Неизвестный протокол в ссылке: $protocol');
      }
      bindings.add(PortBinding(port, protocol));
    }

    final mux = uri.queryParameters['multiplexing'];
    return MieruProfile(
      link: text,
      server: uri.host,
      username: username,
      password: password,
      bindings: bindings,
      multiplexing: (mux != null && mux.startsWith('MULTIPLEXING_')) ? mux : null,
    );
  }

  static String _decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  static bool _validPort(String p) {
    final parts = p.split('-');
    if (parts.length > 2) return false;
    final nums = parts.map(int.tryParse).toList();
    for (final n in nums) {
      if (n == null || n < 1 || n > 65535) return false;
    }
    return nums.length == 1 || nums[0]! <= nums[1]!;
  }
}
