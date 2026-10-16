// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'types.dart';
import 'utils.dart';

/// PRs with any of these labels are hidden by default, since another triage
/// rotation handles them.
const Set<String> defaultHiddenLabels = <String>{'triage-design'};

/// Days of waiting after which a PR is due for attention.
const int dueDays = 7;

/// Days of waiting after which a PR is overdue.
const int overdueDays = 14;

/// Days of waiting after which a PR is critically overdue.
///
/// Community PRs that have waited this long on their author are candidates
/// for closing.
const int criticalDays = 30;

/// The urgency of a PR that has been waiting for [days] days.
Urgency urgencyForDays(int days) {
  if (days >= criticalDays) {
    return Urgency.critical;
  }
  if (days >= overdueDays) {
    return Urgency.overdue;
  }
  if (days >= dueDays) {
    return Urgency.due;
  }
  return Urgency.notYet;
}

/// A short description of [urgency], for display.
String urgencyLabel(Urgency urgency) => switch (urgency) {
  Urgency.notYet => 'not due yet',
  Urgency.due => 'due',
  Urgency.overdue => 'overdue',
  Urgency.critical => 'critical',
};

/// The sections shown on [page], in display order.
List<Section> sectionsFor(ReportPage page) => switch (page) {
  ReportPage.community => Section.values,
  ReportPage.team => const <Section>[
    Section.loadError,
    Section.waitingOnTeam,
    Section.waitingOnAuthor,
    Section.drafts,
  ],
};

/// The heading for [section] on [page].
String sectionTitle(Section section, ReportPage page) => switch (section) {
  Section.loadError => 'Failed to load',
  Section.needsReviewer => 'Needs reviewer',
  Section.waitingOnTeam => page == ReportPage.team ? 'Waiting on reviewer' : 'Waiting on team',
  Section.waitingOnAuthor => 'Waiting on author',
  Section.bots => 'Bots',
  Section.drafts => 'Drafts',
};

/// The title of [page].
String pageTitle(ReportPage page) => switch (page) {
  ReportPage.community => 'Community PRs',
  ReportPage.team => 'Team PRs',
};

/// Whether [pr] has any of [hiddenLabels].
bool hasHiddenLabel(PRInfo pr, Set<String> hiddenLabels) => pr.labels.any(hiddenLabels.contains);

/// Whether [label] says which package, platform, or triage rotation a PR
/// belongs to, which makes it worth showing in the report.
bool isRoutingLabel(String label) =>
    label.startsWith('p: ') || label.startsWith('platform-') || label.startsWith('triage-');

/// How long [analysis]'s PR has been waiting, and on whom, e.g. "12d on team".
String waitingLabel(PRAnalysis analysis) {
  final int days = analysis.waitingDays;
  return switch (analysis.section) {
    Section.loadError => 'unknown',
    Section.needsReviewer || Section.waitingOnTeam =>
      analysis.page == ReportPage.team ? '${days}d on reviewer' : '${days}d on team',
    Section.waitingOnAuthor => '${days}d on author',
    Section.bots => '${days}d open',
    Section.drafts => '${days}d idle',
  };
}

/// Orders analyses for display: by page and section, then most urgent and
/// longest waiting first, then oldest PR first.
int comparePRs(PRAnalysis a, PRAnalysis b) {
  int result = a.page.index.compareTo(b.page.index);
  if (result != 0) {
    return result;
  }
  result = a.section.index.compareTo(b.section.index);
  if (result != 0) {
    return result;
  }
  result = b.urgency.index.compareTo(a.urgency.index);
  if (result != 0) {
    return result;
  }
  result = b.waitingDays.compareTo(a.waitingDays);
  if (result != 0) {
    return result;
  }
  return a.pr.number.compareTo(b.pr.number);
}

/// Decides where [pr] goes in the report as of [now], how long it has been
/// waiting, and what a triager should do next.
PRAnalysis analyzePR(PRInfo pr, {required DateTime now}) {
  final ReportPage page = pr.authorType == ContributorType.member
      ? ReportPage.team
      : ReportPage.community;
  final isCommunityPR = pr.authorType == ContributorType.community;
  final reasons = <String>[
    if (pr.authorTypeFromRoster)
      '@${pr.author} counts as team: in SUGGESTED_REVIEWERS.md or requested as a reviewer',
  ];

  PRAnalysis place(
    Section section,
    DateTime waitingSince,
    String waitingSinceDescription,
    String Function(Urgency urgency) nextStep, {
    Urgency minimumUrgency = Urgency.notYet,
  }) {
    final int days = daysBetween(waitingSince, now);
    Urgency urgency = urgencyForDays(days);
    if (urgency.index < minimumUrgency.index) {
      urgency = minimumUrgency;
    }
    return PRAnalysis(
      pr: pr,
      page: page,
      section: section,
      waitingSince: waitingSince,
      waitingDays: days,
      urgency: urgency,
      nextStep: nextStep(urgency),
      reasons: <String>[
        ...reasons,
        'Waiting since $waitingSinceDescription (${formatAsDay(waitingSince)})',
      ],
    );
  }

  if (pr.fetchErrors.isNotEmpty) {
    return PRAnalysis(
      pr: pr,
      page: page,
      section: Section.loadError,
      waitingSince: pr.updatedDate,
      waitingDays: daysBetween(pr.updatedDate, now),
      urgency: Urgency.notYet,
      nextStep: 'Check it on GitHub, or rerun to retry',
      reasons: <String>[...reasons, ...pr.fetchErrors],
    );
  }

  if (pr.authorType == ContributorType.bot) {
    reasons.add('Opened by a bot');
    return place(
      Section.bots,
      pr.creationDate,
      'the PR was opened',
      (Urgency urgency) =>
          urgency == Urgency.overdue || urgency == Urgency.critical ? 'Check if stuck' : '',
    );
  }

  final DateTime lastAuthorCommentDate = pr.authorComment?.date ?? pr.creationDate;
  final DateTime? lastMemberCommentDate = pr.memberComment?.date;
  final bool lastCommentIsAuthor =
      lastMemberCommentDate == null || lastAuthorCommentDate.isAfter(lastMemberCommentDate);
  final Map<ReviewState, int> reviewStateCount = pr.reviewStateCount;
  final bool hasBlockingReview = (reviewStateCount[ReviewState.changesRequested] ?? 0) > 0;
  // In theory this should be a really useful signal, but we can't dismiss
  // revview requests that come from CODEOWNERS, so we don't use this. We may
  // want to revisit using CODEOWNERS in the first place.
  final bool hasPendingReview = (reviewStateCount[ReviewState.pending] ?? 0) > 0;
  final bool hasCommentReview = (reviewStateCount[ReviewState.commented] ?? 0) > 0;

  // Try to figure out if this PR is waiting for the author to do something, vs.
  // waiting for the Flutter team. This is heuristic, so will give wrong answers
  // sometimes. In general, err on the side of assuming it's waiting for the
  // Flutter team so that we look at it.
  var waitingForPRAuthor = false;
  final String turnReason;
  if (pr.isDraft) {
    waitingForPRAuthor = true;
    turnReason = 'Draft';
  } else if (hasBlockingReview && !lastCommentIsAuthor) {
    // This should generally be correct; if it's not we probably need to
    // re-request review in triage.
    waitingForPRAuthor = true;
    turnReason = 'Changes were requested, and the team commented after the author';
  } else if (hasCommentReview && !lastCommentIsAuthor) {
    // This probably means that the author hasn't responded to review feedback
    // yet, but we'll need to see how often this is wrong (e.g., due to an
    // old comment review that was never dismissed).
    waitingForPRAuthor = true;
    turnReason = 'A reviewer left a comment review, and the team commented after the author';
  } else if (isCommunityPR && !(hasBlockingReview || hasCommentReview)) {
    // If a community PR doesn't have any active requests from the team, that's
    // probably a sign that the ball is in our court.
    waitingForPRAuthor = false;
    turnReason = 'Community PR with no changes-requested or comment reviews';
  } else if (!isCommunityPR && !lastCommentIsAuthor) {
    // For team PRs, where missing a PR that needs attention is much less of
    // an issue (since they can escalate directly with reviewers), just follow
    // the last comment date.
    waitingForPRAuthor = true;
    turnReason = 'Team PR, and the team commented after the author';
  } else {
    turnReason = lastMemberCommentDate == null
        ? 'No comments from the team yet'
        : "The author replied after the team's last comment";
  }
  // TODO(stuartmorgan): Other heuristics? Should we fall back on the last comment date if
  // we can't determine who's turn it is?
  reasons.add(turnReason);

  final bool hasInProgressReview = hasPendingReview || hasCommentReview || hasBlockingReview;

  // Don't count <2 as missing unless one of them is an approval, since
  // community PR reviews are often intentionally serial (to reduce sunk time
  // if the PR is abandoned).
  final bool missingReviewer =
      isCommunityPR && !hasInProgressReview && (reviewStateCount[ReviewState.approved] ?? 0) <= 1;

  if (pr.isDraft) {
    return place(
      Section.drafts,
      pr.updatedDate,
      'the PR was last updated',
      (Urgency urgency) => isCommunityPR && urgency == Urgency.critical ? 'Consider closing' : '',
    );
  }

  if (missingReviewer) {
    final DateTime? firstApproval = pr.firstApprovalDate;
    if (firstApproval == null) {
      reasons.add('No approvals, and no requested, commenting, or blocking reviewers');
      return place(
        Section.needsReviewer,
        pr.creationDate,
        'the PR was opened',
        (_) => 'Assign a reviewer',
        minimumUrgency: Urgency.due,
      );
    }
    reasons.add('One approval, and no other requested, commenting, or blocking reviewers');
    return place(
      Section.needsReviewer,
      firstApproval,
      'the first approval',
      (_) => 'Assign a second reviewer',
      minimumUrgency: Urgency.due,
    );
  }

  if (waitingForPRAuthor) {
    return place(
      Section.waitingOnAuthor,
      lastMemberCommentDate ?? lastAuthorCommentDate,
      "the team's last comment",
      (Urgency urgency) => switch (urgency) {
        Urgency.notYet => '',
        Urgency.due || Urgency.overdue => 'Ping @${pr.author}',
        Urgency.critical => isCommunityPR ? 'Consider closing' : 'Ping @${pr.author}',
      },
    );
  }

  return place(
    Section.waitingOnTeam,
    lastAuthorCommentDate,
    pr.authorComment == null ? 'the PR was opened' : "the author's last comment",
    (Urgency urgency) => _teamNextStep(pr, urgency),
  );
}

String _teamNextStep(PRInfo pr, Urgency urgency) {
  if (urgency == Urgency.notYet) {
    return '';
  }
  final List<String> names = pr.reviewers.keys.toList()
    ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
  final List<String> requested = names
      .where((String name) => pr.reviewers[name]!.requested)
      .toList();
  final List<String> engaged = names.where((String name) {
    final ReviewerStatus status = pr.reviewers[name]!;
    return status.decision == ReviewState.changesRequested || status.commented;
  }).toList();
  final toPing = requested.isNotEmpty ? requested : engaged;
  if (toPing.isNotEmpty) {
    final String mentions = toPing.map((String name) => '@$name').join(', ');
    return urgency == Urgency.critical ? 'Ping or reassign $mentions' : 'Ping $mentions';
  }
  if (pr.approvalCount >= 2) {
    return "Approved; check why it hasn't landed";
  }
  return 'No reviewer assigned';
}
