// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:args/args.dart';
import 'package:pr_inspector/detail_cache.dart';
import 'package:pr_inspector/github_client.dart';
import 'package:pr_inspector/html_output.dart';
import 'package:pr_inspector/pr_inspector.dart';
import 'package:pr_inspector/report_state.dart';
import 'package:pr_inspector/text_output.dart';
import 'package:pr_inspector/token.dart';
import 'package:pr_inspector/triage.dart';
import 'package:pr_inspector/types.dart';
import 'package:pr_inspector/utils.dart';

/// Thrown for invalid command-line usage.
class _UsageException implements Exception {
  _UsageException(this.message);

  final String message;
}

Future<void> main(List<String> arguments) async {
  const TriageConfig config = defaultConfig;
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      help:
          'Run a single Dart config file (e.g. configs/ecosystem.dart) instead of '
          'all configs in configs/.',
    )
    ..addOption(
      'only',
      help:
          'When building multi-config HTML from configs/, only refresh the named '
          'config (e.g. ecosystem) while preserving switcher links to all configs.',
    )
    ..addOption(
      'only-schedule',
      help:
          'When building multi-config HTML from configs/, only refresh configs '
          'whose refreshSchedule matches this cron expression.',
    )
    ..addOption('pr', abbr: 'p', help: 'Explain how a single PR is triaged, and why.')
    ..addOption(
      'html',
      help:
          'Write the report as HTML: community PRs to <file>, team PRs to '
          '<file name>_team.html, and package issues to <file name>_issues.html. '
          'When running multiple configs from configs/, also writes <dir>/<name>/*.html.',
    )
    ..addFlag('open', negatable: false, help: 'Open the HTML report when it is done.')
    ..addFlag(
      'issues',
      defaultsTo: true,
      help: 'Also fetch and triage issues (from flutter/flutter for flutter/packages).',
    )
    ..addFlag(
      'show-hidden',
      negatable: false,
      help:
          'Show PRs labeled ${config.hiddenLabels.join(', ')} by default. '
          '(The HTML report always has a button to show them.)',
    )
    ..addOption('limit', help: 'Only analyze the <n> newest open PRs, for quick checks.')
    ..addFlag(
      'refresh',
      negatable: false,
      help:
          'Fetch all comments and reviews again, instead of reusing saved ones for unchanged PRs.',
    )
    ..addOption(
      'record',
      help: 'Save every GitHub response to <file>, so the run can be repeated with --replay.',
    )
    ..addOption(
      'replay',
      help:
          'Use the responses saved by --record instead of calling GitHub. '
          'Use the same --limit or --pr as the recorded run.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
  final File envFile = envFileFor(Platform.script);
  final List<File> envFiles = candidateEnvFiles(Platform.script);
  final usage =
      '''
Usage: dart run bin/pr_inspector.dart [<owner>/<repo> ...] [options]

Sorts the open PRs in one or more repositories (configured in configs/*.dart)
by who needs to act next and how long they have been waiting.

Reads a GitHub token from the $tokenVariable (or $ghTokenVariable) environment variable,
from a "$tokenVariable=<token>" line in .env (${envFile.path} or ~/.config/pr_inspector/.env),
or from the GitHub CLI ("gh auth token").

Saves each PR's comments and reviews so that later runs only fetch PRs that have
changed, and removes them once a PR hasn't been seen open for ${DetailCache.maxUnseen.inDays} days. They are
saved in ${cacheDirectory().path}.

${parser.usage}''';

  try {
    await _run(parser.parse(arguments), usage, envFile, envFiles);
  } on ArgParserException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln()
      ..writeln(usage);
    exitCode = 64;
  } on _UsageException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln()
      ..writeln(usage);
    exitCode = 64;
  } on GitHubException catch (e) {
    stderr.writeln('Error: $e');
    exitCode = 1;
  }
}

Map<String, TriageConfig> _loadConfigs(ArgResults results) {
  final String? configPath = results.option('config');
  if (configPath != null) {
    final file = File(configPath);
    if (!file.existsSync()) {
      throw _UsageException('Config file $configPath does not exist.');
    }
    final String name = file.uri.pathSegments.last.replaceAll(RegExp(r'\.dart$'), '');
    try {
      return <String, TriageConfig>{name: parseDartConfigFile(file)};
    } on FormatException catch (e) {
      throw _UsageException('Invalid config file $configPath: ${e.message}');
    }
  }
  final Directory configsDir = configsDirectoryFor(Platform.script);
  try {
    final Map<String, TriageConfig> loaded = loadConfigsDirectory(configsDir);
    if (loaded.isNotEmpty) {
      return loaded;
    }
  } on FormatException catch (e) {
    throw _UsageException('Invalid config in ${configsDir.path}: ${e.message}');
  }
  return const <String, TriageConfig>{'ecosystem': defaultConfig};
}

Future<void> _run(ArgResults results, String usage, File envFile, List<File> envFiles) async {
  if (results.flag('help')) {
    stdout.writeln(usage);
    return;
  }
  final Map<String, TriageConfig> configs = _loadConfigs(results);
  final hasExplicitConfig = results.option('config') != null;
  final int? prNumber = _positiveInt(results, 'pr');
  if (prNumber != null && results.rest.length > 1) {
    throw _UsageException('Provide at most one repository when using --pr.');
  }
  for (final String repo in results.rest) {
    if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
      throw _UsageException('"$repo" is not a repository in owner/repo form.');
    }
  }
  final int? limit = _positiveInt(results, 'limit');
  final String? htmlPath = results.option('html');
  final String? recordPath = results.option('record');
  final String? replayPath = results.option('replay');
  final bool showHidden = results.flag('show-hidden');
  final bool includeIssues = results.flag('issues');
  final String? envWorkflowRepo = readConfigValue(
    environment: Platform.environment,
    envFiles: envFiles,
    key: 'GITHUB_REPOSITORY',
  );
  if (results.flag('open') && htmlPath == null) {
    throw _UsageException('--open requires --html.');
  }
  if (recordPath != null && replayPath != null) {
    throw _UsageException('--record and --replay cannot be used together.');
  }
  if (replayPath != null && !File(replayPath).existsSync()) {
    throw _UsageException('Replay file $replayPath does not exist.');
  }

  // Replays never contact GitHub, so they don't need a token.
  final GitHubToken? token = replayPath == null
      ? findToken(
          environment: Platform.environment,
          envFile: envFile,
          additionalEnvFiles: envFiles,
          ghCliToken: readGhCliToken,
        )
      : null;
  if (replayPath == null && token == null) {
    if (prNumber == null && limit == null) {
      throw _UsageException(
        'No GitHub token found. Add a "$tokenVariable=<token>" line to ${envFile.path}, '
        'set the $tokenVariable environment variable, or authenticate with "gh auth login". '
        'Without a token, GitHub allows 60 requests per hour, which is not enough for a full '
        'report; use --pr or --limit for a small anonymous run.',
      );
    }
    _warn('No GitHub token found in ${envFile.path}; using the anonymous rate limit.');
  }

  final client = GitHubClient(
    token: token?.value ?? '',
    replayFile: replayPath == null ? null : File(replayPath),
  );
  final stopwatch = Stopwatch()..start();
  try {
    final TriageConfig primaryConfig = configs.values.first;
    if (prNumber != null) {
      final String targetRepo = results.rest.isNotEmpty
          ? results.rest.first
          : primaryConfig.repos.first;
      final bool usesConfiguredRepos =
          hasExplicitConfig ||
          targetRepo.startsWith('flutter/') ||
          primaryConfig.repos.contains(targetRepo);
      await _explainPR(
        client,
        targetRepo,
        prNumber,
        requiredApprovals: usesConfiguredRepos ? primaryConfig.requiredApprovals : 1,
        config: primaryConfig,
      );
    } else if (results.rest.isNotEmpty || hasExplicitConfig || htmlPath == null) {
      // Single report run (explicit CLI repos, explicit --config file, or text output).
      final List<String> repos = results.rest.isNotEmpty ? results.rest : primaryConfig.repos;
      final bool usesConfiguredRepos =
          hasExplicitConfig ||
          repos.every((String r) => r.startsWith('flutter/') || primaryConfig.repos.contains(r));
      final bool refresh = results.flag('refresh') || recordPath != null;
      await _report(
        client,
        repos,
        limit: limit,
        htmlFile: htmlPath == null ? null : File(htmlPath),
        open: results.flag('open'),
        showHidden: showHidden,
        hiddenLabels: usesConfiguredRepos ? primaryConfig.hiddenLabels : const <String>{},
        showAllLabels: primaryConfig.showAllLabels || !usesConfiguredRepos,
        requiredApprovals: usesConfiguredRepos ? primaryConfig.requiredApprovals : 1,
        includeIssues: includeIssues,
        workflowRepo: envWorkflowRepo ?? primaryConfig.workflowRepo,
        usesConfiguredRepos: usesConfiguredRepos,
        config: primaryConfig,
        activeConfigName: configs.keys.first,
        live: replayPath == null,
        refresh: refresh,
      );
    } else {
      // Multi-config HTML build across configs/*.dart files (optionally filtered
      // by --only or --only-schedule while preserving switcher links to all configs).
      final rootHtmlFile = File(htmlPath);
      final Directory siteDir = rootHtmlFile.parent;
      final String baseName = rootHtmlFile.uri.pathSegments.last;
      final List<String> allConfigNames = configs.keys.toList();
      final String primaryName = allConfigNames.first;
      final bool refresh = results.flag('refresh') || recordPath != null;
      final String? onlyConfig = results.option('only')?.trim();
      final String? onlySchedule = results.option('only-schedule')?.trim();

      if (onlyConfig != null && onlyConfig.isNotEmpty && !configs.containsKey(onlyConfig)) {
        throw _UsageException(
          'Unknown config "$onlyConfig". Available configs: ${allConfigNames.join(', ')}',
        );
      }

      final targetEntries = <MapEntry<String, TriageConfig>>[
        for (final MapEntry<String, TriageConfig> entry in configs.entries)
          if ((onlyConfig == null || onlyConfig.isEmpty || entry.key == onlyConfig) &&
              (onlySchedule == null ||
                  onlySchedule.isEmpty ||
                  entry.value.refreshSchedule?.trim() == onlySchedule))
            entry,
      ];
      if (targetEntries.isEmpty) {
        stderr.writeln(
          'No configs in configs/ matched schedule "${onlySchedule ?? ''}"; nothing to refresh.',
        );
        return;
      }

      for (final entry in targetEntries) {
        final String configName = entry.key;
        final TriageConfig config = entry.value;
        final subHtmlFile = File(
          '${siteDir.path}${Platform.pathSeparator}$configName${Platform.pathSeparator}$baseName',
        );
        final subLinks = <({String name, String dirPrefix})>[
          for (final String name in allConfigNames)
            (name: name, dirPrefix: name == configName ? '' : '../$name/'),
        ];
        final isPrimary = configName == primaryName;
        final rootLinks = <({String name, String dirPrefix})>[
          for (final String name in allConfigNames) (name: name, dirPrefix: '$name/'),
        ];
        stderr.writeln('=== Generating triage pages for config "$configName" ===');
        await _report(
          client,
          config.repos,
          limit: limit,
          htmlFile: subHtmlFile,
          mirrorRootHtmlFile: isPrimary ? rootHtmlFile : null,
          open: isPrimary && results.flag('open'),
          showHidden: showHidden,
          hiddenLabels: config.hiddenLabels,
          showAllLabels: config.showAllLabels,
          requiredApprovals: config.requiredApprovals,
          includeIssues: includeIssues,
          workflowRepo: envWorkflowRepo ?? config.workflowRepo,
          usesConfiguredRepos: true,
          config: config,
          activeConfigName: configName,
          configLinks: subLinks,
          mirrorRootConfigLinks: rootLinks,
          live: replayPath == null,
          refresh: refresh,
        );
      }
    }
  } on GitHubException catch (e) {
    if (e.statusCode != 401 || token == null) {
      rethrow;
    }
    throw GitHubException(
      '$e\nGitHub rejected the token from ${token.source}. It may have expired or been revoked.',
      statusCode: e.statusCode,
    );
  } finally {
    client.close();
    if (recordPath != null) {
      client.writeRecording(File(recordPath));
      stderr.writeln('Saved ${client.recordedCount} responses to $recordPath.');
    }
    if (replayPath == null) {
      final remaining = client.rateLimitRemaining == null
          ? ''
          : '; ${client.rateLimitRemaining} remaining';
      stderr.writeln(
        'Made ${client.requestCount} GitHub requests in '
        '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s$remaining.',
      );
    }
  }
}

int? _positiveInt(ArgResults results, String name) {
  final String? value = results.option(name);
  if (value == null) {
    return null;
  }
  final int? number = int.tryParse(value);
  if (number == null || number <= 0) {
    throw _UsageException('--$name must be a positive integer.');
  }
  return number;
}

void _warn(String message) => stderr.writeln('Warning: $message');

Future<void> _explainPR(
  GitHubClient client,
  String repo,
  int number, {
  required int requiredApprovals,
  required TriageConfig config,
}) async {
  stderr.writeln('Fetching PR #$number in $repo...');
  final Map<String, dynamic> listing = await fetchSinglePR(client, repo, number);
  final Set<String> roster = await fetchRoster(
    client,
    repo,
    <Map<String, dynamic>>[listing],
    onWarning: _warn,
    config: config,
  );
  final PRInfo pr = await fetchPRDetails(
    client,
    repo,
    listing,
    roster,
    alwaysFetchDetails: true,
    config: config,
  );
  printExplanation(
    analyzePR(pr, now: client.now, requiredApprovals: requiredApprovals, config: config),
  );
}

Future<void> _report(
  GitHubClient client,
  List<String> repos, {
  required int? limit,
  required File? htmlFile,
  File? mirrorRootHtmlFile,
  required bool open,
  required bool showHidden,
  required Set<String> hiddenLabels,
  required bool showAllLabels,
  required int requiredApprovals,
  required bool includeIssues,
  required String workflowRepo,
  required bool usesConfiguredRepos,
  required TriageConfig config,
  String? activeConfigName,
  List<({String name, String dirPrefix})> configLinks = const <({String name, String dirPrefix})>[],
  List<({String name, String dirPrefix})> mirrorRootConfigLinks =
      const <({String name, String dirPrefix})>[],
  required bool live,
  required bool refresh,
}) async {
  final DateTime now = client.now;
  final bool interactive = stderr.hasTerminal;
  final listingsByRepo = <String, List<Map<String, dynamic>>>{};
  final roster = <String>{};
  final suggestedReviewers = <String, String>{};

  for (final repo in repos) {
    try {
      stderr.writeln('Fetching open PRs in $repo...');
      final List<Map<String, dynamic>> rawListing = await fetchOpenPRs(client, repo, limit: limit);
      final List<Map<String, dynamic>> listing = usesConfiguredRepos && config.prLabels.isNotEmpty
          ? filterPRListingsByLabels(rawListing, config.prLabels)
          : rawListing;
      stderr.writeln(
        limit == null
            ? (listing.length == rawListing.length
                  ? 'Found ${listing.length} open PRs in $repo.'
                  : 'Found ${listing.length} matching open PRs (of ${rawListing.length}) in $repo.')
            : 'Analyzing the ${listing.length} newest open PRs in $repo (--limit).',
      );
      listingsByRepo[repo] = listing;
      roster.addAll(
        await fetchRoster(
          client,
          repo,
          listing,
          suggestedReviewers: suggestedReviewers,
          onWarning: _warn,
          config: config,
        ),
      );
    } on GitHubException catch (e) {
      if (!live && repo != repos.first) {
        _warn('Recording does not include $repo ($e); skipping.');
      } else {
        rethrow;
      }
    }
  }

  final allPRs = <PRInfo>[];
  for (final MapEntry<String, List<Map<String, dynamic>>> entry in listingsByRepo.entries) {
    final String repo = entry.key;
    final List<Map<String, dynamic>> listing = entry.value;
    // Replays shouldn't change the cache. Recordings skip it so that they
    // include every response.
    final DetailCache? cache = !live
        ? null
        : DetailCache.load(
            detailCacheFileFor(repo),
            repo: repo,
            now: now,
            refresh: refresh,
            onWarning: _warn,
          );
    final List<PRInfo> prs = await fetchAllPRDetails(
      client,
      repo,
      listing,
      roster,
      cache: cache,
      config: config,
      onProgress: (int done, int total, PRInfo pr) {
        if (interactive) {
          stderr.write('\r[$done/$total] $repo#${pr.number}   ');
          if (done == total) {
            stderr.writeln();
          }
        } else if (done % 25 == 0 || done == total) {
          stderr.writeln('[$done/$total]');
        }
      },
    );
    if (cache != null) {
      _saveCache(cache, prs.map((PRInfo pr) => pr.number), label: '$repo PRs');
    }
    allPRs.addAll(prs);
  }

  final analyses = <PRAnalysis>[
    for (final PRInfo pr in allPRs)
      analyzePR(pr, now: now, requiredApprovals: requiredApprovals, config: config),
  ]..sort(comparePRs);

  final String issuesRepo = defaultIssuesRepoFor(repos.first, config: config);
  final bool useConfigIssueLabels = usesConfiguredRepos && issuesRepo == config.issuesRepo;
  final String? effectiveTeamLabel = useConfigIssueLabels
      ? ((config.issueTeamLabel?.isEmpty ?? true) ? null : config.issueTeamLabel)
      : null;
  final String? effectiveFyiLabel = useConfigIssueLabels
      ? ((config.issueFyiLabel?.isEmpty ?? true) ? null : config.issueFyiLabel)
      : null;
  final String effectiveTriagedLabel = useConfigIssueLabels ? config.issueTriagedLabel : 'triaged';
  final DetailCache? issuesCache = !live || !includeIssues
      ? null
      : DetailCache.load(
          detailCacheFileFor('${issuesRepo}_issues'),
          repo: '$issuesRepo#issues',
          now: now,
          refresh: refresh,
          onWarning: _warn,
        );
  final issueAnalyses = <IssueAnalysis>[];
  if (includeIssues) {
    try {
      stderr.writeln('Fetching package issues in $issuesRepo...');
      final List<Map<String, dynamic>> issueListings = await fetchTriageIssues(
        client,
        issuesRepo,
        now: now,
        limit: limit,
        teamLabel: effectiveTeamLabel,
        fyiLabel: effectiveFyiLabel,
        triagedLabel: effectiveTriagedLabel,
        config: config,
      );
      stderr.writeln('Found ${issueListings.length} candidate package issues.');
      final List<IssueInfo> issues = await fetchAllIssueDetails(
        client,
        issuesRepo,
        issueListings,
        roster,
        cache: issuesCache,
        now: now,
        teamLabel: effectiveTeamLabel,
        triagedLabel: effectiveTriagedLabel,
        config: config,
        onProgress: (int done, int total, IssueInfo issue) {
          if (interactive) {
            stderr.write('\r[$done/$total] issue #${issue.number}   ');
            if (done == total) {
              stderr.writeln();
            }
          } else if (done % 25 == 0 || done == total) {
            stderr.writeln('[$done/$total]');
          }
        },
      );
      if (issuesCache != null) {
        _saveCache(issuesCache, issues.map((IssueInfo i) => i.number), label: 'issues');
      }
      for (final issue in issues) {
        final IssueAnalysis? analysis = analyzeIssue(
          issue,
          now: now,
          teamLabel: effectiveTeamLabel ?? '',
          fyiLabel: effectiveFyiLabel ?? '',
          triagedLabel: effectiveTriagedLabel,
          config: config,
        );
        if (analysis != null) {
          issueAnalyses.add(analysis);
        }
      }
      issueAnalyses.sort(compareIssues);
    } on GitHubException catch (e) {
      if (!live) {
        _warn('Recording does not include issue queries ($e); skipping issues.');
      } else {
        rethrow;
      }
    }
  }

  final String repoLabel = repos.join(' + ');
  if (htmlFile == null) {
    printTextReport(
      repoLabel,
      analyses,
      issues: issueAnalyses,
      issuesRepo: issuesRepo,
      hiddenLabels: hiddenLabels,
      showHidden: showHidden,
      config: config,
    );
  } else {
    void writeTargetHtml(File targetFile, List<({String name, String dirPrefix})> links) {
      final File stateFile = stateFileFor(targetFile);
      final Map<int, PreviousPlacement>? previous =
          readReportState(stateFile, repo: repoLabel) ??
          readReportState(stateFile, repo: repos.first);
      writeHtmlReport(
        repo: repoLabel,
        prs: analyses,
        issues: issueAnalyses,
        issuesRepo: issuesRepo,
        communityFile: targetFile,
        generatedAt: now,
        previous: previous,
        suggestedReviewers: suggestedReviewers,
        hiddenLabels: hiddenLabels,
        showHiddenByDefault: showHidden,
        showAllLabels: showAllLabels,
        workflowRepo: workflowRepo,
        teamLabel: effectiveTeamLabel,
        fyiLabel: effectiveFyiLabel,
        config: config,
        activeConfigName: activeConfigName,
        configLinks: links,
        note: <String>[
          if (limit != null) 'Partial report: only the $limit newest open PRs were analyzed.',
          if (!live) 'Replayed from a recording made ${formatAsMinute(now)}.',
        ].join(' ').nullIfEmpty,
      );
      // Partial and replayed runs would make the next report's badges wrong.
      if (limit == null && live) {
        writeReportState(
          stateFile,
          analyses,
          repo: repoLabel,
          generatedAt: now,
          previous: previous,
        );
      }
      stderr.writeln(
        'Wrote ${targetFile.path}, ${teamPageFileFor(targetFile).path}, '
        'and ${issuesPageFileFor(targetFile).path}.',
      );
    }

    writeTargetHtml(htmlFile, configLinks);
    if (mirrorRootHtmlFile != null) {
      writeTargetHtml(mirrorRootHtmlFile, mirrorRootConfigLinks);
    }
    if (open) {
      await _openInBrowser(mirrorRootHtmlFile ?? htmlFile);
    }
  }
  _printSummary(
    analyses,
    issueAnalyses,
    roster: roster,
    hiddenLabels: hiddenLabels,
    showHidden: showHidden,
    config: config,
  );
}

/// Saves [cache] after a run that found [numbers] open, which keeps their
/// entries for another [DetailCache.maxUnseen] whether or not they changed.
void _saveCache(DetailCache cache, Iterable<int> numbers, {required String label}) {
  cache.markSeen(numbers);
  try {
    cache.save();
  } on FileSystemException catch (e) {
    _warn('Could not save the cache to ${cache.file.path}: ${e.message}');
  }
  if (cache.reusedCount > 0) {
    stderr.writeln('Reused saved comments for ${cache.reusedCount} unchanged $label.');
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

void _printSummary(
  List<PRAnalysis> analyses,
  List<IssueAnalysis> issueAnalyses, {
  required Set<String> roster,
  required Set<String> hiddenLabels,
  required bool showHidden,
  required TriageConfig config,
}) {
  for (final ReportPage page in ReportPage.values) {
    final List<PRAnalysis> onPage = analyses.where((PRAnalysis a) => a.page == page).toList();
    final counts = <String>[
      for (final Section section in sectionsFor(page))
        if (onPage.where((PRAnalysis a) => a.section == section).length case final int count
            when count > 0)
          '${sectionTitle(section, page).toLowerCase()} $count',
    ];
    final int followUps = onPage.where((PRAnalysis a) => a.isFollowUp).length;
    final followUpNote = followUps > 0 ? ' [$followUps follow-up]' : '';
    stderr.writeln('${pageTitle(page)}: ${onPage.length} (${counts.join(', ')})$followUpNote');
  }
  if (issueAnalyses.isNotEmpty) {
    final issueCounts = <String>[
      for (final IssueSection section in IssueSection.values)
        if (issueAnalyses.where((IssueAnalysis a) => a.section == section).length
            case final int count when count > 0)
          '${issueSectionTitle(section, config: config).toLowerCase()} $count',
    ];
    stderr.writeln('Package Issues: ${issueAnalyses.length} (${issueCounts.join(', ')})');
  }
  final int fromRoster = analyses.where((PRAnalysis a) => a.pr.authorTypeFromRoster).length;
  if (fromRoster > 0) {
    stderr.writeln(
      '$fromRoster team PRs were identified using ${config.rosterFile}, CODEOWNERS, or review '
      'requests (${roster.length} known team members), since GitHub did not report their authors '
      'as members.',
    );
  }
  final int hidden = analyses.where((PRAnalysis a) => hasHiddenLabel(a.pr, hiddenLabels)).length;
  if (hidden > 0 && !showHidden) {
    stderr.writeln(
      '$hidden of these are labeled ${hiddenLabels.join(' or ')}, so they are hidden '
      'by default.',
    );
  }
  final int failed = analyses.where((PRAnalysis a) => a.section == Section.loadError).length;
  if (failed > 0) {
    stderr.writeln('Warning: $failed PRs failed to load; rerun to retry.');
  }
}

Future<void> _openInBrowser(File file) async {
  final String path = file.absolute.path;
  final (String command, List<String> args) = Platform.isMacOS
      ? ('open', <String>[path])
      : Platform.isWindows
      ? ('cmd', <String>['/c', 'start', '', path])
      : ('xdg-open', <String>[path]);
  try {
    final ProcessResult result = await Process.run(command, args);
    if (result.exitCode != 0) {
      _warn('Could not open $path: ${result.stderr}');
    }
  } on ProcessException catch (e) {
    _warn('Could not open $path: ${e.message}');
  }
}
