// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:pr_inspector/html_output.dart';
import 'package:pr_inspector/pr_inspector.dart';
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

  test(
    'hides triage-design PRs by default, with checkboxes to show non-design, design, or both',
    () {
      write(<PRAnalysis>[
        _analysis(1, labels: <String>['p: material_ui', 'triage-design']),
        _analysis(2),
      ]);
      final String html = communityFile.readAsStringSync();
      expect(html, contains('data-hidden-labels="triage-design"'));
      expect(
        html,
        contains(
          '<input id="show-non-design" type="checkbox" checked><span>triage-packages (1)</span>',
        ),
      );
      expect(
        html,
        contains('<input id="show-design" type="checkbox"><span>triage-design (1)</span>'),
      );
      expect(rowFor(html, 1), contains(' hidden>'));
      expect(rowFor(html, 1), contains('<span class="label hidden-label">triage-design</span>'));
      expect(rowFor(html, 2), isNot(contains(' hidden>')));
      // The section count only includes visible rows.
      expect(html, contains('Waiting on team (<span data-count="waitingOnTeam">1</span>)'));
    },
  );

  test('can show only triage-design PRs by default', () {
    write(<PRAnalysis>[
      _analysis(1, labels: <String>['triage-design']),
      _analysis(2),
    ], showHiddenByDefault: true);
    final String html = communityFile.readAsStringSync();
    expect(html, contains('data-show-hidden-default="true"'));
    expect(
      html,
      contains('<input id="show-non-design" type="checkbox"><span>triage-packages (1)</span>'),
    );
    expect(
      html,
      contains('<input id="show-design" type="checkbox" checked><span>triage-design (1)</span>'),
    );
    expect(rowFor(html, 1), isNot(contains(' hidden>')));
    expect(rowFor(html, 2), contains(' hidden>'));
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

  test('renders FOLLOW-UP badge and writes linked issues page', () {
    final PRAnalysis pr = _analysis(1);
    final followUpPr = PRAnalysis(
      pr: pr.pr,
      page: pr.page,
      section: pr.section,
      waitingSince: pr.waitingSince,
      waitingDays: pr.waitingDays,
      urgency: pr.urgency,
      nextStep: pr.nextStep,
      reasons: pr.reasons,
      isFollowUp: true,
    );
    final issue = IssueInfo(
      number: 42,
      author: 'reporter',
      title: 'Camera crash on iOS',
      url: 'https://github.com/flutter/flutter/issues/42',
      creationDate: _now.subtract(const Duration(days: 12)),
      updatedDate: _now,
      authorType: ContributorType.community,
      labels: const <String>['team-ecosystem', 'p: camera'],
    )..hasDetails = true;
    final issueAnalysis = IssueAnalysis(
      issue: issue,
      section: IssueSection.untriaged,
      waitingSince: issue.creationDate,
      waitingDays: 12,
      urgency: Urgency.due,
      nextStep: 'Assign priority and add triaged-ecosystem',
      reasons: const <String>['Missing triaged-ecosystem and priority label'],
      isFollowUp: true,
    );

    writeHtmlReport(
      repo: 'flutter/packages',
      prs: <PRAnalysis>[followUpPr],
      issues: <IssueAnalysis>[issueAnalysis],
      issuesRepo: 'flutter/flutter',
      communityFile: communityFile,
      generatedAt: _now,
    );

    final String community = communityFile.readAsStringSync();
    expect(community, contains('class="badge follow-up"'));
    expect(community, contains('Follow-up PRs (1)'));
    expect(community, contains('href="triage_issues.html">Issues (1)</a>'));

    final File issuesFile = issuesPageFileFor(communityFile);
    expect(issuesFile.existsSync(), isTrue);
    final String issuesHtml = issuesFile.readAsStringSync();
    expect(issuesHtml, contains('flutter/flutter · Package Issues'));
    expect(issuesHtml, contains('#42</a>'));
    expect(issuesHtml, contains('Camera crash on iOS'));
    expect(issuesHtml, contains('class="badge follow-up"'));
  });

  test('renders repository chip when report covers multiple repos', () {
    final pr1 = PRInfo(
      repo: 'flutter/packages',
      number: 101,
      author: 'alice',
      title: 'Packages PR',
      url: 'https://github.com/flutter/packages/pull/101',
      creationDate: _now.subtract(const Duration(days: 10)),
      updatedDate: _now,
      authorType: ContributorType.community,
      isDraft: false,
      labels: const <String>['p: camera'],
    )..hasDetails = true;
    final pr2 = PRInfo(
      repo: 'flutter/core-packages',
      number: 202,
      author: 'bob',
      title: 'Core Packages PR',
      url: 'https://github.com/flutter/core-packages/pull/202',
      creationDate: _now.subtract(const Duration(days: 10)),
      updatedDate: _now,
      authorType: ContributorType.community,
      isDraft: false,
      labels: const <String>['p: path'],
    )..hasDetails = true;

    writeHtmlReport(
      repo: 'flutter/packages + flutter/core-packages',
      prs: <PRAnalysis>[
        PRAnalysis(
          pr: pr1,
          page: ReportPage.community,
          section: Section.waitingOnTeam,
          waitingSince: pr1.creationDate,
          waitingDays: 10,
          urgency: Urgency.due,
          nextStep: 'Review',
          reasons: const <String>['Reason'],
        ),
        PRAnalysis(
          pr: pr2,
          page: ReportPage.community,
          section: Section.waitingOnTeam,
          waitingSince: pr2.creationDate,
          waitingDays: 10,
          urgency: Urgency.due,
          nextStep: 'Review',
          reasons: const <String>['Reason'],
        ),
      ],
      communityFile: communityFile,
      generatedAt: _now,
    );

    final String html = communityFile.readAsStringSync();
    expect(rowFor(html, 101), contains('<span class="label repo-label">packages</span>'));
    expect(rowFor(html, 202), contains('<span class="label repo-label">core-packages</span>'));
  });

  test('renders refresh report button with 5-minute cooldown metadata on all pages', () {
    write(<PRAnalysis>[_analysis(1)]);
    final String community = communityFile.readAsStringSync();
    final String team = teamPageFileFor(communityFile).readAsStringSync();
    final String issues = issuesPageFileFor(communityFile).readAsStringSync();

    for (final pageHtml in <String>[community, team, issues]) {
      expect(pageHtml, contains('id="refresh-report"'));
      expect(pageHtml, contains('>↻ Refresh report</button>'));
      expect(pageHtml, contains('data-generated-at="2026-10-01T12:00:00.000Z"'));
      expect(pageHtml, contains('data-workflow-repo="tarrinneal/packages-triage"'));
      expect(pageHtml, contains('const cooldownMs = 5 * 60 * 1000;'));
    }
  });

  test('hides waiting-for-response items by default with a checked filter checkbox', () {
    final issue = IssueInfo(
      number: 99,
      author: 'reporter',
      title: 'Waiting issue',
      url: 'https://github.com/flutter/flutter/issues/99',
      creationDate: _now.subtract(const Duration(days: 10)),
      updatedDate: _now,
      authorType: ContributorType.community,
      labels: const <String>['team-ecosystem', 'waiting-for-response'],
    )..hasDetails = true;
    final issueAnalysis = IssueAnalysis(
      issue: issue,
      section: IssueSection.untriaged,
      waitingSince: issue.creationDate,
      waitingDays: 10,
      urgency: Urgency.due,
      nextStep: 'Triage',
      reasons: const <String>['Untriaged'],
    );

    writeHtmlReport(
      repo: 'o/r',
      prs: <PRAnalysis>[
        _analysis(1, labels: <String>['waiting-for-response']),
        _analysis(2),
      ],
      issues: <IssueAnalysis>[issueAnalysis],
      communityFile: communityFile,
      generatedAt: _now,
    );

    final String community = communityFile.readAsStringSync();
    expect(
      community,
      contains(
        '<input id="hide-waiting-response" type="checkbox" checked><span>Hide waiting-for-response (1)</span>',
      ),
    );
    expect(rowFor(community, 1), contains('data-waiting-response="true"'));
    expect(rowFor(community, 1), contains(' hidden>'));
    expect(rowFor(community, 2), isNot(contains(' hidden>')));
    expect(community, contains('Waiting on team (<span data-count="waitingOnTeam">1</span>)'));

    final String issuesHtml = issuesPageFileFor(communityFile).readAsStringSync();
    expect(
      issuesHtml,
      contains(
        '<input id="hide-waiting-response" type="checkbox" checked><span>Hide waiting-for-response (1)</span>',
      ),
    );
    expect(rowFor(issuesHtml, 99), contains('data-waiting-response="true"'));
    expect(rowFor(issuesHtml, 99), contains(' hidden>'));
    expect(
      issuesHtml,
      contains('Untriaged (team-ecosystem) (<span data-count="untriaged">0</span>)'),
    );
  });

  test('renders Open first 10 and Open all buttons on each section', () {
    write(<PRAnalysis>[_analysis(1)]);
    final String community = communityFile.readAsStringSync();
    final String issuesHtml = issuesPageFileFor(communityFile).readAsStringSync();

    // waitingOnTeam has 1 visible PR -> buttons enabled
    expect(
      community,
      contains(
        <String>[
          '<h2>Waiting on team (<span data-count="waitingOnTeam">1</span>)</h2>',
          '<span class="section-actions">',
          '<button type="button" class="section-btn open-batch">Open first 10</button>',
          '<button type="button" class="section-btn open-all">Open all</button>',
          '</span>',
        ].join(),
      ),
    );
    // needsReviewer has 0 visible PRs -> buttons disabled
    expect(
      community,
      contains(
        <String>[
          '<h2>Needs reviewer (<span data-count="needsReviewer">0</span>)</h2>',
          '<span class="section-actions">',
          '<button type="button" class="section-btn open-batch" disabled>Open first 10</button>',
          '<button type="button" class="section-btn open-all" disabled>Open all</button>',
          '</span>',
        ].join(),
      ),
    );
    expect(community, contains("offset > 0 ? 'Open next 10' : 'Open first 10'"));
    expect(issuesHtml, contains('class="section-btn open-batch"'));
    expect(issuesHtml, contains('class="section-btn open-all"'));
  });

  test('renders suggested reviewers tooltip on package labels', () {
    final Map<String, String> suggestedReviewers = parseSuggestedReviewers('''
`camera`:
  - **Cross-platform**: @bparrishMines
  - **Android**: @camsim99
  - **iOS**: @hellohuanlin, @louisehsu

`go_router / go_router_builder`:
  - @chunhtai
''');

    final issue = IssueInfo(
      number: 55,
      author: 'reporter',
      title: 'Camera issue',
      url: 'https://github.com/flutter/flutter/issues/55',
      creationDate: _now.subtract(const Duration(days: 10)),
      updatedDate: _now,
      authorType: ContributorType.community,
      labels: const <String>['team-ecosystem', 'p: camera'],
    )..hasDetails = true;
    final issueAnalysis = IssueAnalysis(
      issue: issue,
      section: IssueSection.untriaged,
      waitingSince: issue.creationDate,
      waitingDays: 10,
      urgency: Urgency.due,
      nextStep: 'Triage',
      reasons: const <String>['Untriaged'],
    );

    writeHtmlReport(
      repo: 'o/r',
      prs: <PRAnalysis>[
        _analysis(1, labels: const <String>['p: camera', 'p: go_router_builder', 'p: unknown']),
      ],
      issues: <IssueAnalysis>[issueAnalysis],
      communityFile: communityFile,
      generatedAt: _now,
      suggestedReviewers: suggestedReviewers,
    );

    final String community = communityFile.readAsStringSync();
    expect(
      rowFor(community, 1),
      contains(
        <String>[
          '<span class="label" title="Suggested reviewers (camera):&#10;',
          '• Cross-platform: @bparrishMines&#10;',
          '• Android: @camsim99&#10;',
          '• iOS: @hellohuanlin, @louisehsu">p: camera</span>',
        ].join(),
      ),
    );
    expect(
      rowFor(community, 1),
      contains(
        <String>[
          '<span class="label" title="Suggested reviewers (go_router / go_router_builder):&#10;',
          '• @chunhtai">p: go_router_builder</span>',
        ].join(),
      ),
    );
    expect(rowFor(community, 1), contains('<span class="label">p: unknown</span>'));

    final String issuesHtml = issuesPageFileFor(communityFile).readAsStringSync();
    expect(
      rowFor(issuesHtml, 55),
      contains(
        <String>[
          '<span class="label" title="Suggested reviewers (camera):&#10;',
          '• Cross-platform: @bparrishMines&#10;',
          '• Android: @camsim99&#10;',
          '• iOS: @hellohuanlin, @louisehsu">p: camera</span>',
        ].join(),
      ),
    );
  });

  test('supports showAllLabels, custom workflowRepo, and generic issue sections', () {
    writeHtmlReport(
      repo: 'acme/widgets',
      prs: <PRAnalysis>[
        _analysis(1, labels: const <String>['enhancement', 'cla: yes']),
      ],
      communityFile: communityFile,
      generatedAt: _now,
      hiddenLabels: const <String>{},
      showAllLabels: true,
      workflowRepo: 'acme/triage',
      teamLabel: null,
      fyiLabel: null,
    );
    final String community = communityFile.readAsStringSync();
    expect(community, contains('data-workflow-repo="acme/triage"'));
    expect(community, isNot(contains('id="show-non-design"')));
    expect(rowFor(community, 1), contains('<span class="label">enhancement</span>'));
    expect(rowFor(community, 1), isNot(contains('<span class="label">cla: yes</span>')));

    final String issuesHtml = issuesPageFileFor(communityFile).readAsStringSync();
    expect(issuesHtml, contains('<h2>Untriaged (<span data-count="untriaged">0</span>)</h2>'));
    expect(issuesHtml, isNot(contains('id="fyiEcosystem"')));
  });

  test('renders triage companion button, dock, and Document Picture-in-Picture support', () {
    write(<PRAnalysis>[_analysis(1)]);
    final String community = communityFile.readAsStringSync();
    final String team = teamPageFileFor(communityFile).readAsStringSync();
    final String issues = issuesPageFileFor(communityFile).readAsStringSync();

    for (final pageHtml in <String>[community, team, issues]) {
      expect(pageHtml, contains('id="open-companion"'));
      expect(pageHtml, contains('>🪟 Triage companion</button>'));
      expect(
        pageHtml,
        contains(
          '<aside id="triage-companion-dock" class="companion-dock" hidden aria-label="Triage companion"></aside>',
        ),
      );
      expect(pageHtml, contains('window.documentPictureInPicture.requestWindow'));
      expect(pageHtml, contains('Suggested Reviewers (from SUGGESTED_REVIEWERS.md)'));
      expect(pageHtml, contains('Auto-open GitHub'));
    }
  });
}
