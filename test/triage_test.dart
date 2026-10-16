// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pr_inspector/triage.dart';
import 'package:pr_inspector/types.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 10, 1, 12);

DateTime _daysAgo(int days) => _now.subtract(Duration(days: days));

PRInfo _pr({
  int number = 1,
  ContributorType type = ContributorType.community,
  bool draft = false,
  int openedDaysAgo = 60,
  int updatedDaysAgo = 0,
  bool fromRoster = false,
  int? authorCommentDaysAgo,
  int? memberCommentDaysAgo,
}) {
  final pr = PRInfo(
    number: number,
    author: 'author',
    title: 'PR $number',
    url: 'https://github.com/o/r/pull/$number',
    creationDate: _daysAgo(openedDaysAgo),
    updatedDate: _daysAgo(updatedDaysAgo),
    authorType: type,
    isDraft: draft,
    authorTypeFromRoster: fromRoster,
  )..hasDetails = true;
  if (authorCommentDaysAgo != null) {
    pr.authorComment = (username: 'author', date: _daysAgo(authorCommentDaysAgo));
  }
  if (memberCommentDaysAgo != null) {
    pr.memberComment = (username: 'teammate', date: _daysAgo(memberCommentDaysAgo));
  }
  return pr;
}

void _addReviewer(
  PRInfo pr,
  String name, {
  ReviewState? decision,
  int decisionDaysAgo = 10,
  bool commented = false,
  bool requested = false,
}) {
  pr.reviewers[name] = ReviewerStatus()
    ..decision = decision
    ..decisionDate = decision == null ? null : _daysAgo(decisionDaysAgo)
    ..commented = commented
    ..requested = requested;
}

PRAnalysis _analyze(PRInfo pr) => analyzePR(pr, now: _now);

void main() {
  group('urgencyForDays', () {
    test('uses 7/14/30 day tiers', () {
      expect(urgencyForDays(0), Urgency.notYet);
      expect(urgencyForDays(6), Urgency.notYet);
      expect(urgencyForDays(7), Urgency.due);
      expect(urgencyForDays(13), Urgency.due);
      expect(urgencyForDays(14), Urgency.overdue);
      expect(urgencyForDays(29), Urgency.overdue);
      expect(urgencyForDays(30), Urgency.critical);
    });
  });

  group('needs reviewer', () {
    test('community PR with no reviewers needs one right away', () {
      final PRAnalysis analysis = _analyze(_pr(openedDaysAgo: 3));
      expect(analysis.page, ReportPage.community);
      expect(analysis.section, Section.needsReviewer);
      expect(analysis.nextStep, 'Assign a reviewer');
      expect(analysis.waitingDays, 3);
      expect(analysis.urgency, Urgency.due);
    });

    test('community PR with one approval needs a second reviewer, timed from the approval', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 20, memberCommentDaysAgo: 16);
      _addReviewer(pr, 'alice', decision: ReviewState.approved, decisionDaysAgo: 16);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.needsReviewer);
      expect(analysis.nextStep, 'Assign a second reviewer');
      expect(analysis.waitingDays, 16);
      expect(analysis.urgency, Urgency.overdue);
    });

    test('a requested reviewer counts as engaged', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 10);
      _addReviewer(pr, 'bob', requested: true);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.waitingOnTeam);
      expect(analysis.nextStep, 'Ping @bob');
    });

    test('team PRs never need a reviewer from triage', () {
      final PRAnalysis analysis = _analyze(_pr(type: ContributorType.member, openedDaysAgo: 3));
      expect(analysis.page, ReportPage.team);
      expect(analysis.section, Section.waitingOnTeam);
      expect(analysis.nextStep, '');
    });
  });

  group('waiting on team', () {
    test("is timed from the author's last comment, not a later team ping", () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 20, memberCommentDaysAgo: 2);
      _addReviewer(pr, 'bob', requested: true);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.waitingOnTeam);
      expect(analysis.waitingSince, _daysAgo(20));
      expect(analysis.waitingDays, 20);
      expect(analysis.urgency, Urgency.overdue);
      expect(analysis.nextStep, 'Ping @bob');
    });

    test('is timed from creation if the author never commented', () {
      final PRInfo pr = _pr(openedDaysAgo: 8);
      _addReviewer(pr, 'bob', requested: true);
      expect(_analyze(pr).waitingDays, 8);
    });

    test('suggests reassigning when critical', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 45);
      _addReviewer(pr, 'bob', requested: true);
      _addReviewer(pr, 'alice', requested: true);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.urgency, Urgency.critical);
      expect(analysis.nextStep, 'Ping or reassign @alice, @bob');
    });

    test('pings blocking reviewers once the author has replied', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 9, memberCommentDaysAgo: 12);
      _addReviewer(pr, 'carol', decision: ReviewState.changesRequested, decisionDaysAgo: 12);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.waitingOnTeam);
      expect(analysis.nextStep, 'Ping @carol');
      expect(analysis.reasons, contains("The author replied after the team's last comment"));
    });

    test('flags approved PRs that have not landed', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 10, memberCommentDaysAgo: 8);
      _addReviewer(pr, 'alice', decision: ReviewState.approved);
      _addReviewer(pr, 'bob', decision: ReviewState.approved);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.waitingOnTeam);
      expect(analysis.nextStep, "Approved; check why it hasn't landed");
    });

    test('has no next step before it is due', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 3);
      _addReviewer(pr, 'bob', requested: true);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.urgency, Urgency.notYet);
      expect(analysis.nextStep, '');
    });
  });

  group('waiting on author', () {
    test("after changes are requested, timed from the team's last comment", () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 30, memberCommentDaysAgo: 10);
      _addReviewer(pr, 'carol', decision: ReviewState.changesRequested);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.waitingOnAuthor);
      expect(analysis.waitingSince, _daysAgo(10));
      expect(analysis.nextStep, 'Ping @author');
    });

    test('after a comment review', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 12, memberCommentDaysAgo: 8);
      _addReviewer(pr, 'dave', commented: true);
      expect(_analyze(pr).section, Section.waitingOnAuthor);
    });

    test('suggests closing community PRs after 30 days', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 90, memberCommentDaysAgo: 30);
      _addReviewer(pr, 'carol', decision: ReviewState.changesRequested, decisionDaysAgo: 30);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.urgency, Urgency.critical);
      expect(analysis.nextStep, 'Consider closing');
    });

    test('pings team authors instead of suggesting closing', () {
      final PRInfo pr = _pr(
        type: ContributorType.member,
        authorCommentDaysAgo: 90,
        memberCommentDaysAgo: 30,
      );
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.page, ReportPage.team);
      expect(analysis.section, Section.waitingOnAuthor);
      expect(analysis.nextStep, 'Ping @author');
    });

    test('has no next step before it is due', () {
      final PRInfo pr = _pr(authorCommentDaysAgo: 5, memberCommentDaysAgo: 3);
      _addReviewer(pr, 'dave', commented: true);
      final PRAnalysis analysis = _analyze(pr);
      expect(analysis.section, Section.waitingOnAuthor);
      expect(analysis.nextStep, '');
    });
  });

  test('a comment review after an approval keeps the approval', () {
    final PRInfo pr = _pr();
    _addReviewer(pr, 'alice', decision: ReviewState.approved, commented: true);
    expect(pr.approvalCount, 1);
    expect(pr.reviewStateCount[ReviewState.commented], 1);
  });

  test('a requested reviewer shows only as pending', () {
    final PRInfo pr = _pr();
    _addReviewer(pr, 'alice', decision: ReviewState.approved, requested: true);
    expect(pr.reviewers['alice']!.displayStates, <ReviewState>[ReviewState.pending]);
    expect(pr.approvalCount, 0);
  });

  group('drafts', () {
    test('community drafts idle for 30 days are close candidates', () {
      final PRAnalysis analysis = _analyze(_pr(draft: true, updatedDaysAgo: 40));
      expect(analysis.page, ReportPage.community);
      expect(analysis.section, Section.drafts);
      expect(analysis.waitingDays, 40);
      expect(analysis.nextStep, 'Consider closing');
    });

    test('team drafts go on the team page', () {
      final PRAnalysis analysis = _analyze(
        _pr(type: ContributorType.member, draft: true, updatedDaysAgo: 40),
      );
      expect(analysis.page, ReportPage.team);
      expect(analysis.section, Section.drafts);
      expect(analysis.nextStep, '');
    });
  });

  group('bots', () {
    test('are flagged once overdue', () {
      final PRAnalysis analysis = _analyze(_pr(type: ContributorType.bot, openedDaysAgo: 20));
      expect(analysis.page, ReportPage.community);
      expect(analysis.section, Section.bots);
      expect(analysis.nextStep, 'Check if stuck');
    });

    test('are left alone while recent', () {
      expect(_analyze(_pr(type: ContributorType.bot, openedDaysAgo: 3)).nextStep, '');
    });
  });

  test('PRs that failed to load are not ranked', () {
    final PRInfo pr = _pr(authorCommentDaysAgo: 100);
    pr.fetchErrors.add('Failed to fetch reviews: 502');
    final PRAnalysis analysis = _analyze(pr);
    expect(analysis.section, Section.loadError);
    expect(analysis.reasons, contains('Failed to fetch reviews: 502'));
  });

  test('explains roster-based team classification', () {
    final PRAnalysis analysis = _analyze(_pr(type: ContributorType.member, fromRoster: true));
    expect(analysis.reasons.first, contains('SUGGESTED_REVIEWERS.md'));
  });

  test('section titles depend on the page', () {
    expect(sectionTitle(Section.waitingOnTeam, ReportPage.community), 'Waiting on team');
    expect(sectionTitle(Section.waitingOnTeam, ReportPage.team), 'Waiting on reviewer');
    expect(sectionsFor(ReportPage.team), isNot(contains(Section.needsReviewer)));
    expect(sectionsFor(ReportPage.team), isNot(contains(Section.bots)));
  });

  test('comparePRs orders by page, section, urgency, wait, then number', () {
    PRAnalysis make(int number, ReportPage page, Section section, int days, {Urgency? urgency}) =>
        PRAnalysis(
          pr: _pr(number: number),
          page: page,
          section: section,
          waitingSince: _daysAgo(days),
          waitingDays: days,
          urgency: urgency ?? urgencyForDays(days),
          nextStep: '',
          reasons: const <String>[],
        );
    final analyses = <PRAnalysis>[
      make(1, ReportPage.team, Section.waitingOnTeam, 100),
      make(2, ReportPage.community, Section.drafts, 500),
      make(3, ReportPage.community, Section.waitingOnTeam, 3),
      make(4, ReportPage.community, Section.waitingOnTeam, 20),
      make(5, ReportPage.community, Section.needsReviewer, 1, urgency: Urgency.due),
      make(6, ReportPage.community, Section.waitingOnTeam, 20),
      make(7, ReportPage.community, Section.waitingOnTeam, 25),
    ]..sort(comparePRs);
    expect(analyses.map((PRAnalysis a) => a.pr.number), <int>[5, 7, 4, 6, 3, 2, 1]);
  });

  test('hasHiddenLabel and isRoutingLabel', () {
    final pr = PRInfo(
      number: 1,
      author: 'a',
      title: 't',
      url: 'u',
      creationDate: _now,
      updatedDate: _now,
      authorType: ContributorType.community,
      isDraft: false,
      labels: const <String>['p: material_ui', 'triage-design', 'CICD'],
    );
    expect(hasHiddenLabel(pr, defaultHiddenLabels), isTrue);
    expect(hasHiddenLabel(pr, const <String>{}), isFalse);
    expect(pr.labels.where(isRoutingLabel), <String>['p: material_ui', 'triage-design']);
  });
}
