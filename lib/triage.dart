// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'config.dart';
import 'types.dart';
import 'utils.dart';

export 'config.dart'
    show
        TriageConfig,
        configFileFor,
        defaultBotAccounts,
        defaultConfigFileName,
        defaultHiddenLabels,
        defaultHighPriorityLabels,
        defaultIssueFyiLabel,
        defaultIssueTeamLabel,
        defaultIssueTriagedLabel,
        defaultIssuesRepo,
        defaultNonHiddenFilterLabel,
        defaultPackageLabelPrefix,
        defaultPriorityLabels,
        defaultRepos,
        defaultRequiredApprovals,
        defaultRosterFile,
        defaultRoutingLabelPrefixes,
        defaultWaitingForResponseLabels,
        defaultWorkflowRepo;

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
bool isRoutingLabel(String label, {TriageConfig config = const TriageConfig()}) =>
    config.routingLabelPrefixes.any(label.startsWith);

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

/// Orders analyses for display: by page and section, then most urgent,
/// contributor follow-ups, and longest waiting first, then oldest PR first.
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
  result = (b.isFollowUp ? 1 : 0).compareTo(a.isFollowUp ? 1 : 0);
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
PRAnalysis analyzePR(
  PRInfo pr, {
  required DateTime now,
  int? requiredApprovals,
  TriageConfig config = const TriageConfig(),
}) {
  final int effectiveRequiredApprovals = requiredApprovals ?? config.requiredApprovals;
  final ReportPage page = pr.authorType == ContributorType.member
      ? ReportPage.team
      : ReportPage.community;
  final isCommunityPR = pr.authorType == ContributorType.community;
  final rosterSource = config.rosterFile.isNotEmpty
      ? 'in ${config.rosterFile}, CODEOWNERS, or requested as a reviewer'
      : 'in CODEOWNERS or requested as a reviewer';
  final reasons = <String>[
    if (pr.authorTypeFromRoster) '@${pr.author} counts as team: $rosterSource',
  ];

  PRAnalysis place(
    Section section,
    DateTime waitingSince,
    String waitingSinceDescription,
    String Function(Urgency urgency) nextStep, {
    Urgency minimumUrgency = Urgency.notYet,
    bool isFollowUp = false,
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
      isFollowUp: isFollowUp,
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
  final bool hasAuthorFollowUp =
      lastMemberCommentDate != null &&
      pr.authorComment != null &&
      lastAuthorCommentDate.isAfter(lastMemberCommentDate);
  final DateTime followUpDate = pr.authorFollowUpComment?.date ?? lastAuthorCommentDate;
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
    turnReason = hasAuthorFollowUp
        ? "The author replied after the team's last comment"
        : 'Community PR with no changes-requested or comment reviews';
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

  // Don't count <requiredApprovals as missing unless one of them is an
  // approval, since community PR reviews are often intentionally serial (to
  // reduce sunk time if the PR is abandoned).
  final int approvals = reviewStateCount[ReviewState.approved] ?? 0;
  final bool missingReviewer =
      isCommunityPR && !hasInProgressReview && approvals < effectiveRequiredApprovals;

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
        isFollowUp: hasAuthorFollowUp,
      );
    }
    reasons.add('One approval, and no other requested, commenting, or blocking reviewers');
    return place(
      Section.needsReviewer,
      firstApproval,
      'the first approval',
      (_) => 'Assign a second reviewer',
      minimumUrgency: Urgency.due,
      isFollowUp: hasAuthorFollowUp,
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

  final waitingSince = hasAuthorFollowUp ? followUpDate : lastAuthorCommentDate;
  final String waitingSinceDescription;
  if (pr.authorComment == null) {
    waitingSinceDescription = 'the PR was opened';
  } else if (hasAuthorFollowUp &&
      pr.authorFollowUpComment != null &&
      pr.authorFollowUpComment!.date != lastAuthorCommentDate) {
    waitingSinceDescription = "the author's follow-up comment";
  } else {
    waitingSinceDescription = "the author's last comment";
  }

  return place(
    Section.waitingOnTeam,
    waitingSince,
    waitingSinceDescription,
    (Urgency urgency) => _teamNextStep(pr, urgency, requiredApprovals: effectiveRequiredApprovals),
    isFollowUp: hasAuthorFollowUp,
  );
}

String _teamNextStep(
  PRInfo pr,
  Urgency urgency, {
  int requiredApprovals = defaultRequiredApprovals,
}) {
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
  final toPing = requested.isNotEmpty
      ? requested
      : engaged.isNotEmpty
      ? engaged
      : <String>[
          if (pr.memberComment != null && pr.approvalCount < requiredApprovals)
            pr.memberComment!.username,
        ];
  if (toPing.isNotEmpty) {
    final String mentions = toPing.map((String name) => '@$name').join(', ');
    return urgency == Urgency.critical ? 'Ping or reassign $mentions' : 'Ping $mentions';
  }
  if (pr.approvalCount >= requiredApprovals) {
    return "Approved; check why it hasn't landed";
  }
  return 'No reviewer assigned';
}

/// Priority labels used on `flutter/flutter` issues.
const Set<String> priorityLabels = <String>{'P0', 'P1', 'P2', 'P3'};

/// Returns the priority label (`P0`–`P3`) on [issue], or `null` if none is set.
String? issuePriority(IssueInfo issue, {TriageConfig config = const TriageConfig()}) {
  for (final String p in config.priorityLabels) {
    if (issue.labels.contains(p)) {
      return p;
    }
  }
  return null;
}

/// Labels indicating that an item is waiting on a response from the author.
const Set<String> waitingForResponseLabels = defaultWaitingForResponseLabels;

/// Whether [labels] includes any of [waitingForResponseLabels].
bool hasWaitingForResponseLabel(
  Iterable<String> labels, {
  TriageConfig config = const TriageConfig(),
}) => labels.any(config.waitingForResponseLabels.contains);

/// Whether [label] is useful to display on an issue row.
bool isIssueDisplayLabel(String label, {TriageConfig config = const TriageConfig()}) =>
    isRoutingLabel(label, config: config) ||
    config.priorityLabels.contains(label) ||
    (config.issueFyiLabel != null && label == config.issueFyiLabel) ||
    config.waitingForResponseLabels.contains(label);

const String _unsetIssueLabel = '\u0000';

/// The heading for [section] on the issues page.
String issueSectionTitle(
  IssueSection section, {
  String? teamLabel = _unsetIssueLabel,
  String? fyiLabel = _unsetIssueLabel,
  TriageConfig config = const TriageConfig(),
}) {
  final String? effectiveTeamLabel = identical(teamLabel, _unsetIssueLabel)
      ? config.issueTeamLabel
      : teamLabel;
  final String? effectiveFyiLabel = identical(fyiLabel, _unsetIssueLabel)
      ? config.issueFyiLabel
      : fyiLabel;
  final highPriorityLabel = config.highPriorityLabels.isNotEmpty
      ? 'High priority (${config.highPriorityLabels.join(' / ')})'
      : 'High priority';
  final String waitingLabel = config.waitingForResponseLabels.firstOrNull ?? 'waiting for response';
  return switch (section) {
    IssueSection.loadError => 'Failed to load',
    IssueSection.untriaged =>
      effectiveTeamLabel != null && effectiveTeamLabel.isNotEmpty
          ? 'Untriaged ($effectiveTeamLabel)'
          : 'Untriaged',
    IssueSection.fyiEcosystem =>
      effectiveFyiLabel == defaultIssueFyiLabel
          ? 'FYI Ecosystem ($defaultIssueFyiLabel)'
          : (effectiveFyiLabel != null && effectiveFyiLabel.isNotEmpty
                ? 'FYI ($effectiveFyiLabel)'
                : 'FYI'),
    IssueSection.waitingOnTeam => 'Waiting on team (author followed up)',
    IssueSection.highPriority => highPriorityLabel,
    IssueSection.waitingOnAuthor => 'Waiting on author ($waitingLabel)',
    IssueSection.otherTeamIssues =>
      effectiveTeamLabel != null && effectiveTeamLabel.isNotEmpty
          ? 'Other ($effectiveTeamLabel)'
          : 'Other',
  };
}

/// How long [analysis]'s issue has been waiting, and on whom.
String issueWaitingLabel(IssueAnalysis analysis) {
  final int days = analysis.waitingDays;
  return switch (analysis.section) {
    IssueSection.loadError => 'unknown',
    IssueSection.untriaged || IssueSection.fyiEcosystem => '${days}d untriaged',
    IssueSection.waitingOnTeam => '${days}d on team',
    IssueSection.highPriority || IssueSection.otherTeamIssues => '${days}d since update',
    IssueSection.waitingOnAuthor => '${days}d on author',
  };
}

/// Orders issue analyses by section, then urgency, follow-up status, wait time,
/// and issue number.
int compareIssues(IssueAnalysis a, IssueAnalysis b) {
  int result = a.section.index.compareTo(b.section.index);
  if (result != 0) {
    return result;
  }
  result = b.urgency.index.compareTo(a.urgency.index);
  if (result != 0) {
    return result;
  }
  result = (b.isFollowUp ? 1 : 0).compareTo(a.isFollowUp ? 1 : 0);
  if (result != 0) {
    return result;
  }
  result = b.waitingDays.compareTo(a.waitingDays);
  if (result != 0) {
    return result;
  }
  return a.issue.number.compareTo(b.issue.number);
}

/// Decides whether [issue] belongs on the issues page as of [now], and if so,
/// which section it belongs in and what the next step is.
///
/// All open issues labeled with [teamLabel] (by default `team-ecosystem`) are
/// included: those not in one of the actionable sections above are placed in
/// [IssueSection.otherTeamIssues] at the bottom of the page.
IssueAnalysis? analyzeIssue(
  IssueInfo issue, {
  required DateTime now,
  String? teamLabel,
  String? fyiLabel,
  String? triagedLabel,
  TriageConfig config = const TriageConfig(),
}) {
  if (issue.fetchErrors.isNotEmpty) {
    return IssueAnalysis(
      issue: issue,
      section: IssueSection.loadError,
      waitingSince: issue.updatedDate,
      waitingDays: daysBetween(issue.updatedDate, now),
      urgency: Urgency.notYet,
      nextStep: 'Check it on GitHub, or rerun to retry',
      reasons: <String>[...issue.fetchErrors],
    );
  }

  final String effectiveTeamLabel = teamLabel ?? (config.issueTeamLabel ?? '');
  final String effectiveFyiLabel = fyiLabel ?? (config.issueFyiLabel ?? '');
  final String effectiveTriagedLabel = triagedLabel ?? config.issueTriagedLabel;
  final bool isTeamLabeled =
      effectiveTeamLabel.isNotEmpty && issue.labels.contains(effectiveTeamLabel);
  final bool isFyiLabeled =
      effectiveFyiLabel.isNotEmpty && issue.labels.contains(effectiveFyiLabel);
  final bool isTriaged =
      effectiveTriagedLabel.isNotEmpty && issue.labels.contains(effectiveTriagedLabel);
  final String? priority = issuePriority(issue, config: config);
  final bool hasWaitingForResponse = hasWaitingForResponseLabel(issue.labels, config: config);
  final String primaryWaitingLabel =
      config.waitingForResponseLabels.firstOrNull ?? 'waiting for response';

  final DateTime lastAuthorCommentDate = issue.authorComment?.date ?? issue.creationDate;
  final DateTime? lastMemberCommentDate = issue.memberComment?.date;
  final bool hasAuthorFollowUp =
      lastMemberCommentDate != null &&
      issue.authorComment != null &&
      lastAuthorCommentDate.isAfter(lastMemberCommentDate);
  final DateTime followUpDate = issue.authorFollowUpComment?.date ?? lastAuthorCommentDate;

  IssueAnalysis place(
    IssueSection section,
    DateTime waitingSince,
    String waitingSinceDescription,
    String Function(Urgency urgency) nextStep, {
    required List<String> reasons,
    Urgency minimumUrgency = Urgency.notYet,
    bool isFollowUp = false,
  }) {
    final int days = daysBetween(waitingSince, now);
    Urgency urgency = urgencyForDays(days);
    if (urgency.index < minimumUrgency.index) {
      urgency = minimumUrgency;
    }
    return IssueAnalysis(
      issue: issue,
      section: section,
      waitingSince: waitingSince,
      waitingDays: days,
      urgency: urgency,
      nextStep: nextStep(urgency),
      reasons: <String>[
        ...reasons,
        'Waiting since $waitingSinceDescription (${formatAsDay(waitingSince)})',
      ],
      isFollowUp: isFollowUp,
    );
  }

  if (isFyiLabeled && !isTeamLabeled) {
    if (isTriaged) {
      return null;
    }
    return place(
      IssueSection.fyiEcosystem,
      issue.creationDate,
      'the issue was opened',
      (_) => 'Review and add $effectiveTriagedLabel',
      reasons: <String>['Labeled $effectiveFyiLabel without $effectiveTriagedLabel'],
      minimumUrgency: Urgency.due,
      isFollowUp: hasAuthorFollowUp,
    );
  }

  final String priorityRange = config.priorityLabels.length >= 2
      ? '${config.priorityLabels.first}–${config.priorityLabels.last}'
      : config.priorityLabels.join('/');
  final bool needsPriority = config.priorityLabels.isNotEmpty && priority == null;
  if (isTeamLabeled && (!isTriaged || needsPriority)) {
    final String missingReason;
    final String step;
    if (!isTriaged && needsPriority) {
      missingReason = 'Missing $effectiveTriagedLabel and priority label';
      step = 'Assign priority and add $effectiveTriagedLabel';
    } else if (!isTriaged) {
      missingReason = 'Missing $effectiveTriagedLabel label';
      step = 'Triage and add $effectiveTriagedLabel';
    } else {
      missingReason = 'Has $effectiveTriagedLabel, but missing a $priorityRange priority label';
      step = 'Assign a priority label ($priorityRange)';
    }
    return place(
      IssueSection.untriaged,
      hasAuthorFollowUp ? followUpDate : issue.creationDate,
      hasAuthorFollowUp ? "the author's follow-up comment" : 'the issue was opened',
      (_) => step,
      reasons: <String>[
        missingReason,
        if (hasAuthorFollowUp)
          "The author replied after @${issue.memberComment!.username}'s comment",
      ],
      minimumUrgency: Urgency.due,
      isFollowUp: hasAuthorFollowUp,
    );
  }

  if (hasAuthorFollowUp) {
    final bool usedEarliestFollowUp =
        issue.authorFollowUpComment != null &&
        issue.authorFollowUpComment!.date != lastAuthorCommentDate;
    return place(
      IssueSection.waitingOnTeam,
      followUpDate,
      usedEarliestFollowUp ? "the author's follow-up comment" : "the author's last comment",
      (Urgency urgency) {
        if (hasWaitingForResponse) {
          return 'Remove "$primaryWaitingLabel" and ping @${issue.memberComment!.username}';
        }
        return urgency == Urgency.notYet
            ? 'Follow up with @${issue.author} (last team comment by @${issue.memberComment!.username})'
            : 'Ping @${issue.memberComment!.username}';
      },
      reasons: <String>[
        "The author replied after @${issue.memberComment!.username}'s comment",
        if (hasWaitingForResponse) 'Still labeled $primaryWaitingLabel, but the author has replied',
      ],
      isFollowUp: true,
    );
  }

  if (hasWaitingForResponse) {
    return place(
      IssueSection.waitingOnAuthor,
      lastMemberCommentDate ?? issue.updatedDate,
      lastMemberCommentDate != null ? "the team's last comment" : 'the issue was last updated',
      (Urgency urgency) => switch (urgency) {
        Urgency.notYet => '',
        Urgency.due || Urgency.overdue => 'Ping @${issue.author}',
        Urgency.critical => 'Close as stale or ping @${issue.author}',
      },
      reasons: <String>['Labeled $primaryWaitingLabel'],
    );
  }

  if (priority != null && config.highPriorityLabels.contains(priority)) {
    final ownerStep = issue.assignees.isEmpty
        ? 'Assign an owner'
        : 'Check progress with ${issue.assignees.map((String a) => '@$a').join(', ')}';
    final bool isTopPriority =
        config.priorityLabels.isNotEmpty && priority == config.priorityLabels.first;
    return place(
      IssueSection.highPriority,
      issue.updatedDate,
      'the issue was last updated',
      (_) => ownerStep,
      reasons: <String>['Labeled $priority'],
      minimumUrgency: isTopPriority ? Urgency.critical : Urgency.due,
    );
  }

  if (isTeamLabeled) {
    return place(
      IssueSection.otherTeamIssues,
      issue.updatedDate,
      'the issue was last updated',
      (_) => '',
      reasons: <String>[
        'Labeled $effectiveTeamLabel'
            '${isTriaged ? ' and $effectiveTriagedLabel' : ''}'
            '${priority != null ? ' ($priority)' : ''}',
      ],
    );
  }

  // Generic fallback for repositories that do not use team/fyi labels: surface
  // community issues that have received no team response and have no triage or
  // priority label yet.
  if (!isTeamLabeled &&
      !isFyiLabeled &&
      !isTriaged &&
      !issue.labels.contains('triaged') &&
      priority == null &&
      issue.memberComment == null &&
      issue.authorType == ContributorType.community) {
    return place(
      IssueSection.untriaged,
      issue.creationDate,
      'the issue was opened',
      (_) => 'Triage issue',
      reasons: <String>['No team response or triage label yet'],
      minimumUrgency: Urgency.due,
    );
  }

  return null;
}
