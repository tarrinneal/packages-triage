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
    test('default triage.yaml matches const TriageConfig()', () {
      final config = TriageConfig.fromFile(File('triage.yaml'));
      const defaults = TriageConfig();

      expect(config.repos, defaults.repos);
      expect(config.issuesRepo, defaults.issuesRepo);
      expect(config.workflowRepo, defaults.workflowRepo);
      expect(config.rosterFile, defaults.rosterFile);
      expect(config.botAccounts, defaults.botAccounts);
      expect(config.requiredApprovals, defaults.requiredApprovals);
      expect(config.hiddenLabels, defaults.hiddenLabels);
      expect(config.nonHiddenFilterLabel, defaults.nonHiddenFilterLabel);
      expect(config.routingLabelPrefixes, defaults.routingLabelPrefixes);
      expect(config.packageLabelPrefix, defaults.packageLabelPrefix);
      expect(config.showAllLabels, defaults.showAllLabels);
      expect(config.waitingForResponseLabels, defaults.waitingForResponseLabels);
      expect(config.issueTeamLabel, defaults.issueTeamLabel);
      expect(config.issueFyiLabel, defaults.issueFyiLabel);
      expect(config.issueTriagedLabel, defaults.issueTriagedLabel);
      expect(config.priorityLabels, defaults.priorityLabels);
      expect(config.highPriorityLabels, defaults.highPriorityLabels);
    });

    test('empty YAML uses built-in defaults', () {
      final config = TriageConfig.fromYaml('');
      const defaults = TriageConfig();
      expect(config.repos, defaults.repos);
      expect(config.issuesRepo, defaults.issuesRepo);
      expect(config.issueTeamLabel, defaults.issueTeamLabel);
    });

    test('parses custom repositories and labels from YAML', () {
      final config = TriageConfig.fromYaml('''
repos:
  - dart-lang/tools
  - dart-lang/native
issues_repo: null
workflow_repo: dart-lang/triage-dashboard
roster_file: OWNERS.md
bot_accounts:
  - dart-Autoroller
required_approvals: 1
hidden_labels:
  - needs-rfc
non_hidden_filter_label: ""
routing_label_prefixes:
  - "pkg:"
  - "os-"
package_label_prefix: "pkg:"
show_all_labels: true
waiting_for_response_labels:
  - needs-info
issue_team_label: area-tools
issue_fyi_label: fyi-tools
issue_triaged_label: triaged
priority_labels:
  - P1
  - P2
high_priority_labels:
  - P1
''');

      expect(config.repos, <String>['dart-lang/tools', 'dart-lang/native']);
      expect(config.issuesRepo, isNull);
      expect(config.workflowRepo, 'dart-lang/triage-dashboard');
      expect(config.rosterFile, 'OWNERS.md');
      expect(config.botAccounts, <String>{'dart-Autoroller'});
      expect(config.requiredApprovals, 1);
      expect(config.hiddenLabels, <String>{'needs-rfc'});
      expect(config.nonHiddenFilterLabel, '');
      expect(config.routingLabelPrefixes, <String>['pkg:', 'os-']);
      expect(config.packageLabelPrefix, 'pkg:');
      expect(config.showAllLabels, isTrue);
      expect(config.waitingForResponseLabels, <String>{'needs-info'});
      expect(config.issueTeamLabel, 'area-tools');
      expect(config.issueFyiLabel, 'fyi-tools');
      expect(config.issueTriagedLabel, 'triaged');
      expect(config.priorityLabels, <String>['P1', 'P2']);
      expect(config.highPriorityLabels, <String>{'P1'});
    });

    test('rejects unknown keys and invalid values', () {
      expect(() => TriageConfig.fromYaml('unknown_field: 123'), throwsFormatException);
      expect(() => TriageConfig.fromYaml('repos: [not-a-repo]'), throwsFormatException);
      expect(() => TriageConfig.fromYaml('repos: []'), throwsFormatException);
      expect(() => TriageConfig.fromYaml('required_approvals: 0'), throwsFormatException);
    });

    test('applies custom config to PR and issue triage and HTML output', () {
      final config = TriageConfig.fromYaml('''
repos:
  - acme/widgets
issues_repo: acme/issues
roster_file: REVIEWERS.md
bot_accounts:
  - acme-bot
required_approvals: 1
hidden_labels:
  - skip-triage
non_hidden_filter_label: keep-visible
routing_label_prefixes:
  - "mod:"
package_label_prefix: "mod:"
waiting_for_response_labels:
  - awaiting-author
issue_team_label: team-widgets
issue_fyi_label: fyi-widgets
issue_triaged_label: triaged-widgets
priority_labels:
  - sev-1
  - sev-2
high_priority_labels:
  - sev-1
''');

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
        final htmlFile = File('${tempDir.path}/index.html');
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
        );
        final String communityHtml = htmlFile.readAsStringSync();
        final String issuesHtml = issuesPageFileFor(htmlFile).readAsStringSync();
        expect(communityHtml, contains('title="@bob">mod:button</span>'));
        expect(communityHtml, contains('keep-visible'));
        expect(issuesHtml, contains('team-widgets'));
        expect(issuesHtml, contains('sev-1'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
