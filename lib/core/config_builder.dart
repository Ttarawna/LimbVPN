import 'dart:convert';
import 'dart:io';

import 'mieru_link.dart';

String _q(String s) => jsonEncode(s); // JSON-строка корректна и для YAML

/// Собирает конфиг Mihomo из профиля mieru.
///
/// [serverIps] — IP-адреса сервера, определённые ДО поднятия туннеля.
/// Они исключаются из туннеля, чтобы трафик к серверу не зациклился.
String buildMihomoConfig(
  MieruProfile p, {
  required List<String> serverIps,
  bool dnsProtection = true,
  bool blockIpv6 = true,
}) {
  final b = StringBuffer();
  final excluded =
      serverIps.map((ip) => ip.contains(':') ? '$ip/128' : '$ip/32').toList();
  final serverIsIp = InternetAddress.tryParse(p.server) != null;
  const ruDns = '[77.88.8.8, 77.88.8.1]';

  b.writeln('mixed-port: 7890');
  b.writeln('mode: rule');
  b.writeln('log-level: debug');
  b.writeln('ipv6: ${!blockIpv6}');
  b.writeln('find-process-mode: off');
  b.writeln('geodata-mode: true');
  b.writeln('geo-auto-update: true');
  b.writeln('geo-update-interval: 24');
  b.writeln('geox-url:');
  b.writeln('  geoip: "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"');
  b.writeln('  geosite: "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"');

  b.writeln('tun:');
  b.writeln('  enable: true');
  b.writeln('  stack: mixed');
  b.writeln('  auto-route: true');
  b.writeln('  auto-detect-interface: true');
  b.writeln('  strict-route: true');
  b.writeln('  dns-hijack:');
  b.writeln('    - any:53');
  if (excluded.isNotEmpty) {
    b.writeln('  route-exclude-address:');
    for (final e in excluded) {
      b.writeln('    - $e');
    }
  }

  b.writeln('dns:');
  b.writeln('  enable: true');
  b.writeln('  ipv6: ${!blockIpv6}');
  b.writeln('  enhanced-mode: fake-ip');
  b.writeln('  fake-ip-range: 198.18.0.1/16');
  b.writeln('  fake-ip-filter: ["+.ru", "+.su", "+.xn--p1ai"]');
  b.writeln('  default-nameserver: $ruDns');
  b.writeln('  proxy-server-nameserver: [77.88.8.8]');
  if (dnsProtection) {
    b.writeln('  nameserver: ["https://1.1.1.1/dns-query#mieru"]');
    b.writeln('  nameserver-policy:');
    for (final d in ['+.ru', '+.su', '+.xn--p1ai', 'geosite:category-ru']) {
      b.writeln('    ${_q(d)}: $ruDns');
    }
  } else {
    b.writeln('  nameserver: [system]');
  }

  b.writeln('proxies:');
  final names = <String>[];
  for (var i = 0; i < p.bindings.length; i++) {
    final bind = p.bindings[i];
    final name = 'mieru-${i + 1}';
    names.add(name);
    b.writeln('  - name: $name');
    b.writeln('    type: mieru');
    b.writeln('    server: ${_q(p.server)}');
    b.writeln(bind.isRange
        ? '    port-range: ${_q(bind.port)}'
        : '    port: ${bind.port}');
    b.writeln('    transport: ${bind.protocol}');
    b.writeln('    username: ${_q(p.username)}');
    b.writeln('    password: ${_q(p.password)}');
    b.writeln('    udp: true');
    if (p.multiplexing != null) {
      b.writeln('    multiplexing: ${p.multiplexing}');
    }
  }

  b.writeln('proxy-groups:');
  b.writeln('  - name: mieru');
  b.writeln('    type: fallback');
  b.writeln('    proxies: [${names.join(', ')}]');
  b.writeln('    url: https://www.gstatic.com/generate_204');
  b.writeln('    interval: 300');

  // Порядок важен: сервер, локальные сети, РФ, остальное через VPN.
  b.writeln('rules:');
  for (final ip in serverIps) {
    b.writeln(ip.contains(':')
        ? '  - IP-CIDR6,$ip/128,DIRECT,no-resolve'
        : '  - IP-CIDR,$ip/32,DIRECT,no-resolve');
  }
  if (!serverIsIp) b.writeln('  - DOMAIN,${p.server},DIRECT');
  b.writeln('  - GEOIP,PRIVATE,DIRECT,no-resolve');
  b.writeln('  - DOMAIN-SUFFIX,ru,DIRECT');
  b.writeln('  - DOMAIN-SUFFIX,su,DIRECT');
  b.writeln('  - DOMAIN-SUFFIX,xn--p1ai,DIRECT');
  b.writeln('  - GEOSITE,category-ru,DIRECT');
  b.writeln('  - GEOIP,RU,DIRECT,no-resolve');
  b.writeln('  - MATCH,mieru');

  return b.toString();
}
