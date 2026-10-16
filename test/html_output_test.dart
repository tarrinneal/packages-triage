// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:pr_inspector/html_output.dart';
import 'package:pr_inspector/report_state.dart';
import 'package:pr_inspector/text_output.dart';
import 'package:pr_inspector/triage.dart';
import 'package:pr_inspector/types.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 10, 1, 12);

PRAnalysis _analysis(
  int number, {
  ReportPage page = ReportPage.community,
  Section section = Section.waitingOnTeam,
  int waitingDays = 10,
  List<String> labels = const <String>[],
  String title = 'A PR',
  List<String> errors = const <String>[],
}) {
  final pr = PRInfo(
    number: number,
    author: 'author$number',
    title: title,
    url: 'https://github.com/o/r/pull/$number',
    creationDate: _now.subtract(const Duration(days: 40)),
    updatedDate: _now,
    authorType: page == ReportPage.team ? ContributorType.member : ContributorType.community,
    isDraft: section == Section.drafts,
    labels: labels,
  )..hasDetails = true;
  pr.fetchErrors.addAll(errors);
  pr.reviewers['reviewer'] = ReviewerStatus()..requested = true;
  return PRAnalysis(
    pr: pr,
    page: page,
    section: section,
    waitingSince: _now.subtract(Duration(days: waitingDays)),
    waitingDays: waitingDays,
    urgency: urgencyForDays(waitingDays),
    nextStep: 'Ping @reviewer',
    reasons: const <String>['Because', 'Reasons'],
  );
}

void main() {
  late Directory tempDir;
  late File communityFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('html_output_test');
    communityFile = File('${tempDir.path}/triage.html');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  void write(
    List<PRAnalysis> prs, {
    Map<int, PreviousPlacement>? previous,
    bool showHiddenByDefault = false,
    String? note,
  }) {
    writeHtmlReport(
      repo: 'o/r',
      prs: prs..sort(comparePRs),
      communityFile: communityFile,
      generatedAt: _now,
      previous: previous,
      showHiddenByDefault: showHiddenByDefault,
      note: note,
    );
  }

  String rowFor(String html, int number) =>
      RegExp('<tr[^>]*data-number="$number"[^>]*>[\\s\\S]*?</tr>').firstMatch(html)![0]!;

  test('file helpers', () {
    expect(teamPageFileFor(File('/tmp/triage.html')).path, '/tmp/triage_team.html');
    expect(stateFileFor(File('/tmp/triage.html')).path, '/tmp/triage.state.json');
    expect(teamPageFileFor(File('/tmp/a.b/report')).path, '/tmp/a.b/report_team.html');
  });

  test('writes linked community and team pages', () {
    write(<PRAnalysis>[
      _analysis(1),
      _analysis(2, page: ReportPage.team),
      _analysis(3, section: Section.needsReviewer),
    ]);
    final String community = communityFile.readAsStringSync();
    final String team = teamPageFileFor(communityFile).readAsStringSync();

    expect(community, contains('<meta charset="utf-8">'));
    expect(community, contains('href="triage_team.html">Team PRs (1)</a>'));
    expect(community, contains('<strong>Community PRs (2)</strong>'));
    expect(community, contains('data-number="1"'));
    expect(community, contains('data-number="3"'));
    expect(community, isNot(contains('data-number="2"')));
    expect(community, contains('id="needsReviewer"'));
    expect(community, contains('Waiting on team'));

    expect(team, contains('href="triage.html">Community PRs (2)</a>'));
    expect(team, contains('data-number="2"'));
    expect(team, contains('Waiting on reviewer'));
    expect(team, isNot(contains('id="needsReviewer"')));
    expect(team, isNot(contains('id="bots"')));
  });

  test('is well formed', () {
    write(<PRAnalysis>[_analysis(1), _analysis(2, section: Section.drafts)]);
    final String html = communityFile.readAsStringSync();
    expect('<tbody>'.allMatches(html).length, '</tbody>'.allMatches(html).length);
    expect('<tr'.allMatches(html).length, '</tr>'.allMatches(html).length);
    expect(html, isNot(contains('class="null"')));
    expect(html, contains('<details id="drafts" data-section="drafts">'));
    expect(html, contains('<details id="waitingOnTeam" data-section="waitingOnTeam" open>'));
  });

  test('shows the row details', () {
    write(<PRAnalysis>[
      _analysis(1, labels: <String>['p: camera', 'CICD'], title: 'Fix <video> & "audio"'),
    ]);
    final String row = rowFor(communityFile.readAsStringSync(), 1);
    expect(row, contains('Fix &lt;video&gt; &amp; &quot;audio&quot;'));
    expect(row, contains('<span class="label">p: camera</span>'));
    expect(row, isNot(contains('>CICD<')));
    expect(row, contains('Ping @reviewer'));
    expect(row, contains('class="waiting urgency-due" title="Because&#10;Reasons">10d on team'));
    expect(row, contains('🟠 reviewer'));
    expect(row, contains('data-waiting="10"'));
  });

  test('hides triage-design PRs by default, with a button to show them', () {
    write(<PRAnalysis>[
      _analysis(1, labels: <String>['p: material_ui', 'triage-design']),
      _analysis(2),
    ]);
    final String html = communityFile.readAsStringSync();
    expect(html, contains('data-hidden-labels="triage-design"'));
    expect(html, contains('data-label="triage-design PRs (1)"'));
    expect(html, contains('>Show triage-design PRs (1)</button>'));
    expect(rowFor(html, 1), contains(' hidden>'));
    expect(rowFor(html, 1), contains('<span class="label hidden-label">triage-design</span>'));
    expect(rowFor(html, 2), isNot(contains(' hidden>')));
    // The section count only includes visible rows.
    expect(html, contains('Waiting on team (<span data-count="waitingOnTeam">1</span>)'));
  });

  test('can show triage-design PRs by default', () {
    write(<PRAnalysis>[
      _analysis(1, labels: <String>['triage-design']),
    ], showHiddenByDefault: true);
    final String html = communityFile.readAsStringSync();
    expect(html, contains('data-show-hidden-default="true"'));
    expect(html, contains('>Hide triage-design PRs (1)</button>'));
    expect(rowFor(html, 1), isNot(contains(' hidden>')));
  });

  test('marks new and moved PRs', () {
    write(
      <PRAnalysis>[_analysis(1), _analysis(2), _analysis(3)],
      previous: <int, PreviousPlacement>{
        1: (page: ReportPage.community, section: Section.waitingOnAuthor),
        3: (page: ReportPage.community, section: Section.waitingOnTeam),
      },
    );
    final String html = communityFile.readAsStringSync();
    expect(rowFor(html, 1), contains('class="badge moved"'));
    expect(rowFor(html, 2), contains('class="badge new"'));
    expect(rowFor(html, 3), isNot(contains('class="badge')));
  });

  test('has no badges without a previous report', () {
    write(<PRAnalysis>[_analysis(1)]);
    expect(rowFor(communityFile.readAsStringSync(), 1), isNot(contains('class="badge')));
  });

  test('warns about PRs that failed to load', () {
    write(<PRAnalysis>[
      _analysis(1, section: Section.loadError, errors: <String>['Failed to fetch reviews']),
    ], note: 'Partial report.');
    final String html = communityFile.readAsStringSync();
    expect(html, contains('class="banner"'));
    expect(html, contains('id="loadError"'));
    expect(html, contains('<p class="note">Partial report.</p>'));
    final String team = teamPageFileFor(communityFile).readAsStringSync();
    expect(team, isNot(contains('class="banner"')));
    expect(team, isNot(contains('id="loadError"')));
  });

  group('report state', () {
    test('round-trips placements', () {
      final File file = stateFileFor(communityFile);
      writeReportState(
        file,
        <PRAnalysis>[_analysis(1), _analysis(2, page: ReportPage.team, section: Section.drafts)],
        repo: 'o/r',
        generatedAt: _now,
      );
      expect(readReportState(file, repo: 'o/r'), <int, PreviousPlacement>{
        1: (page: ReportPage.community, section: Section.waitingOnTeam),
        2: (page: ReportPage.team, section: Section.drafts),
      });
      expect(readReportState(file, repo: 'other/repo'), isNull);
    });

    test('keeps the previous placement of PRs that failed to load', () {
      final File file = stateFileFor(communityFile);
      writeReportState(
        file,
        <PRAnalysis>[
          _analysis(1, section: Section.loadError, errors: <String>['oops']),
          _analysis(2, section: Section.loadError, errors: <String>['oops']),
        ],
        repo: 'o/r',
        generatedAt: _now,
        previous: <int, PreviousPlacement>{
          1: (page: ReportPage.community, section: Section.waitingOnAuthor),
        },
      );
      expect(readReportState(file, repo: 'o/r'), <int, PreviousPlacement>{
        1: (page: ReportPage.community, section: Section.waitingOnAuthor),
        2: (page: ReportPage.community, section: Section.loadError),
      });
    });

    test('ignores missing or corrupt files', () {
      final File file = stateFileFor(communityFile);
      expect(readReportState(file, repo: 'o/r'), isNull);
      file.writeAsStringSync('not json');
      expect(readReportState(file, repo: 'o/r'), isNull);
    });

    test('a PR that failed to load last time is not marked as moved', () {
      expect(
        badgeFor(_analysis(1), <int, PreviousPlacement>{
          1: (page: ReportPage.community, section: Section.loadError),
        }),
        isNull,
      );
    });
  });

  group('text report', () {
    test('groups by page and section, leaving out hidden labels', () {
      final buffer = StringBuffer();
      printTextReport(
        'o/r',
        <PRAnalysis>[
          _analysis(1),
          _analysis(2, page: ReportPage.team),
          _analysis(3, labels: <String>['triage-design']),
        ]..sort(comparePRs),
        out: buffer,
      );
      final text = buffer.toString();
      expect(text, contains('o/r · Community PRs (1)'));
      expect(text, contains('Waiting on team (1)'));
      expect(text, contains('o/r · Team PRs (1)'));
      expect(text, contains('Waiting on reviewer (1)'));
      expect(text, contains('#1 A PR'));
      expect(text, isNot(contains('#3 A PR')));
      expect(text, contains('1 PR labeled triage-design not shown'));
    });

    test('can include hidden labels', () {
      final buffer = StringBuffer();
      printTextReport(
        'o/r',
        <PRAnalysis>[
          _analysis(3, labels: <String>['triage-design']),
        ],
        showHidden: true,
        out: buffer,
      );
      expect(buffer.toString(), contains('#3 A PR'));
      expect(buffer.toString(), isNot(contains('not shown')));
    });

    test('explains a single PR', () {
      final buffer = StringBuffer();
      printExplanation(_analysis(1), out: buffer);
      final text = buffer.toString();
      expect(text, contains('Placement:  Community PRs › Waiting on team'));
      expect(text, contains('Next step:  Ping @reviewer'));
      expect(text, contains('    - Because'));
    });
  });
}
