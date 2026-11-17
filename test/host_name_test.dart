import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extendedscreen/shared/platform/host_name.dart';

void main() {
  group('macDisplayName', () {
    test('is the Computer Name, not what the network calls the machine',
        () async {
      final name = await macDisplayName(
        readComputerName: () async => 'MacBook Pro ของ porto \n',
        readHostName: () => 'host123.corp.example.com',
      );
      expect(name, 'MacBook Pro ของ porto');
    });

    test('falls back to the first label of the host name', () async {
      String host = 'MacBook-Pro-khxng-porto.local';
      Future<String> fallback(ComputerNameReader reader) =>
          macDisplayName(readComputerName: reader, readHostName: () => host);

      expect(await fallback(() async => null), 'MacBook-Pro-khxng-porto');
      expect(await fallback(() async => '   '), 'MacBook-Pro-khxng-porto');
      expect(
          await fallback(
              () async => throw const ProcessException('scutil', [])),
          'MacBook-Pro-khxng-porto');

      // A VPN's reverse DNS name: at least not the whole domain.
      host = 'host123.corp.example.com';
      expect(await fallback(() async => null), 'host123');
    });

    test('is never empty', () async {
      expect(
          await macDisplayName(
              readComputerName: () async => '', readHostName: () => ''),
          'Mac');
      expect(
          await macDisplayName(
              readComputerName: () async => null, readHostName: () => '.local'),
          '.local');
    });

    test('fits the 64 bytes a packet gives it without splitting a character',
        () async {
      // 30 Thai letters: 90 bytes of UTF-8.
      final long = 'ก' * 30;
      final name = await macDisplayName(
          readComputerName: () async => long, readHostName: () => 'x');
      final bytes = utf8.encode(name);
      expect(bytes.length, lessThanOrEqualTo(maxHostNameBytes));
      expect(name, 'ก' * 21, reason: '21 whole letters are 63 bytes');
      expect(utf8.decode(bytes), name);
    });

    test('reads the real Computer Name on a Mac', () async {
      final name = await macDisplayName();
      expect(name, isNotEmpty);
      expect(utf8.encode(name).length, lessThanOrEqualTo(maxHostNameBytes));
      final expected = (await Process.run(
              '/usr/sbin/scutil', const ['--get', 'ComputerName']))
          .stdout
          .toString()
          .trim();
      if (expected.isNotEmpty) {
        expect(name, truncateUtf8(expected, maxHostNameBytes));
      }
    }, skip: Platform.isMacOS ? null : 'macOS only');
  });

  test('firstHostLabel', () {
    expect(firstHostLabel('MacBook-Pro.local'), 'MacBook-Pro');
    expect(firstHostLabel('host123.corp.example.com'), 'host123');
    expect(firstHostLabel('studio'), 'studio');
    expect(firstHostLabel('  studio.local  '), 'studio');
  });

  test('truncateUtf8 cuts between characters', () {
    expect(truncateUtf8('abc', 10), 'abc');
    expect(truncateUtf8('abcdef', 3), 'abc');
    expect(truncateUtf8('aกข', 4), 'aก'); // 1 + 3 bytes; the next needs 3 more
    expect(truncateUtf8('Mac 😀', 5), 'Mac'); // the emoji is 4 bytes
    expect(truncateUtf8('', 5), '');
  });
}
