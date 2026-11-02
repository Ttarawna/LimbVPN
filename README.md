# Limb VPN (Android)

Минималистичный клиент для протокола mieru. Ядро: Mihomo. Интерфейс: Flutter.
Сборка идёт на GitHub

## Что внутри

- `lib/`, `test/`: интерфейс Flutter, управление VPN через Android MethodChannel,
  разбор ссылок mierus:// и генератор конфига Mihomo.
- `core/`: обёртка на Go вокруг Mihomo (собирается в библиотеку для Android).
- `android_overlay/`: Kotlin-код (служба VPN, ядро в отдельном процессе, kill switch,
  автозапуск, обновление, защищённое хранилище), манифест, иконки.
- `tools/`: подготовка Android-проекта и патч библиотеки sing-tun при сборке.
- `.github/workflows/android.yml`: автосборка и публикация релиза.
