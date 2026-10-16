// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

/// Bump this when the saved format changes, so old caches are ignored.
const int _formatVersion = 1;

/// The per-user directory where the tool saves data between runs.
///
/// This is the platform's cache directory, so the data is never inside a
/// repository: `~/Library/Caches` on macOS, `%LOCALAPPDATA%` on Windows, and
/// `$XDG_CACHE_HOME` or `~/.cache` elsewhere.
Directory cacheDirectory({Map<String, String>? environment, String? operatingSystem}) {
  final Map<String, String> env = environment ?? Platform.environment;
  String? variable(String name) {
    final String? value = env[name];
    return value == null || value.isEmpty ? null : value;
  }

  final String? home = variable('HOME');
  final String? base = switch (operatingSystem ?? Platform.operatingSystem) {
    'macos' => home == null ? null : '$home/Library/Caches',
    'windows' => variable('LOCALAPPDATA'),
    _ => variable('XDG_CACHE_HOME') ?? (home == null ? null : '$home/.cache'),
  };
  return Directory('${base ?? Directory.systemTemp.path}${Platform.pathSeparator}pr_inspector');
}

/// The file in [directory] (by default, [cacheDirectory]) that holds the
/// [DetailCache] for [repo].
File detailCacheFileFor(String repo, {Directory? directory}) => File(
  '${(directory ?? cacheDirectory()).path}${Platform.pathSeparator}'
  '${repo.replaceAll('/', '_')}.json',
);

/// PR details saved between runs, so that PRs that haven't changed since an
/// earlier run don't need to be fetched again.
///
/// A PR's entry is only used while the PR's `updated_at` matches the one it
/// was saved with. Each entry also remembers when its PR was last seen open;
/// entries that haven't been seen for [maxUnseen] are removed, so closed PRs
/// don't pile up.
class DetailCache {
  DetailCache._(this.file, this.now, this.refresh, this._repo, this._entries) {
    _removeUnseen();
  }

  /// Loads the cache for [repo] from [file], as of [now].
  ///
  /// If [refresh] is true, [lookup] never returns saved details, but new ones
  /// are still saved. If [file] can't be read, calls [onWarning] and starts
  /// empty.
  factory DetailCache.load(
    File file, {
    required String repo,
    required DateTime now,
    bool refresh = false,
    void Function(String message)? onWarning,
  }) {
    final entries = <int, _Entry>{};
    try {
      final Object? json = jsonDecode(file.readAsStringSync());
      if (json case {
        'version': _formatVersion,
        'repo': final String savedRepo,
        'prs': final Map<String, dynamic> prs,
      } when savedRepo == repo) {
        for (final MapEntry<String, dynamic> pr in prs.entries) {
          final int? number = int.tryParse(pr.key);
          final _Entry? entry = _Entry.fromJson(pr.value);
          if (number != null && entry != null) {
            entries[number] = entry;
          }
        }
      }
    } on PathNotFoundException {
      // Nothing has been saved yet.
    } on FileSystemException catch (e) {
      onWarning?.call('Could not read the cache ${file.path}: ${e.message}');
    } on FormatException catch (e) {
      onWarning?.call('Ignoring the unreadable cache ${file.path}: ${e.message}');
    }
    return DetailCache._(file, now, refresh, repo, entries);
  }

  /// How long an entry is kept after its PR was last seen open.
  static const Duration maxUnseen = Duration(days: 7);

  /// Where the cache is saved.
  final File file;

  /// The time of this run, which is when PRs are seen and saved.
  final DateTime now;

  /// Whether [lookup] ignores saved details.
  final bool refresh;

  final String _repo;
  final Map<int, _Entry> _entries;
  int _reusedCount = 0;

  /// How many times [lookup] has returned saved details.
  int get reusedCount => _reusedCount;

  /// Returns the details saved for PR [number], if they were saved when its
  /// `updated_at` was [updatedAt].
  Map<String, dynamic>? lookup(int number, String updatedAt) {
    final _Entry? entry = _entries[number];
    if (refresh || entry == null || entry.updatedAt != updatedAt) {
      return null;
    }
    _reusedCount++;
    return entry.details;
  }

  /// Saves [details] for PR [number] as of its `updated_at` of [updatedAt].
  void store(int number, String updatedAt, Map<String, dynamic> details) {
    _entries[number] = _Entry(updatedAt: updatedAt, lastSeen: now, details: details);
  }

  /// Records that the PRs with [numbers] are still open, which keeps their
  /// entries for another [maxUnseen] whether or not they have changed.
  void markSeen(Iterable<int> numbers) {
    for (final number in numbers) {
      _entries[number]?.lastSeen = now;
    }
  }

  /// Writes the cache to [file], leaving out entries that haven't been seen
  /// for [maxUnseen].
  void save() {
    _removeUnseen();
    file.parent.createSync(recursive: true);
    // Write to a temporary file first so an interrupted run can't leave a
    // truncated cache behind.
    final temp = File('${file.path}.tmp')
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': _formatVersion,
          'repo': _repo,
          'prs': <String, Object?>{
            for (final MapEntry<int, _Entry> entry in _entries.entries)
              '${entry.key}': entry.value.toJson(),
          },
        }),
      );
    temp.renameSync(file.path);
  }

  void _removeUnseen() {
    _entries.removeWhere((int _, _Entry entry) => now.difference(entry.lastSeen) >= maxUnseen);
  }
}

class _Entry {
  _Entry({required this.updatedAt, required this.lastSeen, required this.details});

  static _Entry? fromJson(Object? json) {
    if (json case {
      'updatedAt': final String updatedAt,
      'lastSeen': final String lastSeen,
      'details': final Map<String, dynamic> details,
    }) {
      if (DateTime.tryParse(lastSeen) case final DateTime seen) {
        return _Entry(updatedAt: updatedAt, lastSeen: seen, details: details);
      }
    }
    return null;
  }

  final String updatedAt;
  DateTime lastSeen;
  final Map<String, dynamic> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'updatedAt': updatedAt,
    'lastSeen': lastSeen.toUtc().toIso8601String(),
    'details': details,
  };
}
