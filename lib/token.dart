// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

/// The name of the environment variable, and of the `.env` file entry, that
/// holds the GitHub token.
const String tokenVariable = 'GITHUB_TOKEN';

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

/// Returns the GitHub token from the [tokenVariable] environment variable if
/// it is set, and otherwise from the [tokenVariable] entry in [envFile].
///
/// The environment variable wins so that a token can be overridden for a
/// single run. Returns null if neither has a token.
GitHubToken? findToken({required Map<String, String> environment, required File envFile}) {
  final String fromEnvironment = environment[tokenVariable]?.trim() ?? '';
  if (fromEnvironment.isNotEmpty) {
    return (value: fromEnvironment, source: 'the $tokenVariable environment variable');
  }
  final String contents;
  try {
    contents = envFile.readAsStringSync();
  } on FileSystemException {
    return null;
  }
  final String fromFile = readEnvValue(contents, tokenVariable) ?? '';
  return fromFile.isEmpty ? null : (value: fromFile, source: envFile.path);
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
