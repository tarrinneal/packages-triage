// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:pr_inspector/detail_cache.dart';
import 'package:test/test.dart';

final DateTime _start = DateTime.utc(2026, 10);
const Map<String, dynamic> _details = <String, dynamic>{'saved': true};

void main() {
  late Directory tempDir;
  late File file;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('detail_cache_test');
    file = File('${tempDir.path}/cache/o_r.json');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  DetailCache load({int days = 0, bool refresh = false, List<String>? warnings}) =>
      DetailCache.load(
        file,
        repo: 'o/r',
        now: _start.add(Duration(days: days)),
        refresh: refresh,
        onWarning: warnings?.add,
      );

  test('reuses details until the PR changes', () {
    load()
      ..store(1, 'v1', _details)
      ..save();
    final DetailCache cache = load(days: 1);
    expect(cache.lookup(1, 'v1'), _details);
    expect(cache.lookup(1, 'v2'), isNull);
    expect(cache.lookup(2, 'v1'), isNull);
    expect(cache.reusedCount, 1);
  });

  test('removes PRs once they have not been seen open for a week', () {
    load()
      ..store(1, 'v1', _details)
      ..store(2, 'v1', _details)
      ..save();
    // Six days later, PR 1 is still open but hasn't changed, and PR 2 has
    // closed.
    load(days: 6)
      ..markSeen(<int>[1])
      ..save();
    final DetailCache cache = load(days: 12);
    expect(cache.lookup(1, 'v1'), _details);
    expect(cache.lookup(2, 'v1'), isNull);
    // A week after PR 1 was last seen, it's gone too.
    expect(load(days: 13).lookup(1, 'v1'), isNull);
  });

  test('refresh ignores saved details but still saves new ones', () {
    load()
      ..store(1, 'v1', _details)
      ..save();
    final DetailCache cache = load(refresh: true);
    expect(cache.lookup(1, 'v1'), isNull);
    cache
      ..store(1, 'v2', _details)
      ..save();
    expect(load().lookup(1, 'v2'), _details);
  });

  test('ignores unreadable files, and files for other repositories or versions', () {
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{not json');
    final warnings = <String>[];
    expect(load(warnings: warnings).lookup(1, 'v1'), isNull);
    expect(warnings, hasLength(1));

    load()
      ..store(1, 'v1', _details)
      ..save();
    expect(DetailCache.load(file, repo: 'o/other', now: _start).lookup(1, 'v1'), isNull);

    file.writeAsStringSync(file.readAsStringSync().replaceFirst('"version":1', '"version":0'));
    expect(load().lookup(1, 'v1'), isNull);
  });

  test('is saved in the per-user cache directory, outside any repository', () {
    String directory(String operatingSystem, Map<String, String> environment) =>
        cacheDirectory(environment: environment, operatingSystem: operatingSystem).path;
    final String separator = Platform.pathSeparator;
    const localAppData = r'C:\Users\me\AppData\Local';

    expect(
      directory('macos', <String, String>{'HOME': '/Users/me'}),
      '/Users/me/Library/Caches${separator}pr_inspector',
    );
    expect(
      directory('linux', <String, String>{'HOME': '/home/me'}),
      '/home/me/.cache${separator}pr_inspector',
    );
    expect(
      directory('linux', <String, String>{'HOME': '/home/me', 'XDG_CACHE_HOME': '/xdg'}),
      '/xdg${separator}pr_inspector',
    );
    expect(
      directory('windows', <String, String>{'LOCALAPPDATA': localAppData}),
      '$localAppData${separator}pr_inspector',
    );
    expect(
      detailCacheFileFor('flutter/packages', directory: Directory('/cache')).path,
      '/cache${separator}flutter_packages.json',
    );
  });
}
