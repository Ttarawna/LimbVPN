import 'package:flutter_test/flutter_test.dart';
import 'package:quiet_vpn/core/config_builder.dart';
import 'package:quiet_vpn/core/mieru_link.dart';

const _link =
    'mierus://baozi:manlianpenfen@1.2.3.4?multiplexing=MULTIPLEXING_HIGH'
    '&port=6666&port=9998-9999&protocol=TCP&protocol=UDP&profile=default';

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
      expect(() => MieruProfile.parse('https://example.com'),
          throwsA(isA<LinkFormatException>()));
      expect(() => MieruProfile.parse('mieru://abcdef'),
          throwsA(isA<LinkFormatException>()));
      expect(() => MieruProfile.parse('mierus://user@1.2.3.4?port=1&protocol=TCP'),
          throwsA(isA<LinkFormatException>()));
      expect(() => MieruProfile.parse('mierus://u:p@1.2.3.4?port=70000&protocol=TCP'),
          throwsA(isA<LinkFormatException>()));
      expect(() => MieruProfile.parse('mierus://u:p@1.2.3.4?port=1&port=2&protocol=TCP'),
          throwsA(isA<LinkFormatException>()));
    });
  });

  group('buildMihomoConfig', () {
    final profile = MieruProfile.parse(_link);

    test('исключает сервер из туннеля и маршрутов', () {
      final yaml = buildMihomoConfig(profile, serverIps: ['1.2.3.4']);
      expect(yaml, contains('route-exclude-address:\n    - 1.2.3.4/32'));
      expect(yaml, contains('- IP-CIDR,1.2.3.4/32,DIRECT,no-resolve'));
    });

    test('РФ напрямую, остальное через mieru, порядок правил верный', () {
      final yaml = buildMihomoConfig(profile, serverIps: ['1.2.3.4']);
      final server = yaml.indexOf('IP-CIDR,1.2.3.4/32');
      final ru = yaml.indexOf('GEOIP,RU,DIRECT');
      final match = yaml.indexOf('MATCH,mieru');
      expect(server, lessThan(ru));
      expect(ru, lessThan(match));
      expect(yaml, contains('port: 9998'));
      expect(yaml, contains('port: 9999'));
    });

    test('для сервера-домена добавляет правило DOMAIN', () {
      final p = MieruProfile.parse(
          'mierus://u:p@vpn.example.com?port=1000&protocol=TCP');
      final yaml = buildMihomoConfig(p, serverIps: ['203.0.113.5']);
      expect(yaml, contains('- DOMAIN,vpn.example.com,DIRECT'));
    });
  });
}
