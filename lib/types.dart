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

  /// All other open `team-ecosystem` issues (such as triaged `P2`/`P3` issues).
  otherTeamIssues,
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

/// Default repositories inspected when none are passed on the command line.
const List<String> defaultRepos = <String>['flutter/packages', 'flutter/core-packages'];

/// Default weekly cron expression (`'37 19 * * 2'`) used to refresh a page's
/// report in GitHub Actions.
const String defaultRefreshSchedule = '37 19 * * 2';

/// Default repository where issues are tracked for [defaultRepos].
const String defaultIssuesRepo = 'flutter/flutter';

/// Default repository used by the in-page "Refresh report" button to trigger
/// the GitHub Actions workflow when not hosted on `*.github.io`.
const String defaultWorkflowRepo = 'tarrinneal/packages-triage';

/// Default file in each repository used to discover team members and suggested
/// package reviewers.
const String defaultRosterFile = 'SUGGESTED_REVIEWERS.md';

/// Default automated accounts that do not have GitHub user type `Bot` or a
/// `[bot]` suffix.
const Set<String> defaultBotAccounts = <String>{'fluttergithubbot', 'engine-flutter-autoroll'};

/// Default number of approvals a community PR needs before it is no longer
/// flagged as missing a reviewer.
const int defaultRequiredApprovals = 2;

/// PRs with any of these labels are hidden by default, since another triage
/// rotation handles them.
const Set<String> defaultHiddenLabels = <String>{'triage-design'};

/// Default label shown on the filter chip for PRs that do not have any of
/// [defaultHiddenLabels].
const String defaultNonHiddenFilterLabel = 'triage-packages';

/// Default label prefixes considered routing/display labels on PRs and issues.
const List<String> defaultRoutingLabelPrefixes = <String>['p: ', 'platform-', 'triage-'];

/// Default prefix used to match package labels against [defaultRosterFile].
const String defaultPackageLabelPrefix = 'p: ';

/// Labels indicating that an item is waiting on a response from the author.
const Set<String> defaultWaitingForResponseLabels = <String>{
  'waiting for response',
  'waiting-for-response',
  'waiting for customer response',
};

/// Default primary label identifying issues owned by the team.
const String defaultIssueTeamLabel = 'team-ecosystem';

/// Default secondary label identifying FYI issues for the team.
const String defaultIssueFyiLabel = 'fyi-ecosystem';

/// Default label indicating that an issue has been triaged by the team.
const String defaultIssueTriagedLabel = 'triaged-ecosystem';

/// Priority labels used on `flutter/flutter` issues, in descending priority
/// order.
const List<String> defaultPriorityLabels = <String>['P0', 'P1', 'P2', 'P3'];

/// Priority labels considered high priority on the issues page.
const Set<String> defaultHighPriorityLabels = <String>{'P0', 'P1'};

const String _deriveFromTeam = '\x00derive_from_flutter_team';

/// Configuration for repositories, labels, and roster lookup in the triage
/// tool.
///
/// Edit `defaultConfig` in `lib/config.dart` to customize the tool for your
/// team or repositories.
class TriageConfig {
  /// Creates a configuration with the given settings.
  ///
  /// Setting [flutterTeam] (for example `'ecosystem'`, `'ios'`, or `'web'`)
  /// automatically sets [issueTeamLabel] to `'team-<flutterTeam>'`,
  /// [issueFyiLabel] to `'fyi-<flutterTeam>'`, and [issueTriagedLabel] to
  /// `'triaged-<flutterTeam>'` unless those fields are explicitly overridden.
  const TriageConfig({
    this.repos = defaultRepos,
    this.flutterTeam = 'ecosystem',
    this.refreshSchedule = defaultRefreshSchedule,
    this.teamMembers = const <String>[],
    this.prLabels = const <String>{},
    this.issuesRepo = defaultIssuesRepo,
    this.workflowRepo = defaultWorkflowRepo,
    String? rosterFile = _deriveFromTeam,
    this.botAccounts = defaultBotAccounts,
    this.requiredApprovals = defaultRequiredApprovals,
    Set<String>? hiddenLabels,
    this.nonHiddenFilterLabel = defaultNonHiddenFilterLabel,
    this.routingLabelPrefixes = defaultRoutingLabelPrefixes,
    this.packageLabelPrefix = defaultPackageLabelPrefix,
    this.showAllLabels = false,
    this.waitingForResponseLabels = defaultWaitingForResponseLabels,
    String? issueTeamLabel = _deriveFromTeam,
    String? issueFyiLabel = _deriveFromTeam,
    String? issueTriagedLabel = _deriveFromTeam,
    this.priorityLabels = defaultPriorityLabels,
    this.highPriorityLabels = defaultHighPriorityLabels,
  }) : _rosterFile = rosterFile,
       _hiddenLabels = hiddenLabels,
       _issueTeamLabel = issueTeamLabel,
       _issueFyiLabel = issueFyiLabel,
       _issueTriagedLabel = issueTriagedLabel;

  /// Default repositories to inspect for open PRs when none are specified on
  /// the command line.
  final List<String> repos;

  /// Short Flutter team name (such as `'ecosystem'`, `'ios'`, or `'android'`)
  /// used to derive `team-<name>`, `fyi-<name>`, and `triaged-<name>` issue
  /// labels when not explicitly set, or `null` for non-Flutter repositories.
  final String? flutterTeam;

  /// Standard 5-field UTC cron expression specifying when this config's page
  /// and reviewer list should be refreshed automatically in GitHub Actions, or
  /// `null` to disable scheduled refreshes for this config.
  final String? refreshSchedule;

  /// GitHub usernames of team members to include in the team roster.
  final List<String> teamMembers;

  /// If non-empty, only open PRs carrying at least one of these labels are
  /// included in the report.
  final Set<String> prLabels;

  /// Repository where issues are tracked for [repos], or `null` to default to
  /// the PR repository itself.
  final String? issuesRepo;

  /// Repository (`owner/repo`) that hosts the `deploy_pages.yml` GitHub
  /// Actions workflow for the in-page "Refresh report" button.
  final String workflowRepo;

  final String? _rosterFile;

  /// Markdown file listing team reviewers and package reviewer mappings.
  ///
  /// Can be a repository-qualified path (`'owner/repo:path/to/file.md'`), a
  /// path relative to each inspected PR repository (`'SUGGESTED_REVIEWERS.md'`),
  /// or `null` to disable fetching a roster file (falling back to `CODEOWNERS`).
  String? get rosterFile => identical(_rosterFile, _deriveFromTeam)
      ? (flutterTeam == 'ecosystem' ? defaultRosterFile : null)
      : (_rosterFile != null && _rosterFile.isEmpty ? null : _rosterFile);

  /// Logins of automated accounts that should be treated as bots even if
  /// GitHub does not report their `type` as `Bot`.
  final Set<String> botAccounts;

  /// Number of approvals a community PR needs before it is no longer flagged
  /// as missing a reviewer.
  final int requiredApprovals;

  final Set<String>? _hiddenLabels;

  /// PR labels that start out hidden by default on the report.
  Set<String> get hiddenLabels =>
      _hiddenLabels ?? (flutterTeam == 'ecosystem' ? defaultHiddenLabels : const <String>{});

  /// Label displayed on the filter toggle chip for PRs without [hiddenLabels].
  final String nonHiddenFilterLabel;

  /// Label prefixes displayed as chips on PR and issue rows.
  final List<String> routingLabelPrefixes;

  /// Label prefix used to look up package reviewer tooltips from [rosterFile].
  final String packageLabelPrefix;

  /// Whether to display all non-CLA labels as chips on PR and issue rows.
  final bool showAllLabels;

  /// Labels indicating that a PR or issue is waiting on the author's response.
  final Set<String> waitingForResponseLabels;

  final String? _issueTeamLabel;
  final String? _issueFyiLabel;
  final String? _issueTriagedLabel;

  /// Primary label identifying issues belonging to the team on the issues
  /// page, or `null` if the repository does not filter issues by a team label.
  String? get issueTeamLabel => identical(_issueTeamLabel, _deriveFromTeam)
      ? (flutterTeam != null ? 'team-$flutterTeam' : null)
      : _issueTeamLabel;

  /// Secondary label identifying FYI issues on the issues page, or `null` if
  /// the team does not use an FYI label.
  String? get issueFyiLabel => identical(_issueFyiLabel, _deriveFromTeam)
      ? (flutterTeam != null ? 'fyi-$flutterTeam' : null)
      : _issueFyiLabel;

  /// Label indicating that an issue has been triaged by the team.
  String get issueTriagedLabel => identical(_issueTriagedLabel, _deriveFromTeam)
      ? (flutterTeam != null ? 'triaged-$flutterTeam' : 'triaged')
      : (_issueTriagedLabel ?? '');

  /// Priority labels in descending priority order (e.g. `['P0', 'P1', 'P2', 'P3']`).
  final List<String> priorityLabels;

  /// Priority labels that should be shown in the high-priority issues section
  /// even after being triaged (e.g. `{'P0', 'P1'}`).
  final Set<String> highPriorityLabels;

  /// Priority labels that are not in [highPriorityLabels] (e.g. `['P2', 'P3']`).
  List<String> get lowPriorityLabels =>
      priorityLabels.where((String p) => !highPriorityLabels.contains(p)).toList();
}
