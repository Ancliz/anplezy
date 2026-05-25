import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/manual_server_utils.dart';

void main() {
  group('ManualServerUtils.parseServerUrl', () {
    test('defaults bare hostnames to local HTTP on the Plex port', () {
      final parsed = ManualServerUtils.parseServerUrl('example');

      expect(parsed?.protocol, 'http');
      expect(parsed?.address, 'example');
      expect(parsed?.port, plexDefaultPort);
      expect(parsed?.uri, 'http://example:32400');
    });

    test('parses common local host forms', () {
      final cases = <({String input, String protocol, String address, int port, String uri})>[
        (
          input: 'plex.local',
          protocol: 'http',
          address: 'plex.local',
          port: plexDefaultPort,
          uri: 'http://plex.local:32400',
        ),
        (
          input: 'example.home.arpa:32401',
          protocol: 'http',
          address: 'example.home.arpa',
          port: 32401,
          uri: 'http://example.home.arpa:32401',
        ),
        (
          input: 'localhost:32400',
          protocol: 'http',
          address: 'localhost',
          port: plexDefaultPort,
          uri: 'http://localhost:32400',
        ),
        (
          input: '192.168.1.20',
          protocol: 'http',
          address: '192.168.1.20',
          port: plexDefaultPort,
          uri: 'http://192.168.1.20:32400',
        ),
        (
          input: 'http://10.0.0.5:32401',
          protocol: 'http',
          address: '10.0.0.5',
          port: 32401,
          uri: 'http://10.0.0.5:32401',
        ),
      ];

      for (final testCase in cases) {
        final parsed = ManualServerUtils.parseServerUrl(testCase.input);

        expect(parsed?.protocol, testCase.protocol, reason: testCase.input);
        expect(parsed?.address, testCase.address, reason: testCase.input);
        expect(parsed?.port, testCase.port, reason: testCase.input);
        expect(parsed?.uri, testCase.uri, reason: testCase.input);
      }
    });

    test('normalizes scheme and host casing', () {
      final parsed = ManualServerUtils.parseServerUrl('HTTPS://Plex.Example:443');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, 443);
      expect(parsed?.uri, 'https://plex.example:443');
    });

    test('parses bracketed IPv6 addresses', () {
      final explicit = ManualServerUtils.parseServerUrl('http://[fd00::1]:32401');
      final defaultPort = ManualServerUtils.parseServerUrl('[fd00::1]');

      expect(explicit?.protocol, 'http');
      expect(explicit?.address, 'fd00::1');
      expect(explicit?.port, 32401);
      expect(explicit?.uri, 'http://[fd00::1]:32401');

      expect(defaultPort?.protocol, 'http');
      expect(defaultPort?.address, 'fd00::1');
      expect(defaultPort?.port, plexDefaultPort);
      expect(defaultPort?.uri, 'http://[fd00::1]:32400');
    });

    test('preserves explicit protocol and port', () {
      final parsed = ManualServerUtils.parseServerUrl('https://plex.example:34403');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, 34403);
      expect(parsed?.uri, 'https://plex.example:34403');
    });

    test('preserves explicit default protocol port', () {
      final parsed = ManualServerUtils.parseServerUrl('https://plex.example:443');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, 443);
      expect(parsed?.uri, 'https://plex.example:443');
    });

    test('uses Plex port when protocol is present but port is omitted', () {
      final parsed = ManualServerUtils.parseServerUrl('https://plex.example');

      expect(parsed?.protocol, 'https');
      expect(parsed?.address, 'plex.example');
      expect(parsed?.port, plexDefaultPort);
      expect(parsed?.uri, 'https://plex.example:32400');
    });

    test('trims input and rejects invalid URLs', () {
      expect(ManualServerUtils.parseServerUrl('  http://example:32400  ')?.uri, 'http://example:32400');
      expect(ManualServerUtils.parseServerUrl(''), isNull);
      expect(ManualServerUtils.parseServerUrl('ftp://example:32400'), isNull);
      expect(ManualServerUtils.parseServerUrl('http://'), isNull);
    });

    test('rejects malformed URLs and unsupported schemes', () {
      final invalidInputs = [
        ' ',
        '://plex.example',
        'plex://plex.example',
        'ftp://plex.example:32400',
        'http://',
        'https://',
        'http://:32400',
        'http:///plex.example',
        'http://plex.example:',
        'http://plex.example:notaport',
        'http://plex.example:-1',
        'http://plex.example:0',
        'http://plex.example:99999',
        'http://user@plex.example:32400',
        'http://plex.example/',
        'http://plex.example:32400/',
        'http://plex.example:32400/web/index.html',
        'http://plex.example:32400?token=nope',
        'http://plex.example:32400#hash',
        'plex.example/web',
        'plex.example?token=nope',
        'plex.example#hash',
        'fd00::1',
        'https://[fd00::1',
      ];

      for (final input in invalidInputs) {
        expect(ManualServerUtils.parseServerUrl(input), isNull, reason: input);
      }
    });
  });
}
