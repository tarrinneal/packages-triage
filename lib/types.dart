// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The subset of review states that we want to display.
enum ReviewState {
  /// The reviewer approved the PR.
  approved,

  /// The reviewer requested changes.
  changesRequested,

  /// The reviewer's review has been requested and they haven't reviewed since.
  pending,

  /// The reviewer left a comment review.
  commented,
}

/// Who opened a PR.
enum ContributorType {
  /// A member of the team.
  member,

  /// An automated account.
  bot,

  /// Anyone else.
  community,
}

/// A comment, review, or review comment: who left it and when.
typedef Comment = ({String username, DateTime date});

/// What one team reviewer has done on a PR.
class ReviewerStatus {
  /// The reviewer's latest approval or change request, if it is still in
  /// force.
  ReviewState? decision;

  /// When [decision] was made.
  DateTime? decisionDate;

  /// Whether the reviewer has left a comment review since [decision].
  bool commented = false;

  /// Whether the reviewer's review is currently requested.
  bool requested = false;

  /// The states to show for this reviewer.
  ///
  /// A comment review doesn't cancel an earlier approval or change request,
  /// so both are shown. An open review request means everything else is older
  /// than the request, so only the request is shown.
  List<ReviewState> get displayStates => requested
      ? const <ReviewState>[ReviewState.pending]
      : <ReviewState>[?decision, if (commented) ReviewState.commented];
}

/// Everything the tool knows about a PR.
class PRInfo {
  /// Creates a PR with no comment or review data.
  PRInfo({
    required this.number,
    required this.author,
    required this.title,
    required this.url,
    required this.creationDate,
    required this.updatedDate,
    required this.authorType,
    required this.isDraft,
    this.repo = '',
    this.authorTypeFromRoster = false,
    this.labels = const <String>[],
  });

  /// The PR number.
  final int number;

  /// The repository (`owner/name`) this PR belongs to, if known.
  final String repo;

  /// The PR author's login.
  final String author;

  /// The PR title.
  final String title;

  /// The PR's web URL.
  final String url;

  /// When the PR was opened.
  final DateTime creationDate;

  /// When anything about the PR last changed, according to GitHub.
  final DateTime updatedDate;

  /// Who opened the PR.
  final ContributorType authorType;

  /// Whether [authorType] is [ContributorType.member] only because the author
  /// is in the team roster, rather than because of GitHub's
  /// `author_association`.
  final bool authorTypeFromRoster;

  /// Whether the PR is a draft.
  final bool isDraft;

  /// The PR's label names.
  final List<String> labels;

  /// The PR author's newest comment, if comments were fetched.
  Comment? authorComment;

  /// The PR author's earliest comment after [memberComment], if the author
  /// has replied since the team's last comment.
  ///
  /// Used to time how long a follow-up has been waiting on the team so that
  /// later pings from the author don't reset their waiting time.
  Comment? authorFollowUpComment;

  /// The newest comment from a team member other than the author.
  Comment? memberComment;

  /// The newest comment from anyone else.
  Comment? nonMemberComment;

  /// Team reviewers, by login.
  final Map<String, ReviewerStatus> reviewers = <String, ReviewerStatus>{};

  /// Whether comments and reviews were fetched for this PR.
  ///
  /// They are skipped for PRs whose placement doesn't depend on them, such as
  /// drafts.
  bool hasDetails = false;

  /// Descriptions of any data that failed to load.
  final List<String> fetchErrors = <String>[];

  /// The number of reviewers in each displayed state.
  Map<ReviewState, int> get reviewStateCount {
    final counts = <ReviewState, int>{};
    for (final ReviewerStatus status in reviewers.values) {
      for (final ReviewState state in status.displayStates) {
        counts[state] = (counts[state] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// The number of approvals currently in force.
  int get approvalCount => reviewStateCount[ReviewState.approved] ?? 0;

  /// When the earliest approval currently in force was given.
  DateTime? get firstApprovalDate {
    DateTime? first;
    for (final ReviewerStatus status in reviewers.values) {
      final DateTime? date = status.decisionDate;
      if (status.displayStates.contains(ReviewState.approved) &&
          date != null &&
          (first == null || date.isBefore(first))) {
        first = date;
      }
    }
    return first;
  }
}

/// The report pages.
enum ReportPage {
  /// PRs opened by community members and bots.
  community,

  /// PRs opened by team members.
  team,
}

/// The report sections, in display order.
enum Section {
  /// PRs whose data couldn't be loaded, so they can't be placed.
  loadError,

  /// Community PRs that need a (or a second) reviewer.
  needsReviewer,

  /// PRs where the team needs to act next.
  waitingOnTeam,

  /// PRs where the author needs to act next.
  waitingOnAuthor,

  /// PRs opened by bots.
  bots,

  /// Draft PRs.
  drafts,
}

/// How overdue a PR is for attention.
enum Urgency {
  /// Not due yet.
  notYet,

  /// Due for attention.
  due,

  /// Overdue.
  overdue,

  /// Very overdue.
  critical,
}

/// Where a PR belongs in the report, and why.
class PRAnalysis {
  /// Creates an analysis of [pr].
  PRAnalysis({
    required this.pr,
    required this.page,
    required this.section,
    required this.waitingSince,
    required this.waitingDays,
    required this.urgency,
    required this.nextStep,
    required this.reasons,
    this.isFollowUp = false,
  });

  /// The PR.
  final PRInfo pr;

  /// The page the PR is shown on.
  final ReportPage page;

  /// The section the PR is shown in.
  final Section section;

  /// When whoever needs to act next got the PR.
  final DateTime waitingSince;

  /// Whole days since [waitingSince].
  final int waitingDays;

  /// How overdue the PR is.
  final Urgency urgency;

  /// What a triager should do, or an empty string if nothing is needed yet.
  final String nextStep;

  /// Why the PR was placed where it was, for display.
  final List<String> reasons;

  /// Whether a team member commented on this PR, the author replied afterwards,
  /// and the PR is now waiting on the team for a follow-up.
  final bool isFollowUp;
}

/// Everything the tool knows about a GitHub issue.
class IssueInfo {
  /// Creates an issue with no comment data.
  IssueInfo({
    required this.number,
    required this.author,
    required this.title,
    required this.url,
    required this.creationDate,
    required this.updatedDate,
    required this.authorType,
    this.labels = const <String>[],
    this.assignees = const <String>[],
    this.commentCount = 0,
  });

  /// The issue number.
  final int number;

  /// The issue author's login.
  final String author;

  /// The issue title.
  final String title;

  /// The issue's web URL.
  final String url;

  /// When the issue was opened.
  final DateTime creationDate;

  /// When anything about the issue last changed, according to GitHub.
  final DateTime updatedDate;

  /// Who opened the issue.
  final ContributorType authorType;

  /// The issue's label names.
  final List<String> labels;

  /// Logins of users assigned to the issue.
  final List<String> assignees;

  /// Total number of comments reported by GitHub's issue listing.
  final int commentCount;

  /// The issue author's newest comment, if comments were fetched.
  Comment? authorComment;

  /// The issue author's earliest comment after [memberComment], if the author
  /// has replied since the team's last comment.
  Comment? authorFollowUpComment;

  /// The newest comment from a team member other than the author.
  Comment? memberComment;

  /// The newest comment from anyone else.
  Comment? nonMemberComment;

  /// Whether comments were fetched for this issue.
  bool hasDetails = false;

  /// Descriptions of any data that failed to load.
  final List<String> fetchErrors = <String>[];
}

/// The sections of the package issues triage page, in display order.
enum IssueSection {
  /// Issues whose data couldn't be loaded.
  loadError,

  /// Open `team-ecosystem` issues that haven't been triaged yet.
  untriaged,

  /// Open `fyi-ecosystem` issues flagged for the ecosystem team's attention.
  fyiEcosystem,

  /// Issues where a team member commented, the author replied, and the issue
  /// is now waiting on the team.
  waitingOnTeam,

  /// Open `P0` or `P1` `team-ecosystem` issues.
  highPriority,

  /// Open `team-ecosystem` issues labeled `waiting for response`.
  waitingOnAuthor,
}

/// Where an issue belongs on the issues triage page, and why.
class IssueAnalysis {
  /// Creates an analysis of [issue].
  IssueAnalysis({
    required this.issue,
    required this.section,
    required this.waitingSince,
    required this.waitingDays,
    required this.urgency,
    required this.nextStep,
    required this.reasons,
    this.isFollowUp = false,
  });

  /// The issue.
  final IssueInfo issue;

  /// The section the issue is shown in.
  final IssueSection section;

  /// When whoever needs to act next got the issue.
  final DateTime waitingSince;

  /// Whole days since [waitingSince].
  final int waitingDays;

  /// How overdue the issue is.
  final Urgency urgency;

  /// What a triager should do, or an empty string if nothing is needed yet.
  final String nextStep;

  /// Why the issue was placed where it was, for display.
  final List<String> reasons;

  /// Whether a team member commented on this issue and the author replied
  /// afterwards.
  final bool isFollowUp;
}
