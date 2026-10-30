This is a prototype for a PR triage tool. It classifies open PRs by whose turn it is to act next
(the Flutter team or the PR author), sorts them by how long they have been waiting on whoever needs
to act, and flags PRs that are missing reviewers.

## Hosting on GitHub Pages

This repository includes [`.github/workflows/deploy_pages.yml`](.github/workflows/deploy_pages.yml),
which builds the HTML report every Tuesday at 12:37 PM Pacific so it is ready before 1:00 PM Pacific
(and on pushes to `main`, manual **Run workflow** triggers, or the in-page **Refresh report**
button, rate-limited to once every 5 minutes) and publishes it to GitHub Pages.

To enable it on a standalone repository:
1. Go to **Settings → Pages**.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.
3. *(Optional, for other repositories)* Edit [`triage.yaml`](triage.yaml) (or set `TRIAGE_REPOS` in **Settings → Secrets and variables → Actions → Variables**) to configure repositories and labels.

Once enabled, the report will be published at:
- `https://<owner>.github.io/<repo>/` (Community PRs)
- `https://<owner>.github.io/<repo>/index_team.html` (Team PRs)
- `https://<owner>.github.io/<repo>/index_issues.html` (Actionable Issues)

## Configuration (`triage.yaml`)

By default, the tool reads [`triage.yaml`](triage.yaml) next to `pubspec.yaml` (or a custom file
passed with `--config <file>` / `-c <file>`). Every field is optional and defaults to the Flutter
Ecosystem triage settings when omitted:

- `repos`: PR repositories to inspect (`flutter/packages` and `flutter/core-packages` by default).
- `issues_repo`: Repository where issues are tracked (`flutter/flutter` by default; set to `null` or `""` to use the first PR repository).
- `workflow_repo`: Repository hosting the GitHub Actions refresh workflow (`tarrinneal/packages-triage` by default).
- `roster_file`: Markdown file in the PR repository listing team reviewers (`SUGGESTED_REVIEWERS.md` by default; falls back to `CODEOWNERS`).
- `bot_accounts`: Logins treated as bots in addition to `[bot]` accounts.
- `required_approvals`: Number of approvals a community PR needs before it is no longer missing a reviewer (`2` by default).
- `hidden_labels`: PR labels hidden by default unless `--show-hidden` or the UI toggle is used (`triage-design` by default).
- `non_hidden_filter_label`: Label that keeps a PR visible even when it also has a hidden label (`triage-packages` by default).
- `routing_label_prefixes` / `package_label_prefix` / `show_all_labels`: Label prefixes shown as badges on PR and issue rows (`p: `, `platform-`, `triage-` by default).
- `waiting_for_response_labels`: Labels indicating an issue is waiting on the author (`waiting for response`, `waiting for customer response`).
- `issue_team_label`, `issue_fyi_label`, `issue_triaged_label`: Issue triage labels (`team-ecosystem`, `fyi-ecosystem`, `triaged-ecosystem` by default).
- `priority_labels` / `high_priority_labels`: Issue priority labels (`P0`–`P3` and `P0`–`P1` by default).

## Running it locally

The tool looks for a GitHub token in this order:
1. The `GITHUB_TOKEN` (or `GH_TOKEN`) environment variable.
2. A `GITHUB_TOKEN=github_pat_YOUR_TOKEN` line in `./.env` (current directory), the `.env` next to `pubspec.yaml`, or `~/.config/pr_inspector/.env`.
3. The GitHub CLI (`gh auth token`), if you are logged in with `gh auth login`.

A fine-grained token with read-only access to public repositories is enough.

Then run the tool with an output file. By default it inspects the repositories in `triage.yaml`
(`flutter/packages` and `flutter/core-packages`); pass `--config <file>` or one or more
`owner/repo` arguments to inspect any GitHub repository:

```sh
dart run bin/pr_inspector.dart --html /tmp/triage.html --open
dart run bin/pr_inspector.dart --config my_triage.yaml --html /tmp/triage.html --open
dart run bin/pr_inspector.dart owner/repo --html /tmp/triage.html --open
```

Or install it globally as a command-line tool:

```sh
dart pub global activate -s git https://github.com/<owner>/<repo>.git
pr_inspector owner/repo --html /tmp/triage.html --open
```

When inspecting non-`flutter/*` repositories without a custom config file, the tool automatically:
- Requires 1 approval instead of 2 for community PRs (override with `--required-approvals <n>`).
- Displays all PR and issue labels on rows (instead of only Flutter routing labels).
- Falls back to `.github/CODEOWNERS` / `CODEOWNERS` when `SUGGESTED_REVIEWERS.md` is not present.
- Triages open issues generically when `--team-label` is not set.

This writes three linked pages:

- `/tmp/triage.html`: PRs from community members and bots.
- `/tmp/triage_team.html`: PRs from team members.
- `/tmp/triage_issues.html`: Actionable issues (`team-ecosystem` and `fyi-ecosystem` issues from `flutter/flutter` by default, or open untriaged/follow-up issues on other repositories). Pass `--no-issues` to skip fetching issues.

Without `--html`, the same report is printed as text.

## Reading the report

Each PR page is split into sections, in this order:

| Section | Meaning |
|---|---|
| Failed to load | Some data couldn't be fetched, so the PR isn't sorted. Rerun to retry. |
| Needs reviewer | Community PR with no engaged reviewer and fewer than two approvals. |
| Waiting on team | The team needs to act next. Timed from the author's earliest follow-up after the team's last comment (or the author's last comment if the team hasn't commented yet). (On the team page: "Waiting on reviewer".) |
| Waiting on author | The author needs to act next. Timed from the team's last comment. |
| Bots | PRs opened by bots (collapsed). |
| Drafts | Draft PRs, timed from their last update (collapsed). |

PRs and issues where a team member commented/reviewed and the contributor replied afterwards are
marked with a **`FOLLOW-UP`** badge, prioritized ahead of non-follow-ups at the same urgency tier,
and can be filtered using the **Follow-up PRs** / **Follow-up issues** toggle button in the header.
Their waiting time is measured from the contributor's *first* follow-up reply after the team's last
comment, so subsequent "friendly ping" comments by the contributor do not reset their wait time.

The **Issues** page groups `flutter/flutter` ecosystem issues into:
- **Untriaged (`team-ecosystem`)**: Open `team-ecosystem` issues missing `triaged-ecosystem` or a `P0`–`P3` priority label.
- **FYI Ecosystem (`fyi-ecosystem`)**: Open `fyi-ecosystem` issues missing `triaged-ecosystem`.
- **Waiting on team (author followed up)**: Open ecosystem issues where a team member commented and the issue reporter replied afterwards.
- **High priority (`P0` / `P1`)**: Open triaged `P0` and `P1` ecosystem issues.
- **Waiting on author (`waiting for response`)**: Open issues labeled `waiting for response` where the author has not replied since the team's last comment.
- **Other (`team-ecosystem`)**: All other open `team-ecosystem` issues (such as already-triaged `P2` and `P3` issues).

Within a section, items that have waited longest come first. Waiting times are colored by urgency:
due at 7 days, overdue at 14, and critical at 30. Community PRs that have waited 30 days on their
author, and community drafts idle for 30 days, are suggested for closing. The **Next step** column
says what to do, and hovering over a waiting time shows why the PR is in its section.

PRs labeled `triage-design` are hidden by default, since they are triaged separately. Use the
button at the top of each page to show them (the choice is remembered), or pass `--show-hidden`.

PRs are marked **NEW** if they weren't in the previous report, and **MOVED** if they changed
section. This uses a `<file name>.state.json` file written next to the report, so it compares
against the last full run that used the same output file.

Team membership comes from GitHub's `author_association`, plus anyone in `SUGGESTED_REVIEWERS.md`
or with a pending review request, since GitHub hides private org membership.

## Caching

Fetching every PR's comments and reviews is most of the work, so the tool saves them in your
user cache directory, outside the repository:

- macOS: `~/Library/Caches/pr_inspector/`
- Linux: `$XDG_CACHE_HOME/pr_inspector/` (usually `~/.cache/pr_inspector/`)
- Windows: `%LOCALAPPDATA%\pr_inspector\`

Later runs reuse the saved data for any PR whose `updated_at` hasn't changed, so they only fetch
PRs with new activity. Each time a run sees a PR open, changed or not, the PR's data is kept
for another 7 days; once a PR hasn't been seen open for 7 days (for example, because it was
merged), its data is removed. Who counts as the team is still decided fresh on every run.

## Other options

- `--pr <number>`: Explain how a single PR is triaged, and why. This always fetches fresh data.
- `--limit <n>`: Only analyze the `n` newest open PRs, for quick checks. This also works without a
  token, within GitHub's limit of 60 requests per hour.
- `--refresh`: Fetch every PR's comments and reviews again instead of reusing saved ones.
- `--record <file>` / `--replay <file>`: Save every GitHub response, then rerun from the saved
  responses without calling GitHub, which is useful when changing the sorting or the output. Replay
  with the same `--limit` or `--pr` that was recorded. Recording fetches everything rather than
  using the cache, and replays leave the cache alone.

Run `dart run bin/pr_inspector.dart --help` for everything else.

## Development & Deploying

```sh
dart test
dart analyze
```

To format, analyze, test, commit changes in `script/triage`, push to `origin`, and deploy the
`script/triage` directory to the standalone GitHub Pages repository (`workflow_repo` in
`triage.yaml`, defaulting to `tarrinneal/packages-triage`):

```sh
./script/triage/deploy.sh "Your commit message"
```

Pass `--skip-checks` to skip formatting/tests, `--repo <owner/repo>` to override the target
repository, or `--dry-run` to preview what would be pushed.

