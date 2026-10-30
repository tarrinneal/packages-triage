// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

/// The name of the primary environment variable, and of the `.env` file entry,
/// that holds the GitHub token.
const String tokenVariable = 'GITHUB_TOKEN';

/// The fallback environment variable used by the GitHub CLI (`gh`).
const String ghTokenVariable = 'GH_TOKEN';

/// A GitHub token, and where it came from, for error messages.
typedef GitHubToken = ({String value, String source});

/// The `.env` file for the package that contains [script]: the file named
/// `.env` next to the nearest `pubspec.yaml` above it.
///
/// This lets the tool find its `.env` file no matter which directory it is run
/// from. Falls back to `.env` in the current directory if [script] isn't a
/// file or isn't in a package.
File envFileFor(Uri script) {
  final fallback = File('.env');
  if (script.scheme != 'file') {
    return fallback.absolute;
  }
  Directory directory = File.fromUri(script).parent;
  while (true) {
    if (File('${directory.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return File('${directory.path}${Platform.pathSeparator}.env');
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      return fallback.absolute;
    }
    directory = parent;
  }
}

/// Candidate `.env` files to search, in priority order:
/// 1. `.env` in [currentDirectory] (when different from the package `.env` and
///    present on disk, useful when running a globally activated binary),
/// 2. [envFileFor] the running [script], and
/// 3. `~/.config/pr_inspector/.env` (or `$XDG_CONFIG_HOME/pr_inspector/.env`).
List<File> candidateEnvFiles(
  Uri script, {
  Directory? currentDirectory,
  Map<String, String>? environment,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final File scriptEnv = envFileFor(script);
  final seenPaths = <String>{};
  final result = <File>[];

  void addIfNew(File file) {
    final String normalized = file.absolute.path;
    if (seenPaths.add(normalized)) {
      result.add(file);
    }
  }

  final Directory cwd = currentDirectory ?? Directory.current;
  final cwdEnv = File('${cwd.path}${Platform.pathSeparator}.env');
  if (cwdEnv.existsSync()) {
    addIfNew(cwdEnv);
  }
  addIfNew(scriptEnv);

  final String? xdgConfig = env['XDG_CONFIG_HOME']?.trim();
  final String? home = env['HOME']?.trim() ?? env['USERPROFILE']?.trim();
  final String? configBase = (xdgConfig != null && xdgConfig.isNotEmpty)
      ? xdgConfig
      : (home != null && home.isNotEmpty ? '$home${Platform.pathSeparator}.config' : null);
  if (configBase != null) {
    addIfNew(
      File(
        '$configBase${Platform.pathSeparator}pr_inspector'
        '${Platform.pathSeparator}.env',
      ),
    );
  }
  return result;
}

/// Attempts to read a GitHub token from the GitHub CLI (`gh auth token`).
///
/// Returns `null` if `gh` is not installed or not authenticated.
String? readGhCliToken() {
  try {
    final ProcessResult result = Process.runSync('gh', const <String>['auth', 'token']);
    if (result.exitCode == 0 && result.stdout is String) {
      final String token = (result.stdout as String).trim();
      if (token.isNotEmpty) {
        return token;
      }
    }
  } on ProcessException {
    // `gh` is not installed or not on PATH.
  }
  return null;
}

/// Returns the GitHub token from the [tokenVariable] (or [ghTokenVariable])
/// environment variable if set, otherwise from [envFile] or
/// [additionalEnvFiles], and finally from [ghCliToken] if provided.
///
/// The environment variable wins so that a token can be overridden for a
/// single run. Returns null if no source has a token.
GitHubToken? findToken({
  required Map<String, String> environment,
  required File envFile,
  Iterable<File> additionalEnvFiles = const <File>[],
  String? Function()? ghCliToken,
}) {
  for (final variable in const <String>[tokenVariable, ghTokenVariable]) {
    final String fromEnvironment = environment[variable]?.trim() ?? '';
    if (fromEnvironment.isNotEmpty) {
      return (value: fromEnvironment, source: 'the $variable environment variable');
    }
  }
  final seen = <String>{};
  for (final candidate in <File>[envFile, ...additionalEnvFiles]) {
    if (!seen.add(candidate.absolute.path)) {
      continue;
    }
    final String contents;
    try {
      contents = candidate.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final variable in const <String>[tokenVariable, ghTokenVariable]) {
      final String fromFile = readEnvValue(contents, variable) ?? '';
      if (fromFile.isNotEmpty) {
        return (value: fromFile, source: candidate.path);
      }
    }
  }
  if (ghCliToken != null) {
    final String fromGh = ghCliToken()?.trim() ?? '';
    if (fromGh.isNotEmpty) {
      return (value: fromGh, source: 'the GitHub CLI (gh auth token)');
    }
  }
  return null;
}

/// Reads a configuration [key] from [environment] first, then from the first
/// matching entry in [envFiles].
String? readConfigValue({
  required Map<String, String> environment,
  required Iterable<File> envFiles,
  required String key,
}) {
  final String fromEnv = environment[key]?.trim() ?? '';
  if (fromEnv.isNotEmpty) {
    return fromEnv;
  }
  for (final file in envFiles) {
    try {
      final String? fromFile = readEnvValue(file.readAsStringSync(), key)?.trim();
      if (fromFile != null && fromFile.isNotEmpty) {
        return fromFile;
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// Returns the value for [key] in the contents of a `.env` file, or null if
/// there isn't one.
///
/// Supports `KEY=value` lines with an optional `export ` prefix, optionally
/// quoted values, comments, and blank lines. If [key] appears more than once,
/// the last value wins, as it would if the file were sourced by a shell.
String? readEnvValue(String contents, String key) {
  String? value;
  for (final String rawLine in const LineSplitter().convert(contents)) {
    String line = rawLine.trim();
    if (line.startsWith('export ')) {
      line = line.substring('export '.length).trimLeft();
    }
    final int equals = line.indexOf('=');
    if (line.startsWith('#') || equals <= 0 || line.substring(0, equals).trim() != key) {
      continue;
    }
    String entry = line.substring(equals + 1).trim();
    final int closingQuote = entry.startsWith('"') || entry.startsWith("'")
        ? entry.indexOf(entry[0], 1)
        : -1;
    if (closingQuote > 0) {
      entry = entry.substring(1, closingQuote);
    } else {
      // Unquoted values end at a comment.
      entry = entry.split(RegExp(r'\s+#')).first.trim();
    }
    value = entry;
  }
  return value;
}
