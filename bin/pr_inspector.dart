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

const String _defaultRepo = 'flutter/packages';

/// Thrown for invalid command-line usage.
class _UsageException implements Exception {
  _UsageException(this.message);

  final String message;
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('pr', abbr: 'p', help: 'Explain how a single PR is triaged, and why.')
    ..addOption(
      'html',
      help:
          'Write the report as HTML: community PRs to <file>, and team PRs to '
          '<file name>_team.html next to it.',
    )
    ..addFlag('open', negatable: false, help: 'Open the HTML report when it is done.')
    ..addFlag(
      'show-hidden',
      negatable: false,
      help:
          'Show PRs labeled ${defaultHiddenLabels.join(', ')} by default. '
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
  final usage =
      '''
Usage: dart run bin/pr_inspector.dart [<owner>/<repo>] [options]

Sorts the open PRs in a repository ($_defaultRepo by default) by who needs to act next
and how long they have been waiting.

Reads a GitHub token from the $tokenVariable environment variable if it is set, and
otherwise from a "$tokenVariable=<token>" line in ${envFile.path}.

Saves each PR's comments and reviews so that later runs only fetch PRs that have
changed, and removes them once a PR hasn't been seen open for ${DetailCache.maxUnseen.inDays} days. They are
saved in ${cacheDirectory().path}.

${parser.usage}''';

  try {
    await _run(parser.parse(arguments), usage, envFile);
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

Future<void> _run(ArgResults results, String usage, File envFile) async {
  if (results.flag('help')) {
    stdout.writeln(usage);
    return;
  }
  if (results.rest.length > 1) {
    throw _UsageException('Provide at most one repository (e.g., owner/repo).');
  }
  final String repo = results.rest.firstOrNull ?? _defaultRepo;
  if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
    throw _UsageException('"$repo" is not a repository in owner/repo form.');
  }
  final int? prNumber = _positiveInt(results, 'pr');
  final int? limit = _positiveInt(results, 'limit');
  final String? htmlPath = results.option('html');
  final String? recordPath = results.option('record');
  final String? replayPath = results.option('replay');
  final bool showHidden = results.flag('show-hidden');
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
      ? findToken(environment: Platform.environment, envFile: envFile)
      : null;
  if (replayPath == null && token == null) {
    if (prNumber == null && limit == null) {
      throw _UsageException(
        'No GitHub token found. Add a "$tokenVariable=<token>" line to ${envFile.path}, or set '
        'the $tokenVariable environment variable. Without a token, GitHub allows 60 requests '
        'per hour, which is not enough for a full report; use --pr or --limit for a small '
        'anonymous run.',
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
    if (prNumber != null) {
      await _explainPR(client, repo, prNumber);
    } else {
      await _report(
        client,
        repo,
        limit: limit,
        htmlFile: htmlPath == null ? null : File(htmlPath),
        open: results.flag('open'),
        showHidden: showHidden,
        live: replayPath == null,
        // Replays shouldn't change the cache. Recordings skip it so that they
        // include every response.
        cache: replayPath != null
            ? null
            : DetailCache.load(
                detailCacheFileFor(repo),
                repo: repo,
                now: client.now,
                refresh: results.flag('refresh') || recordPath != null,
                onWarning: _warn,
              ),
      );
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

Future<void> _explainPR(GitHubClient client, String repo, int number) async {
  stderr.writeln('Fetching PR #$number in $repo...');
  final Map<String, dynamic> listing = await fetchSinglePR(client, repo, number);
  final Set<String> roster = await fetchRoster(client, repo, <Map<String, dynamic>>[
    listing,
  ], onWarning: _warn);
  final PRInfo pr = await fetchPRDetails(client, repo, listing, roster, alwaysFetchDetails: true);
  printExplanation(analyzePR(pr, now: client.now));
}

Future<void> _report(
  GitHubClient client,
  String repo, {
  required int? limit,
  required File? htmlFile,
  required bool open,
  required bool showHidden,
  required bool live,
  required DetailCache? cache,
}) async {
  stderr.writeln('Fetching open PRs in $repo...');
  final List<Map<String, dynamic>> listing = await fetchOpenPRs(client, repo, limit: limit);
  stderr.writeln(
    limit == null
        ? 'Found ${listing.length} open PRs.'
        : 'Analyzing the ${listing.length} newest open PRs (--limit).',
  );
  final Set<String> roster = await fetchRoster(client, repo, listing, onWarning: _warn);

  final bool interactive = stderr.hasTerminal;
  final List<PRInfo> prs = await fetchAllPRDetails(
    client,
    repo,
    listing,
    roster,
    cache: cache,
    onProgress: (int done, int total, PRInfo pr) {
      if (interactive) {
        stderr.write('\r[$done/$total] #${pr.number}   ');
        if (done == total) {
          stderr.writeln();
        }
      } else if (done % 25 == 0 || done == total) {
        stderr.writeln('[$done/$total]');
      }
    },
  );
  if (cache != null) {
    _saveCache(cache, prs);
  }

  final DateTime now = client.now;
  final analyses = <PRAnalysis>[for (final PRInfo pr in prs) analyzePR(pr, now: now)]
    ..sort(comparePRs);

  if (htmlFile == null) {
    printTextReport(repo, analyses, showHidden: showHidden);
  } else {
    final File stateFile = stateFileFor(htmlFile);
    final Map<int, PreviousPlacement>? previous = readReportState(stateFile, repo: repo);
    writeHtmlReport(
      repo: repo,
      prs: analyses,
      communityFile: htmlFile,
      generatedAt: now,
      previous: previous,
      showHiddenByDefault: showHidden,
      note: <String>[
        if (limit != null) 'Partial report: only the $limit newest open PRs were analyzed.',
        if (!live) 'Replayed from a recording made ${formatAsMinute(now)}.',
      ].join(' ').nullIfEmpty,
    );
    // Partial and replayed runs would make the next report's badges wrong.
    if (limit == null && live) {
      writeReportState(stateFile, analyses, repo: repo, generatedAt: now, previous: previous);
    }
    stderr.writeln('Wrote ${htmlFile.path} and ${teamPageFileFor(htmlFile).path}.');
    if (open) {
      await _openInBrowser(htmlFile);
    }
  }
  _printSummary(analyses, roster: roster, showHidden: showHidden);
}

/// Saves [cache] after a run that found [prs] open, which keeps their entries
/// for another [DetailCache.maxUnseen] whether or not they changed.
void _saveCache(DetailCache cache, List<PRInfo> prs) {
  cache.markSeen(prs.map((PRInfo pr) => pr.number));
  try {
    cache.save();
  } on FileSystemException catch (e) {
    _warn('Could not save the cache to ${cache.file.path}: ${e.message}');
  }
  if (cache.reusedCount > 0) {
    stderr.writeln('Reused saved comments and reviews for ${cache.reusedCount} unchanged PRs.');
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

void _printSummary(
  List<PRAnalysis> analyses, {
  required Set<String> roster,
  required bool showHidden,
}) {
  for (final ReportPage page in ReportPage.values) {
    final List<PRAnalysis> onPage = analyses.where((PRAnalysis a) => a.page == page).toList();
    final counts = <String>[
      for (final Section section in sectionsFor(page))
        if (onPage.where((PRAnalysis a) => a.section == section).length case final int count
            when count > 0)
          '${sectionTitle(section, page).toLowerCase()} $count',
    ];
    stderr.writeln('${pageTitle(page)}: ${onPage.length} (${counts.join(', ')})');
  }
  final int fromRoster = analyses.where((PRAnalysis a) => a.pr.authorTypeFromRoster).length;
  if (fromRoster > 0) {
    stderr.writeln(
      '$fromRoster team PRs were identified using SUGGESTED_REVIEWERS.md or review requests '
      '(${roster.length} known team members), since GitHub did not report their authors as members.',
    );
  }
  final int hidden = analyses
      .where((PRAnalysis a) => hasHiddenLabel(a.pr, defaultHiddenLabels))
      .length;
  if (hidden > 0 && !showHidden) {
    stderr.writeln(
      '$hidden of these are labeled ${defaultHiddenLabels.join(' or ')}, so they are hidden '
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
