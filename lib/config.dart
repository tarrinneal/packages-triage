// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'dart:io';

import 'types.dart';

/// Default configuration used when no `configs/*.dart` files are present.
///
/// To configure the hosted pages or add multiple team dashboards, edit or add
/// `.dart` files in the `configs/` directory (see `configs/ecosystem.dart`).
const TriageConfig defaultConfig = TriageConfig(
  repos: <String>['flutter/packages', 'flutter/core-packages'],
  flutterTeam: 'ecosystem',
  refreshSchedule: '37 19 * * 2',
  teamMembers: <String>[
    'adsonpleal',
    'bkonyi',
    'bparrishMines',
    'camsim99',
    'chunhtai',
    'ditman',
    'dkwingsmt',
    'domesticmouse',
    'gmackall',
    'hannah-hyj',
    'hellohuanlin',
    'Hixie',
    'jesswrd',
    'jtmcdole',
    'LongCatIsLooong',
    'louisehsu',
    'mboetger',
    'mdebbar',
    'okorohelijah',
    'parlough',
    'Piinks',
    'qunccccccc',
    'reidbaker',
    'robert-ancell',
    'sokoloff06',
    'stuartmorgan-g',
    'tarrinneal',
    'vashworth',
    'victorsanni',
    'yjbanov',
  ],
  rosterFile: 'flutter/packages:SUGGESTED_REVIEWERS.md',
  hiddenLabels: <String>{'triage-design'},
  nonHiddenFilterLabel: 'triage-packages',
);

/// Default directory name containing per-page `.dart` config files.
const String defaultConfigsDirName = 'configs';

/// The `configs/` directory next to the nearest `pubspec.yaml` above [script].
Directory configsDirectoryFor(Uri script) {
  final fallback = Directory(defaultConfigsDirName);
  if (script.scheme != 'file') {
    return fallback.absolute;
  }
  Directory directory = File.fromUri(script).parent;
  while (true) {
    if (File('${directory.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return Directory('${directory.path}${Platform.pathSeparator}$defaultConfigsDirName');
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      return fallback.absolute;
    }
    directory = parent;
  }
}

/// Loads all `*.dart` configuration files from [directory], keyed by filename
/// stem (e.g. `'ecosystem'` for `configs/ecosystem.dart`).
///
/// If `'ecosystem'` is present, it is placed first so it serves as the root
/// default page; remaining configs are ordered alphabetically.
Map<String, TriageConfig> loadConfigsDirectory(Directory directory) {
  if (!directory.existsSync()) {
    return const <String, TriageConfig>{};
  }
  final List<File> files = directory
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();
  if (files.isEmpty) {
    return const <String, TriageConfig>{};
  }

  String stemOf(File file) {
    final String name = file.uri.pathSegments.last;
    return name.substring(0, name.length - '.dart'.length);
  }

  files.sort((File a, File b) {
    final String stemA = stemOf(a);
    final String stemB = stemOf(b);
    if (stemA == 'ecosystem' && stemB != 'ecosystem') {
      return -1;
    }
    if (stemB == 'ecosystem' && stemA != 'ecosystem') {
      return 1;
    }
    return stemA.compareTo(stemB);
  });

  return <String, TriageConfig>{
    for (final File file in files) stemOf(file): parseDartConfigFile(file),
  };
}

/// Parses a [TriageConfig] from a Dart config [file].
TriageConfig parseDartConfigFile(File file) {
  final String content;
  try {
    content = file.readAsStringSync();
  } on FileSystemException catch (e) {
    throw FormatException('Could not read config file ${file.path}: ${e.message}');
  }
  return parseDartConfig(content, sourcePath: file.path);
}

/// Extracts unique `@<username>` handles from a `SUGGESTED_REVIEWERS.md` file,
/// preserving the first-seen casing of each handle and sorting
/// case-insensitively.
List<String> extractSuggestedReviewerHandles(String markdown) {
  final byLower = <String, String>{};
  for (final Match match in RegExp(r'@([A-Za-z0-9-]+)').allMatches(markdown)) {
    final String handle = match.group(1)!;
    byLower.putIfAbsent(handle.toLowerCase(), () => handle);
  }
  final List<String> handles = byLower.values.toList()
    ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return List<String>.unmodifiable(handles);
}

/// Updates the `teamMembers` list in a Dart config file's source [dartSource]
/// to match [teamMembers].
String updateTeamMembersInDartConfig(String dartSource, List<String> teamMembers) {
  final String formattedItems = <String>[
    for (final String member in teamMembers) "    '$member',",
  ].join('\n');
  final replacementBlock =
      '  teamMembers: <String>[\n'
      '${formattedItems.isNotEmpty ? '$formattedItems\n' : ''}'
      '  ],';

  final existingPattern = RegExp(
    r'^[ \t]*teamMembers:\s*(?:const\s*)?(?:<\s*String\s*>\s*)?\[[^\]]*\],?',
    multiLine: true,
  );
  if (existingPattern.hasMatch(dartSource)) {
    return dartSource.replaceFirst(existingPattern, replacementBlock);
  }

  final afterFlutterTeam = RegExp(r'^([ \t]*flutterTeam:[^\n]*\n)', multiLine: true);
  if (afterFlutterTeam.hasMatch(dartSource)) {
    return dartSource.replaceFirstMapped(
      afterFlutterTeam,
      (Match m) => '${m.group(1)}$replacementBlock\n',
    );
  }

  final constructorStart = RegExp(r'TriageConfig\s*\(\s*\n');
  if (constructorStart.hasMatch(dartSource)) {
    return dartSource.replaceFirstMapped(
      constructorStart,
      (Match m) => '${m.group(0)}$replacementBlock\n',
    );
  }
  throw const FormatException('Could not locate TriageConfig(...) in Dart config source');
}

/// Updates the `schedule:` section in `.github/workflows/deploy_pages.yml`
/// ([workflowYaml]) so its `- cron:` entries match the [TriageConfig.refreshSchedule]
/// values across [configs].
String updateWorkflowSchedulesInYaml(String workflowYaml, Map<String, TriageConfig> configs) {
  final byCron = <String, List<String>>{};
  for (final MapEntry<String, TriageConfig> entry in configs.entries) {
    final String? cron = entry.value.refreshSchedule?.trim();
    if (cron != null && cron.isNotEmpty) {
      byCron.putIfAbsent(cron, () => <String>[]).add(entry.key);
    }
  }
  if (byCron.isEmpty) {
    return workflowYaml;
  }

  final scheduleBuffer = StringBuffer()
    ..writeln('  schedule:')
    ..writeln('    # Synced from configs/*.dart (edit refreshSchedule in configs/<name>.dart):');
  for (final MapEntry<String, List<String>> entry in byCron.entries) {
    scheduleBuffer.writeln("    - cron: '${entry.key}' # ${entry.value.join(', ')}");
  }

  final schedulePattern = RegExp(r'^  schedule:\n(?:    [^\n]*\n)+', multiLine: true);
  if (schedulePattern.hasMatch(workflowYaml)) {
    return workflowYaml.replaceFirst(schedulePattern, scheduleBuffer.toString());
  }
  return workflowYaml;
}

/// Parses a `TriageConfig(...)` constant expression from Dart source code.
TriageConfig parseDartConfig(String dartSource, {String? sourcePath}) {
  final parser = _DartConfigParser(dartSource, sourcePath: sourcePath ?? 'config.dart');
  return parser.parse();
}

class _DartConfigParser {
  _DartConfigParser(this.source, {required this.sourcePath});

  final String source;
  final String sourcePath;
  int _index = 0;

  static const Set<String> _knownKeys = <String>{
    'repos',
    'flutterTeam',
    'refreshSchedule',
    'teamMembers',
    'issuesRepo',
    'workflowRepo',
    'rosterFile',
    'botAccounts',
    'requiredApprovals',
    'hiddenLabels',
    'nonHiddenFilterLabel',
    'routingLabelPrefixes',
    'packageLabelPrefix',
    'showAllLabels',
    'waitingForResponseLabels',
    'issueTeamLabel',
    'issueFyiLabel',
    'issueTriagedLabel',
    'priorityLabels',
    'highPriorityLabels',
  };

  Never _error(String message) => throw FormatException('$message in $sourcePath');

  TriageConfig parse() {
    // Strip comments while preserving string literals so we can locate the
    // `TriageConfig(...)` constructor invocation reliably.
    final int callStart = _findConstructorBody();
    _index = callStart;
    final args = <String, Object?>{};

    while (true) {
      _skipWhitespaceAndComments();
      if (_index >= source.length) {
        _error('Unexpected end of file inside TriageConfig(...)');
      }
      if (source[_index] == ')') {
        _index++;
        break;
      }
      final String key = _readIdentifier();
      if (key.isEmpty) {
        _error('Expected parameter name in TriageConfig(...)');
      }
      if (!_knownKeys.contains(key)) {
        _error('Unknown TriageConfig parameter "$key"');
      }
      _skipWhitespaceAndComments();
      if (_index >= source.length || source[_index] != ':') {
        _error('Expected ":" after "$key"');
      }
      _index++;
      _skipWhitespaceAndComments();
      args[key] = _readValue(key);
      _skipWhitespaceAndComments();
      if (_index < source.length && source[_index] == ',') {
        _index++;
      } else if (_index < source.length && source[_index] == ')') {
        // Closing parenthesis handled on next iteration.
      } else {
        _error('Expected "," or ")" after "$key" value');
      }
    }

    List<String>? stringList(String key, {bool allowEmpty = true}) {
      if (!args.containsKey(key)) {
        return null;
      }
      final Object? val = args[key];
      if (val is Set<String>) {
        if (!allowEmpty && val.isEmpty) {
          _error('"$key" cannot be empty');
        }
        return List<String>.unmodifiable(val);
      }
      if (val is! List<String>) {
        _error('Expected "$key" to be a List<String>');
      }
      if (!allowEmpty && val.isEmpty) {
        _error('"$key" cannot be empty');
      }
      return List<String>.unmodifiable(val);
    }

    Set<String>? stringSet(String key) {
      if (!args.containsKey(key)) {
        return null;
      }
      final Object? val = args[key];
      if (val is Set<String>) {
        return Set<String>.unmodifiable(val);
      }
      if (val is List<String>) {
        return Set<String>.unmodifiable(val);
      }
      _error('Expected "$key" to be a Set<String>');
    }

    String? nullableString(String key, {required String? defaultIfOmitted}) {
      if (!args.containsKey(key)) {
        return defaultIfOmitted;
      }
      final Object? val = args[key];
      if (val != null && val is! String) {
        _error('Expected "$key" to be a String or null');
      }
      return val as String?;
    }

    String? nonNullString(String key) {
      if (!args.containsKey(key)) {
        return null;
      }
      final Object? val = args[key];
      if (val is! String) {
        _error('Expected "$key" to be a String');
      }
      return val;
    }

    int? positiveInt(String key) {
      if (!args.containsKey(key)) {
        return null;
      }
      final Object? val = args[key];
      if (val is! int || val <= 0) {
        _error('Expected "$key" to be a positive int');
      }
      return val;
    }

    bool? boolean(String key) {
      if (!args.containsKey(key)) {
        return null;
      }
      final Object? val = args[key];
      if (val is! bool) {
        _error('Expected "$key" to be a bool');
      }
      return val;
    }

    final List<String> repos = stringList('repos', allowEmpty: false) ?? defaultRepos;
    for (final repo in repos) {
      if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
        _error('"$repo" in "repos" is not in owner/repo form');
      }
    }
    final String? flutterTeam = nullableString('flutterTeam', defaultIfOmitted: 'ecosystem');
    final String? refreshSchedule = nullableString(
      'refreshSchedule',
      defaultIfOmitted: defaultRefreshSchedule,
    );
    if (refreshSchedule != null &&
        refreshSchedule.isNotEmpty &&
        !RegExp(r'^\S+(\s+\S+){4}$').hasMatch(refreshSchedule.trim())) {
      _error('"$refreshSchedule" in "refreshSchedule" is not a 5-field cron expression');
    }
    final String? issuesRepo = nullableString('issuesRepo', defaultIfOmitted: defaultIssuesRepo);
    if (issuesRepo != null && !RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(issuesRepo)) {
      _error('"$issuesRepo" in "issuesRepo" is not in owner/repo form');
    }

    const unset = '\x00unset';
    final String? rosterFileArg = nullableString('rosterFile', defaultIfOmitted: unset);
    final String? issueTeamArg = nullableString('issueTeamLabel', defaultIfOmitted: unset);
    final String? issueFyiArg = nullableString('issueFyiLabel', defaultIfOmitted: unset);
    final String? issueTriagedArg = nullableString('issueTriagedLabel', defaultIfOmitted: unset);

    return TriageConfig(
      repos: repos,
      flutterTeam: flutterTeam,
      refreshSchedule: refreshSchedule != null && refreshSchedule.isEmpty ? null : refreshSchedule,
      teamMembers: stringList('teamMembers') ?? const <String>[],
      issuesRepo: issuesRepo,
      workflowRepo: nonNullString('workflowRepo') ?? defaultWorkflowRepo,
      rosterFile: identical(rosterFileArg, unset)
          ? (flutterTeam == 'ecosystem' ? defaultRosterFile : null)
          : rosterFileArg,
      botAccounts: stringSet('botAccounts') ?? defaultBotAccounts,
      requiredApprovals: positiveInt('requiredApprovals') ?? defaultRequiredApprovals,
      hiddenLabels: stringSet('hiddenLabels') ?? defaultHiddenLabels,
      nonHiddenFilterLabel: nonNullString('nonHiddenFilterLabel') ?? defaultNonHiddenFilterLabel,
      routingLabelPrefixes: stringList('routingLabelPrefixes') ?? defaultRoutingLabelPrefixes,
      packageLabelPrefix: nonNullString('packageLabelPrefix') ?? defaultPackageLabelPrefix,
      showAllLabels: boolean('showAllLabels') ?? false,
      waitingForResponseLabels:
          stringSet('waitingForResponseLabels') ?? defaultWaitingForResponseLabels,
      issueTeamLabel: identical(issueTeamArg, unset)
          ? (flutterTeam != null ? 'team-$flutterTeam' : null)
          : issueTeamArg,
      issueFyiLabel: identical(issueFyiArg, unset)
          ? (flutterTeam != null ? 'fyi-$flutterTeam' : null)
          : issueFyiArg,
      issueTriagedLabel: identical(issueTriagedArg, unset)
          ? (flutterTeam != null ? 'triaged-$flutterTeam' : 'triaged')
          : (issueTriagedArg ?? ''),
      priorityLabels: stringList('priorityLabels') ?? defaultPriorityLabels,
      highPriorityLabels: stringSet('highPriorityLabels') ?? defaultHighPriorityLabels,
    );
  }

  int _findConstructorBody() {
    _index = 0;
    while (_index < source.length) {
      _skipWhitespaceAndComments();
      if (_index >= source.length) {
        break;
      }
      if (source[_index] == "'" || source[_index] == '"') {
        _readStringLiteral();
        continue;
      }
      final String ident = _readIdentifier();
      if (ident == 'TriageConfig') {
        _skipWhitespaceAndComments();
        if (_index < source.length && source[_index] == '(') {
          return _index + 1;
        }
      } else if (ident.isEmpty) {
        _index++;
      }
    }
    _error('Could not find TriageConfig(...) constructor call');
  }

  void _skipWhitespaceAndComments() {
    while (_index < source.length) {
      final String ch = source[_index];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        _index++;
        continue;
      }
      if (ch == '/' && _index + 1 < source.length) {
        if (source[_index + 1] == '/') {
          _index += 2;
          while (_index < source.length && source[_index] != '\n') {
            _index++;
          }
          continue;
        }
        if (source[_index + 1] == '*') {
          _index += 2;
          while (_index + 1 < source.length &&
              !(source[_index] == '*' && source[_index + 1] == '/')) {
            _index++;
          }
          _index += 2;
          continue;
        }
      }
      break;
    }
  }

  String _readIdentifier() {
    final int start = _index;
    while (_index < source.length && RegExp(r'[A-Za-z0-9_]').hasMatch(source[_index])) {
      _index++;
    }
    return source.substring(start, _index);
  }

  Object? _readValue(String key) {
    _skipWhitespaceAndComments();
    if (_index >= source.length) {
      _error('Missing value for "$key"');
    }
    final String ch = source[_index];
    if (ch == "'" || ch == '"') {
      return _readStringLiteral();
    }
    if (ch == '[' || ch == '{') {
      return _readCollection(key);
    }
    if (ch == '<') {
      _skipTypeArguments();
      _skipWhitespaceAndComments();
      return _readCollection(key);
    }
    if (RegExp(r'[0-9]').hasMatch(ch)) {
      final int start = _index;
      while (_index < source.length && RegExp(r'[0-9]').hasMatch(source[_index])) {
        _index++;
      }
      return int.parse(source.substring(start, _index));
    }
    final String word = _readIdentifier();
    if (word == 'const') {
      _skipWhitespaceAndComments();
      if (_index < source.length && source[_index] == '<') {
        _skipTypeArguments();
        _skipWhitespaceAndComments();
      }
      return _readCollection(key);
    }
    switch (word) {
      case 'null':
        return null;
      case 'true':
        return true;
      case 'false':
        return false;
      case 'defaultRepos':
        return defaultRepos;
      case 'defaultRefreshSchedule':
        return defaultRefreshSchedule;
      case 'defaultIssuesRepo':
        return defaultIssuesRepo;
      case 'defaultWorkflowRepo':
        return defaultWorkflowRepo;
      case 'defaultRosterFile':
        return defaultRosterFile;
      case 'defaultBotAccounts':
        return defaultBotAccounts;
      case 'defaultRequiredApprovals':
        return defaultRequiredApprovals;
      case 'defaultHiddenLabels':
        return defaultHiddenLabels;
      case 'defaultNonHiddenFilterLabel':
        return defaultNonHiddenFilterLabel;
      case 'defaultRoutingLabelPrefixes':
        return defaultRoutingLabelPrefixes;
      case 'defaultPackageLabelPrefix':
        return defaultPackageLabelPrefix;
      case 'defaultWaitingForResponseLabels':
        return defaultWaitingForResponseLabels;
      case 'defaultIssueTeamLabel':
        return defaultIssueTeamLabel;
      case 'defaultIssueFyiLabel':
        return defaultIssueFyiLabel;
      case 'defaultIssueTriagedLabel':
        return defaultIssueTriagedLabel;
      case 'defaultPriorityLabels':
        return defaultPriorityLabels;
      case 'defaultHighPriorityLabels':
        return defaultHighPriorityLabels;
      default:
        _error('Unsupported value "$word" for "$key"');
    }
  }

  void _skipTypeArguments() {
    if (_index >= source.length || source[_index] != '<') {
      return;
    }
    var depth = 0;
    while (_index < source.length) {
      if (source[_index] == '<') {
        depth++;
      } else if (source[_index] == '>') {
        depth--;
        if (depth == 0) {
          _index++;
          return;
        }
      }
      _index++;
    }
    _error('Unterminated type argument list');
  }

  Object _readCollection(String key) {
    if (_index >= source.length || (source[_index] != '[' && source[_index] != '{')) {
      _error('Expected list or set literal for "$key"');
    }
    final isSet = source[_index] == '{';
    final closing = isSet ? '}' : ']';
    _index++;
    final items = <String>[];
    while (true) {
      _skipWhitespaceAndComments();
      if (_index >= source.length) {
        _error('Unterminated collection for "$key"');
      }
      if (source[_index] == closing) {
        _index++;
        break;
      }
      if (source[_index] != "'" && source[_index] != '"') {
        _error('Expected string literal inside "$key"');
      }
      items.add(_readStringLiteral());
      _skipWhitespaceAndComments();
      if (_index < source.length && source[_index] == ',') {
        _index++;
      } else if (_index < source.length && source[_index] == closing) {
        // Closing delimiter handled on next iteration.
      } else {
        _error('Expected "," or "$closing" inside "$key"');
      }
    }
    return isSet ? Set<String>.unmodifiable(items) : List<String>.unmodifiable(items);
  }

  String _readStringLiteral() {
    final String quote = source[_index];
    _index++;
    final buffer = StringBuffer();
    while (_index < source.length) {
      final String ch = source[_index++];
      if (ch == quote) {
        return buffer.toString();
      }
      if (ch == r'\') {
        if (_index >= source.length) {
          _error('Unterminated escape sequence in string literal');
        }
        final String escaped = source[_index++];
        switch (escaped) {
          case 'n':
            buffer.write('\n');
          case 'r':
            buffer.write('\r');
          case 't':
            buffer.write('\t');
          default:
            buffer.write(escaped);
        }
      } else {
        buffer.write(ch);
      }
    }
    _error('Unterminated string literal');
  }
}
