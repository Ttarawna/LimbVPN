// lib/core/vpn_service.dart

/// Интерфейс для управления VPN-сервисом.
/// Все операции должны быть асинхронными, так как взаимодействие с сетевым стеком является блокирующей операцией.
abstract class VpnService {
  /// Проверяет, запущен ли VPN-клиент.
  /// Возвращает true, если соединение активно, иначе false.
  Future<bool> isVpnActive();

  /// Запрашивает и пытается установить VPN-соединение.
  /// Возвращает результат (успех/ошибка), в зависимости от того, удалось ли подключиться к Mieru-серверу.
  Future<VpnStatus> connect(VpnConfig config);

  /// Отключает VPN-соединение и прерывает активную сессию Mieru.
  Future<void> disconnect();
}

/// Статус текущей сессии VPN.
enum VpnStatus {
  DISCONNECTED,
  CONNECT_FAILED,
  CONNECT_PENDING,
  CONNECTED
}

/// Конфигурация VPN для инициализации подключения.
class VpnConfig {
  final String serverAddress; // IP или домен сервера Mieru
  final int port;
  final String encryptionKey; // Ключ шифрования для протокола Mieru

  VpnConfig({required this.serverAddress, required this.port, required this.encryptionKey});
}