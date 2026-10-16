// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:pr_inspector/token.dart';
import 'package:test/test.dart';

Directory _tempDir() {
  final Directory dir = Directory.systemTemp.createTempSync('token_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

File _writeFile(Directory dir, String name, String contents) =>
    File('${dir.path}${Platform.pathSeparator}$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);

void main() {
  group('readEnvValue', () {
    test('reads a plain value', () {
      expect(readEnvValue('GITHUB_TOKEN=abc', 'GITHUB_TOKEN'), 'abc');
    });

    test('accepts export prefixes, quotes, and spaces', () {
      expect(readEnvValue('export GITHUB_TOKEN=abc', 'GITHUB_TOKEN'), 'abc');
      expect(readEnvValue('GITHUB_TOKEN="abc"', 'GITHUB_TOKEN'), 'abc');
      expect(readEnvValue("GITHUB_TOKEN='abc'", 'GITHUB_TOKEN'), 'abc');
      expect(readEnvValue('  GITHUB_TOKEN = abc  ', 'GITHUB_TOKEN'), 'abc');
    });

    test('ignores comments and blank lines', () {
      const contents = '''
# GITHUB_TOKEN=commented-out

GITHUB_TOKEN=abc # the real one
OTHER="x" # GITHUB_TOKEN=nope
''';
      expect(readEnvValue(contents, 'GITHUB_TOKEN'), 'abc');
    });

    test('keeps everything inside quotes, but not comments after them', () {
      expect(readEnvValue('GITHUB_TOKEN="a #b" # comment', 'GITHUB_TOKEN'), 'a #b');
    });

    test('uses the last value, like a shell would', () {
      expect(readEnvValue('GITHUB_TOKEN=old\nGITHUB_TOKEN=new', 'GITHUB_TOKEN'), 'new');
    });

    test('only matches the exact key', () {
      expect(readEnvValue('GITHUB_TOKEN_OLD=abc\nMY_GITHUB_TOKEN=def', 'GITHUB_TOKEN'), isNull);
    });

    test('distinguishes an empty value from a missing entry', () {
      expect(readEnvValue('GITHUB_TOKEN=\n', 'GITHUB_TOKEN'), '');
      expect(readEnvValue('', 'GITHUB_TOKEN'), isNull);
    });

    test('handles Windows line endings', () {
      expect(readEnvValue('# comment\r\nGITHUB_TOKEN=abc\r\n', 'GITHUB_TOKEN'), 'abc');
    });
  });

  group('findToken', () {
    test('prefers the environment variable', () {
      final File envFile = _writeFile(_tempDir(), '.env', 'GITHUB_TOKEN=from-file');
      expect(
        findToken(environment: <String, String>{'GITHUB_TOKEN': 'from-env'}, envFile: envFile),
        (value: 'from-env', source: 'the GITHUB_TOKEN environment variable'),
      );
    });

    test('falls back to the file if the variable is unset or empty', () {
      final File envFile = _writeFile(_tempDir(), '.env', 'GITHUB_TOKEN=from-file\n');
      final GitHubToken expected = (value: 'from-file', source: envFile.path);
      expect(findToken(environment: <String, String>{}, envFile: envFile), expected);
      expect(
        findToken(environment: <String, String>{'GITHUB_TOKEN': ' '}, envFile: envFile),
        expected,
      );
    });

    test('returns null if the file is missing or has no token', () {
      final Directory dir = _tempDir();
      final missing = File('${dir.path}${Platform.pathSeparator}.env');
      expect(findToken(environment: <String, String>{}, envFile: missing), isNull);
      final File placeholder = _writeFile(dir, '.env', '# Paste it below.\nGITHUB_TOKEN=\n');
      expect(findToken(environment: <String, String>{}, envFile: placeholder), isNull);
    });
  });

  group('envFileFor', () {
    test('finds .env next to the pubspec above the script', () {
      final Directory dir = _tempDir();
      _writeFile(dir, 'pubspec.yaml', 'name: example\n');
      final File script = _writeFile(dir, 'bin/tool.dart', '');
      expect(envFileFor(script.uri).path, '${dir.path}${Platform.pathSeparator}.env');
    });

    test('uses the current directory if the script is not a file', () {
      expect(
        envFileFor(Uri.parse('data:application/dart;charset=utf-8,')).path,
        File('.env').absolute.path,
      );
    });
  });
}
