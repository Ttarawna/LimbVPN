import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/config_builder.dart';
import 'package:quiet_vpn/core/mieru_link.dart';

const _link =
    'mierus://baozi:manlianpenfen@1.2.3.4?multiplexing=MULTIPLEXING_HIGH'
    '&port=6666&port=9998-9999&protocol=TCP&protocol=UDP&profile=default';

const _localDnsServers = ['192.0.2.53', '2001:db8::53'];

void main() {
  group('MieruProfile.parse', () {
    test('разбирает простую ссылку', () {
      final p = MieruProfile.parse(_link);
      expect(p.server, '1.2.3.4');
      expect(p.username, 'baozi');
      expect(p.password, 'manlianpenfen');
      expect(p.bindings.length, 2);
      expect(p.bindings[1].port, '9998-9999');
      expect(p.bindings[1].protocol, 'UDP');
      expect(p.bindings[1].isRange, isTrue);
      expect(p.multiplexing, 'MULTIPLEXING_HIGH');
    });

    test('отклоняет чужие и неполные ссылки', () {
      expect(
        () => MieruProfile.parse('https://example.com'),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () => MieruProfile.parse('mieru://abcdef'),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () => MieruProfile.parse('mierus://user@1.2.3.4?port=1&protocol=TCP'),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () =>
            MieruProfile.parse('mierus://u:p@1.2.3.4?port=70000&protocol=TCP'),
        throwsA(isA<LinkFormatException>()),
      );
      expect(
        () => MieruProfile.parse(
          'mierus://u:p@1.2.3.4?port=1&port=2&protocol=TCP',
        ),
        throwsA(isA<LinkFormatException>()),
      );
    });

    test('ignores multiplexing values that are not known enum values', () {
      final p = MieruProfile.parse(
        'mierus://user:pass@1.2.3.4?port=443&protocol=TCP'
        '&multiplexing=MULTIPLEXING_HIGH%0Aexternal-controller:%200.0.0.0:9090',
      );
      final yaml = buildMihomoConfig(
        p,
        serverIps: ['1.2.3.4'],
        localDnsServers: _localDnsServers,
      );

      expect(p.multiplexing, isNull);
      expect(yaml, isNot(contains('external-controller')));
      expect(yaml, contains('    udp: true'));
    });
  });

  group('buildMihomoConfig', () {
    final profile = MieruProfile.parse(_link);

    test('исключает сервер из туннеля и маршрутов', () {
      final yaml = buildMihomoConfig(
        profile,
        serverIps: ['1.2.3.4'],
        localDnsServers: _localDnsServers,
      );
      expect(yaml, contains('route-exclude-address:\n    - 1.2.3.4/32'));
      expect(yaml, contains('- IP-CIDR,1.2.3.4/32,DIRECT,no-resolve'));
    });

    test('РФ напрямую, остальное через mieru, порядок правил верный', () {
      final yaml = buildMihomoConfig(
        profile,
        serverIps: ['1.2.3.4'],
        localDnsServers: _localDnsServers,
      );
      final server = yaml.indexOf('IP-CIDR,1.2.3.4/32');
      final ru = yaml.indexOf('GEOIP,RU,DIRECT');
      final match = yaml.indexOf('MATCH,mieru');
      expect(server, lessThan(ru));
      expect(ru, lessThan(match));
      final quic = yaml.indexOf('NETWORK,UDP),(DST-PORT,443');
      expect(quic, greaterThan(ru));
      expect(quic, lessThan(match));
      expect(yaml, contains('lazy: true'));
      expect(yaml, contains('port: 9998'));
      expect(yaml, contains('port: 9999'));
    });

    test('для сервера-домена добавляет правило DOMAIN', () {
      final p = MieruProfile.parse(
        'mierus://u:p@vpn.example.com?port=1000&protocol=TCP',
      );
      final yaml = buildMihomoConfig(
        p,
        serverIps: ['203.0.113.5', '203.0.113.6'],
        localDnsServers: _localDnsServers,
      );
      expect(yaml, contains('- DOMAIN,vpn.example.com,DIRECT'));
      expect(yaml, contains('server: "203.0.113.5"'));
      expect(yaml, contains('server: "203.0.113.6"'));
      expect(yaml, isNot(contains('server: "vpn.example.com"')));
    });
    test('RU использует локальный DNS, прочие домены — DoH через VPN', () {
      final yaml = buildMihomoConfig(
        profile,
        serverIps: ['1.2.3.4'],
        localDnsServers: _localDnsServers,
      );

      expect(yaml, contains('nameserver: ["https://1.1.1.1/dns-query#mieru"]'));
      expect(yaml, contains('nameserver-policy:'));
      expect(yaml, contains('"+.ru": ["192.0.2.53","2001:db8::53"]'));
      expect(
        yaml,
        contains('"geosite:category-ru": ["192.0.2.53","2001:db8::53"]'),
      );
      expect(yaml, isNot(contains('nameserver: [system]')));
      expect(yaml, isNot(contains('default-nameserver:')));
    });

    test('рекламные домены блокируются до правил маршрутизации РФ', () {
      final yaml = buildMihomoConfig(
        profile,
        serverIps: ['1.2.3.4'],
        localDnsServers: _localDnsServers,
        adBlock: true,
      );

      final ads = yaml.indexOf('GEOSITE,category-ads-all,REJECT');
      expect(ads, greaterThanOrEqualTo(0));
      expect(ads, lessThan(yaml.indexOf('DOMAIN-SUFFIX,ru,DIRECT')));
    });

    test('не использует IPv6-адрес VPN-сервера при блокировке IPv6', () {
      const p = MieruProfile(
        link: 'mierus://user:pass@vpn.example.com?port=1000&protocol=TCP',
        server: 'vpn.example.com',
        username: 'user',
        password: 'pass',
        bindings: [PortBinding('1000', 'TCP')],
      );
      final yaml = buildMihomoConfig(
        p,
        serverIps: ['2001:db8::1', '203.0.113.5'],
        localDnsServers: _localDnsServers,
      );

      expect(yaml, contains('server: "203.0.113.5"'));
      expect(yaml, isNot(contains('server: "2001:db8::1"')));
      expect(
        () => buildMihomoConfig(
          p,
          serverIps: ['2001:db8::1'],
          localDnsServers: _localDnsServers,
        ),
        throwsArgumentError,
      );
    });

    test('rejects missing local DNS rather than using a fallback', () {
      expect(
        () => buildMihomoConfig(
          profile,
          serverIps: ['1.2.3.4'],
          localDnsServers: const [],
        ),
        throwsArgumentError,
      );
    });
  });
}
