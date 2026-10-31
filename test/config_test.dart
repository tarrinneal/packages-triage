// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:pr_inspector/html_output.dart';
import 'package:pr_inspector/pr_inspector.dart';
import 'package:pr_inspector/triage.dart';
import 'package:pr_inspector/types.dart';
import 'package:test/test.dart';

void main() {
  group('TriageConfig', () {
    test('configs/ecosystem.dart matches defaultConfig', () {
      final TriageConfig parsed = parseDartConfigFile(File('configs/ecosystem.dart'));

      expect(parsed.repos, defaultConfig.repos);
      expect(parsed.flutterTeam, defaultConfig.flutterTeam);
      expect(parsed.teamMembers, defaultConfig.teamMembers);
      expect(parsed.teamMembers, hasLength(30));
      expect(parsed.issuesRepo, defaultConfig.issuesRepo);
      expect(parsed.workflowRepo, defaultConfig.workflowRepo);
      expect(parsed.rosterFile, 'flutter/packages:SUGGESTED_REVIEWERS.md');
      expect(parsed.botAccounts, defaultConfig.botAccounts);
      expect(parsed.requiredApprovals, defaultConfig.requiredApprovals);
      expect(parsed.hiddenLabels, defaultConfig.hiddenLabels);
      expect(parsed.nonHiddenFilterLabel, defaultConfig.nonHiddenFilterLabel);
      expect(parsed.routingLabelPrefixes, defaultConfig.routingLabelPrefixes);
      expect(parsed.packageLabelPrefix, defaultConfig.packageLabelPrefix);
      expect(parsed.showAllLabels, defaultConfig.showAllLabels);
      expect(parsed.waitingForResponseLabels, defaultConfig.waitingForResponseLabels);
      expect(parsed.issueTeamLabel, 'team-ecosystem');
      expect(parsed.issueFyiLabel, 'fyi-ecosystem');
      expect(parsed.issueTriagedLabel, 'triaged-ecosystem');
      expect(parsed.priorityLabels, defaultConfig.priorityLabels);
      expect(parsed.highPriorityLabels, defaultConfig.highPriorityLabels);
    });

    test(
      'flutterTeam auto-derives team-*, fyi-*, and triaged-* labels and defaults rosterFile to null for other teams',
      () {
        const iosConfig = TriageConfig(repos: <String>['flutter/flutter'], flutterTeam: 'ios');

        expect(iosConfig.issueTeamLabel, 'team-ios');
        expect(iosConfig.issueFyiLabel, 'fyi-ios');
        expect(iosConfig.issueTriagedLabel, 'triaged-ios');
        expect(iosConfig.issuesRepo, 'flutter/flutter');
        expect(iosConfig.rosterFile, isNull);
      },
    );

    test(
      'explicit issue labels override flutterTeam defaults, and null flutterTeam disables team labels',
      () {
        const customLabels = TriageConfig(
          issueTeamLabel: 'area-tools',
          issueFyiLabel: null,
          issueTriagedLabel: 'triaged',
        );
        expect(customLabels.issueTeamLabel, 'area-tools');
        expect(customLabels.issueFyiLabel, isNull);
        expect(customLabels.issueTriagedLabel, 'triaged');

        const genericRepo = TriageConfig(repos: <String>['acme/widgets'], flutterTeam: null);
        expect(genericRepo.issueTeamLabel, isNull);
        expect(genericRepo.issueFyiLabel, isNull);
        expect(genericRepo.issueTriagedLabel, 'triaged');
      },
    );

    test('loadConfigsDirectory loads multiple .dart config files with ecosystem first', () {
      final Directory tempDir = Directory.systemTemp.createTempSync('triage_configs_dir_');
      try {
        File('${tempDir.path}/ios.dart').writeAsStringSync('''
import 'package:pr_inspector/types.dart';

const TriageConfig config = TriageConfig(
  repos: <String>['flutter/flutter'],
  flutterTeam: 'ios',
  hiddenLabels: <String>{},
);
''');
        File('${tempDir.path}/ecosystem.dart').writeAsStringSync('''
import 'package:pr_inspector/types.dart';

const TriageConfig config = TriageConfig(
  repos: <String>['flutter/packages', 'flutter/core-packages'],
  flutterTeam: 'ecosystem',
  rosterFile: 'flutter/packages:SUGGESTED_REVIEWERS.md',
);
''');

        final Map<String, TriageConfig> loaded = loadConfigsDirectory(tempDir);
        expect(loaded.keys.toList(), <String>['ecosystem', 'ios']);
        expect(loaded['ecosystem']!.issueTeamLabel, 'team-ecosystem');
        expect(loaded['ecosystem']!.rosterFile, 'flutter/packages:SUGGESTED_REVIEWERS.md');
        expect(loaded['ios']!.repos, <String>['flutter/flutter']);
        expect(loaded['ios']!.issueTeamLabel, 'team-ios');
        expect(loaded['ios']!.rosterFile, isNull);
        expect(loaded['ios']!.hiddenLabels, isEmpty);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('parseDartConfig rejects invalid parameters or malformed repos', () {
      expect(
        () => parseDartConfig('const c = TriageConfig(unknownParam: 1);'),
        throwsFormatException,
      );
      expect(
        () => parseDartConfig("const c = TriageConfig(repos: <String>['bad']);"),
        throwsFormatException,
      );
    });

    test('applies custom config and renders multi-config switcher in HTML output', () {
      const config = TriageConfig(
        repos: <String>['acme/widgets'],
        flutterTeam: 'widgets',
        issuesRepo: 'acme/issues',
        rosterFile: 'REVIEWERS.md',
        botAccounts: <String>{'acme-bot'},
        requiredApprovals: 1,
        hiddenLabels: <String>{'skip-triage'},
        nonHiddenFilterLabel: 'keep-visible',
        routingLabelPrefixes: <String>['mod:'],
        packageLabelPrefix: 'mod:',
        waitingForResponseLabels: <String>{'awaiting-author'},
        priorityLabels: <String>['sev-1', 'sev-2'],
        highPriorityLabels: <String>{'sev-1'},
      );

      expect(defaultIssuesRepoFor('acme/widgets', config: config), 'acme/issues');
      expect(isBot('acme-bot', config: config), isTrue);
      expect(isRoutingLabel('mod:core', config: config), isTrue);
      expect(isRoutingLabel('p: camera', config: config), isFalse);

      final now = DateTime.utc(2025, 2, 10);
      final pr = PRInfo(
        repo: 'acme/widgets',
        number: 1,
        author: 'alice',
        title: 'Add button',
        url: 'https://github.com/acme/widgets/pull/1',
        creationDate: DateTime.utc(2025, 2, 2),
        updatedDate: DateTime.utc(2025, 2, 5),
        authorType: ContributorType.community,
        isDraft: false,
        labels: <String>['skip-triage', 'mod:button'],
      )..hasDetails = true;
      pr.reviewers['bob'] = ReviewerStatus()
        ..decision = ReviewState.approved
        ..decisionDate = DateTime.utc(2025, 2, 5);

      expect(hasHiddenLabel(pr, config.hiddenLabels), isTrue);
      final PRAnalysis prAnalysis = analyzePR(
        pr,
        now: now,
        requiredApprovals: config.requiredApprovals,
        config: config,
      );
      expect(prAnalysis.section, isNot(Section.needsReviewer));

      final issue = IssueInfo(
        number: 42,
        author: 'user1',
        title: 'Crash in button',
        url: 'https://github.com/acme/issues/issues/42',
        creationDate: DateTime.utc(2025, 2, 2),
        updatedDate: DateTime.utc(2025, 2, 3),
        authorType: ContributorType.community,
        labels: <String>['team-widgets', 'triaged-widgets', 'sev-1', 'mod:button'],
      );
      final IssueAnalysis? issueAnalysis = analyzeIssue(issue, now: now, config: config);
      expect(issueAnalysis, isNotNull);
      expect(issueAnalysis!.section, IssueSection.highPriority);
      expect(issuePriority(issue, config: config), 'sev-1');

      final Directory tempDir = Directory.systemTemp.createTempSync('triage_config_test_');
      try {
        final htmlFile = File('${tempDir.path}/widgets/index.html');
        writeHtmlReport(
          repo: 'acme/widgets',
          prs: <PRAnalysis>[prAnalysis],
          issues: <IssueAnalysis>[issueAnalysis],
          issuesRepo: 'acme/issues',
          communityFile: htmlFile,
          generatedAt: now,
          suggestedReviewers: const <String, String>{'button': '@bob'},
          hiddenLabels: config.hiddenLabels,
          config: config,
          activeConfigName: 'widgets',
          configLinks: const <({String name, String dirPrefix})>[
            (name: 'ecosystem', dirPrefix: '../ecosystem/'),
            (name: 'widgets', dirPrefix: ''),
          ],
        );
        final String communityHtml = htmlFile.readAsStringSync();
        final String issuesHtml = issuesPageFileFor(htmlFile).readAsStringSync();
        expect(communityHtml, contains('title="@bob">mod:button</span>'));
        expect(communityHtml, contains('keep-visible'));
        expect(communityHtml, contains('<select id="config-select"'));
        expect(
          communityHtml,
          contains('<option value="../ecosystem/index.html">ecosystem</option>'),
        );
        expect(communityHtml, contains('<option value="index.html" selected>widgets</option>'));
        expect(issuesHtml, contains('team-widgets'));
        expect(issuesHtml, contains('sev-1'));
        expect(
          issuesHtml,
          contains('<option value="../ecosystem/index_issues.html">ecosystem</option>'),
        );
        expect(issuesHtml, contains('<option value="index_issues.html" selected>widgets</option>'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'extractSuggestedReviewerHandles and updateTeamMembersInDartConfig sync reviewers cleanly',
      () {
        final List<String> handles = extractSuggestedReviewerHandles('''
`camera`:
  - **Cross-platform**: @bparrishMines
  - **Android**: @camsim99, @BparrishMines
`rfw`:
  - @Hixie
''');
        expect(handles, <String>['bparrishMines', 'camsim99', 'Hixie']);

        final String updated = updateTeamMembersInDartConfig('''
const TriageConfig config = TriageConfig(
  repos: <String>['flutter/packages'],
  flutterTeam: 'ecosystem',
  teamMembers: <String>[
    'olduser',
  ],
  rosterFile: 'flutter/packages:SUGGESTED_REVIEWERS.md',
);
''', handles);

        final TriageConfig reparsed = parseDartConfig(updated);
        expect(reparsed.teamMembers, <String>['bparrishMines', 'camsim99', 'Hixie']);
        expect(reparsed.refreshSchedule, '37 19 * * 2');
      },
    );

    test('updateWorkflowSchedulesInYaml syncs cron schedules from multiple configs', () {
      const yaml = '''
on:
  push:
    branches: [main]
  schedule:
    - cron: '0 0 * * 0'
  workflow_dispatch:
''';
      final String synced = updateWorkflowSchedulesInYaml(yaml, const <String, TriageConfig>{
        'ecosystem': TriageConfig(),
        'ios': TriageConfig(flutterTeam: 'ios', refreshSchedule: '0 17 * * 4'),
      });
      expect(synced, contains("- cron: '37 19 * * 2' # ecosystem"));
      expect(synced, contains("- cron: '0 17 * * 4' # ios"));
    });

    test('all configs/*.dart files parse cleanly with ecosystem first', () {
      final Map<String, TriageConfig> configs = loadConfigsDirectory(Directory('configs'));
      expect(configs.keys.first, 'ecosystem');
      expect(
        configs.keys,
        containsAll(<String>[
          'accessibility',
          'android',
          'design',
          'devexp',
          'ecosystem',
          'engine',
          'fluttergpu',
          'framework',
          'infra',
          'ios',
          'linux',
          'macos',
          'text_input',
          'tool',
          'web',
          'windows',
        ]),
      );
      for (final MapEntry<String, TriageConfig> entry in configs.entries) {
        expect(entry.value.repos, isNotEmpty, reason: '${entry.key} repos');
        expect(entry.value.flutterTeam, isNotNull, reason: '${entry.key} flutterTeam');
        expect(entry.value.refreshSchedule, isNotNull, reason: '${entry.key} refreshSchedule');
        expect(entry.value.teamMembers, isNotEmpty, reason: '${entry.key} teamMembers');
      }
      expect(configs['design']!.hiddenLabels, isEmpty);
      expect(configs['design']!.prLabels, contains('triage-design'));
      expect(configs['ios']!.prLabels, contains('platform-ios'));
    });

    test('filterPRListingsByLabels filters open PRs by prLabels case-insensitively', () {
      final prs = <Map<String, dynamic>>[
        <String, dynamic>{
          'number': 1,
          'labels': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'platform-ios'},
          ],
        },
        <String, dynamic>{
          'number': 2,
          'labels': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'platform-android'},
          ],
        },
      ];
      expect(filterPRListingsByLabels(prs, const <String>{}), hasLength(2));
      final List<Map<String, dynamic>> filtered = filterPRListingsByLabels(prs, const <String>{
        'PLATFORM-IOS',
        'triage-ios',
      });
      expect(filtered, hasLength(1));
      expect(filtered.single['number'], 1);
    });
  });
}
