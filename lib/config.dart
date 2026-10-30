// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:yaml/yaml.dart';

/// Default file name for the triage configuration file.
const String defaultConfigFileName = 'triage.yaml';

/// Default repositories inspected when none are passed on the command line.
const List<String> defaultRepos = <String>['flutter/packages', 'flutter/core-packages'];

/// Default repository where issues are tracked for [defaultRepos].
const String defaultIssuesRepo = 'flutter/flutter';

/// Default repository used by the in-page "Refresh report" button to trigger
/// the GitHub Actions workflow when not hosted on `*.github.io`.
const String defaultWorkflowRepo = 'tarrinneal/packages-triage';

/// Default file in each repository used to discover team members and suggested
/// package reviewers.
const String defaultRosterFile = 'SUGGESTED_REVIEWERS.md';

/// Default automated accounts that do not have GitHub user type `Bot` or a
/// `[bot]` suffix.
const Set<String> defaultBotAccounts = <String>{'fluttergithubbot', 'engine-flutter-autoroll'};

/// Default number of approvals a community PR needs before it is no longer
/// flagged as missing a reviewer.
const int defaultRequiredApprovals = 2;

/// PRs with any of these labels are hidden by default, since another triage
/// rotation handles them.
const Set<String> defaultHiddenLabels = <String>{'triage-design'};

/// Default label shown on the filter chip for PRs that do not have any of
/// [defaultHiddenLabels].
const String defaultNonHiddenFilterLabel = 'triage-packages';

/// Default label prefixes considered routing/display labels on PRs and issues.
const List<String> defaultRoutingLabelPrefixes = <String>['p: ', 'platform-', 'triage-'];

/// Default prefix used to match package labels against [defaultRosterFile].
const String defaultPackageLabelPrefix = 'p: ';

/// Labels indicating that an item is waiting on a response from the author.
const Set<String> defaultWaitingForResponseLabels = <String>{
  'waiting for response',
  'waiting-for-response',
  'waiting for customer response',
};

/// Default primary label identifying issues owned by the team.
const String defaultIssueTeamLabel = 'team-ecosystem';

/// Default secondary label identifying FYI issues for the team.
const String defaultIssueFyiLabel = 'fyi-ecosystem';

/// Default label indicating that an issue has been triaged by the team.
const String defaultIssueTriagedLabel = 'triaged-ecosystem';

/// Priority labels used on `flutter/flutter` issues, in descending priority
/// order.
const List<String> defaultPriorityLabels = <String>['P0', 'P1', 'P2', 'P3'];

/// Priority labels considered high priority on the issues page.
const Set<String> defaultHighPriorityLabels = <String>{'P0', 'P1'};

/// Configuration for repositories, labels, and roster lookup in the triage
/// tool.
///
/// A `const TriageConfig()` uses the `flutter/packages` ecosystem defaults.
class TriageConfig {
  /// Creates a configuration with the given settings, defaulting to the
  /// `flutter/packages` ecosystem configuration.
  const TriageConfig({
    this.repos = defaultRepos,
    this.issuesRepo = defaultIssuesRepo,
    this.workflowRepo = defaultWorkflowRepo,
    this.rosterFile = defaultRosterFile,
    this.botAccounts = defaultBotAccounts,
    this.requiredApprovals = defaultRequiredApprovals,
    this.hiddenLabels = defaultHiddenLabels,
    this.nonHiddenFilterLabel = defaultNonHiddenFilterLabel,
    this.routingLabelPrefixes = defaultRoutingLabelPrefixes,
    this.packageLabelPrefix = defaultPackageLabelPrefix,
    this.showAllLabels = false,
    this.waitingForResponseLabels = defaultWaitingForResponseLabels,
    this.issueTeamLabel = defaultIssueTeamLabel,
    this.issueFyiLabel = defaultIssueFyiLabel,
    this.issueTriagedLabel = defaultIssueTriagedLabel,
    this.priorityLabels = defaultPriorityLabels,
    this.highPriorityLabels = defaultHighPriorityLabels,
  });

  /// Parses a [TriageConfig] from a YAML or JSON string.
  ///
  /// Any omitted keys fall back to the defaults in `const TriageConfig()`.
  /// Throws a [FormatException] if [yamlContent] is not a valid mapping or
  /// contains invalid field types.
  factory TriageConfig.fromYaml(String yamlContent, {String? sourcePath}) {
    final Object? decoded;
    try {
      decoded = loadYaml(yamlContent, sourceUrl: sourcePath == null ? null : Uri.file(sourcePath));
    } on YamlException catch (e) {
      throw FormatException('Invalid YAML in ${sourcePath ?? 'config'}: ${e.message}');
    }
    if (decoded == null) {
      return const TriageConfig();
    }
    if (decoded is! YamlMap) {
      throw FormatException(
        'Expected a YAML mapping at the root of ${sourcePath ?? 'config'}, '
        'got ${decoded.runtimeType}.',
      );
    }

    final YamlMap map = decoded;

    const knownKeys = <String>{
      'repos',
      'issues_repo',
      'workflow_repo',
      'roster_file',
      'bot_accounts',
      'required_approvals',
      'hidden_labels',
      'non_hidden_filter_label',
      'routing_label_prefixes',
      'package_label_prefix',
      'show_all_labels',
      'waiting_for_response_labels',
      'issue_team_label',
      'issue_fyi_label',
      'issue_triaged_label',
      'priority_labels',
      'high_priority_labels',
    };
    for (final Object? key in map.keys) {
      if (key is! String || !knownKeys.contains(key)) {
        throw FormatException('Unknown configuration key "$key" in ${sourcePath ?? 'config'}.');
      }
    }

    List<String>? readStringList(String key, {bool allowEmpty = true}) {
      if (!map.containsKey(key)) {
        return null;
      }
      final Object? value = map[key];
      if (value == null && allowEmpty) {
        return const <String>[];
      }
      if (value is! YamlList) {
        throw FormatException('Expected "$key" to be a list of strings.');
      }
      final result = <String>[];
      for (final Object? item in value) {
        if (item is! String || item.trim().isEmpty) {
          throw FormatException('Expected every entry in "$key" to be a non-empty string.');
        }
        result.add(item);
      }
      if (!allowEmpty && result.isEmpty) {
        throw FormatException('"$key" cannot be empty.');
      }
      return List<String>.unmodifiable(result);
    }

    String? readString(String key, {bool allowEmpty = false}) {
      if (!map.containsKey(key)) {
        return null;
      }
      final Object? value = map[key];
      if (value == null) {
        if (allowEmpty) {
          return '';
        }
        throw FormatException('"$key" cannot be null.');
      }
      if (value is! String) {
        throw FormatException('Expected "$key" to be a string.');
      }
      if (!allowEmpty && value.trim().isEmpty) {
        throw FormatException('"$key" cannot be empty.');
      }
      return value;
    }

    String? readNullableString(String key, {required String? defaultValue}) {
      if (!map.containsKey(key)) {
        return defaultValue;
      }
      final Object? value = map[key];
      if (value == null) {
        return null;
      }
      if (value is! String) {
        throw FormatException('Expected "$key" to be a string or null.');
      }
      final String trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    int? readPositiveInt(String key) {
      if (!map.containsKey(key)) {
        return null;
      }
      final Object? value = map[key];
      if (value is! int || value <= 0) {
        throw FormatException('Expected "$key" to be a positive integer.');
      }
      return value;
    }

    bool? readBool(String key) {
      if (!map.containsKey(key)) {
        return null;
      }
      final Object? value = map[key];
      if (value is! bool) {
        throw FormatException('Expected "$key" to be a boolean.');
      }
      return value;
    }

    final List<String> repos = readStringList('repos', allowEmpty: false) ?? defaultRepos;
    for (final repo in repos) {
      if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
        throw FormatException('"$repo" in "repos" is not in owner/repo form.');
      }
    }
    final String? issuesRepo = readNullableString('issues_repo', defaultValue: defaultIssuesRepo);
    if (issuesRepo != null && !RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(issuesRepo)) {
      throw FormatException('"$issuesRepo" in "issues_repo" is not in owner/repo form.');
    }

    final List<String> priorityLabels = readStringList('priority_labels') ?? defaultPriorityLabels;
    final List<String>? highPriorityList = readStringList('high_priority_labels');

    return TriageConfig(
      repos: repos,
      issuesRepo: issuesRepo,
      workflowRepo: readString('workflow_repo') ?? defaultWorkflowRepo,
      rosterFile: readString('roster_file', allowEmpty: true) ?? defaultRosterFile,
      botAccounts: Set<String>.unmodifiable(readStringList('bot_accounts') ?? defaultBotAccounts),
      requiredApprovals: readPositiveInt('required_approvals') ?? defaultRequiredApprovals,
      hiddenLabels: Set<String>.unmodifiable(
        readStringList('hidden_labels') ?? defaultHiddenLabels,
      ),
      nonHiddenFilterLabel:
          readString('non_hidden_filter_label', allowEmpty: true) ?? defaultNonHiddenFilterLabel,
      routingLabelPrefixes: readStringList('routing_label_prefixes') ?? defaultRoutingLabelPrefixes,
      packageLabelPrefix:
          readString('package_label_prefix', allowEmpty: true) ?? defaultPackageLabelPrefix,
      showAllLabels: readBool('show_all_labels') ?? false,
      waitingForResponseLabels: Set<String>.unmodifiable(
        readStringList('waiting_for_response_labels') ?? defaultWaitingForResponseLabels,
      ),
      issueTeamLabel: readNullableString('issue_team_label', defaultValue: defaultIssueTeamLabel),
      issueFyiLabel: readNullableString('issue_fyi_label', defaultValue: defaultIssueFyiLabel),
      issueTriagedLabel:
          readString('issue_triaged_label', allowEmpty: true) ?? defaultIssueTriagedLabel,
      priorityLabels: priorityLabels,
      highPriorityLabels: highPriorityList != null
          ? Set<String>.unmodifiable(highPriorityList)
          : defaultHighPriorityLabels,
    );
  }

  /// Loads a [TriageConfig] from [file].
  factory TriageConfig.fromFile(File file) {
    final String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw FormatException('Could not read config file ${file.path}: ${e.message}');
    }
    return TriageConfig.fromYaml(content, sourcePath: file.path);
  }

  /// Default repositories to inspect for open PRs when none are specified on
  /// the command line.
  final List<String> repos;

  /// Repository where issues are tracked for [repos], or `null` to default to
  /// the PR repository itself.
  final String? issuesRepo;

  /// Repository (`owner/repo`) that hosts the `deploy_pages.yml` GitHub
  /// Actions workflow for the in-page "Refresh report" button.
  final String workflowRepo;

  /// Repository-relative path to the markdown file listing team reviewers and
  /// package reviewer mappings, or empty to disable fetching a roster file.
  final String rosterFile;

  /// Logins of automated accounts that should be treated as bots even if
  /// GitHub does not report their `type` as `Bot`.
  final Set<String> botAccounts;

  /// Number of approvals a community PR needs before it is no longer flagged
  /// as missing a reviewer.
  final int requiredApprovals;

  /// PR labels that start out hidden by default on the report.
  final Set<String> hiddenLabels;

  /// Label displayed on the filter toggle chip for PRs without [hiddenLabels].
  final String nonHiddenFilterLabel;

  /// Label prefixes displayed as chips on PR and issue rows.
  final List<String> routingLabelPrefixes;

  /// Label prefix used to look up package reviewer tooltips from [rosterFile].
  final String packageLabelPrefix;

  /// Whether to display all non-CLA labels as chips on PR and issue rows.
  final bool showAllLabels;

  /// Labels indicating that a PR or issue is waiting on the author's response.
  final Set<String> waitingForResponseLabels;

  /// Primary label identifying issues belonging to the team on the issues
  /// page, or `null` if the repository does not filter issues by a team label.
  final String? issueTeamLabel;

  /// Secondary label identifying FYI issues on the issues page, or `null` if
  /// the team does not use an FYI label.
  final String? issueFyiLabel;

  /// Label indicating that an issue has been triaged by the team.
  final String issueTriagedLabel;

  /// Priority labels in descending priority order (e.g. `['P0', 'P1', 'P2', 'P3']`).
  final List<String> priorityLabels;

  /// Priority labels that should be shown in the high-priority issues section
  /// even after being triaged (e.g. `{'P0', 'P1'}`).
  final Set<String> highPriorityLabels;

  /// Priority labels that are not in [highPriorityLabels] (e.g. `['P2', 'P3']`).
  List<String> get lowPriorityLabels =>
      priorityLabels.where((String p) => !highPriorityLabels.contains(p)).toList();
}

/// The default `triage.yaml` file for the package that contains [script]: the
/// file named [defaultConfigFileName] next to the nearest `pubspec.yaml` above
/// it.
///
/// Falls back to `triage.yaml` in the current directory if [script] isn't a
/// file or isn't in a package.
File configFileFor(Uri script) {
  final fallback = File(defaultConfigFileName);
  if (script.scheme != 'file') {
    return fallback.absolute;
  }
  Directory directory = File.fromUri(script).parent;
  while (true) {
    if (File('${directory.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return File('${directory.path}${Platform.pathSeparator}$defaultConfigFileName');
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      return fallback.absolute;
    }
    directory = parent;
  }
}
