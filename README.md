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

Once enabled, the report will be published at:
- `https://<owner>.github.io/<repo>/` (Community PRs)
- `https://<owner>.github.io/<repo>/index_team.html` (Team PRs)
- `https://<owner>.github.io/<repo>/index_issues.html` (Package Issues from `flutter/flutter`)

## Running it locally

Put a GitHub token in `.env` next to `pubspec.yaml` (which is gitignored), so that it has a line
like this:

```
GITHUB_TOKEN=github_pat_YOUR_TOKEN
```

A fine-grained token with read-only access to public repositories is enough. A `GITHUB_TOKEN`
environment variable, if set, takes precedence over the file.

Then run the tool with an output file. By default it inspects both `flutter/packages` and
`flutter/core-packages`; pass one or more `owner/repo` arguments to override.

```sh
dart run bin/pr_inspector.dart --html /tmp/triage.html --open
```

Or install it globally as a command-line tool:

```sh
dart pub global activate -s git https://github.com/<owner>/<repo>.git
GITHUB_TOKEN=github_pat_YOUR_TOKEN pr_inspector --html /tmp/triage.html --open
```

This writes three linked pages:

- `/tmp/triage.html`: PRs from community members and bots.
- `/tmp/triage_team.html`: PRs from team members.
- `/tmp/triage_issues.html`: Actionable package issues (`team-ecosystem` and `fyi-ecosystem` issues from `flutter/flutter`). Pass `--no-issues` to skip fetching issues.

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

The **Issues** page groups actionable `flutter/flutter` ecosystem issues into:
- **Untriaged (`team-ecosystem`)**: Open `team-ecosystem` issues missing `triaged-ecosystem` or a `P0`–`P3` priority label.
- **FYI Ecosystem (`fyi-ecosystem`)**: Open `fyi-ecosystem` issues missing `triaged-ecosystem`.
- **Waiting on team (author followed up)**: Open ecosystem issues where a team member commented and the issue reporter replied afterwards.
- **High priority (`P0` / `P1`)**: Open triaged `P0` and `P1` ecosystem issues.
- **Waiting on author (`waiting for response`)**: Open issues labeled `waiting for response` where the author has not replied since the team's last comment.

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

## Development

```sh
dart test
dart analyze
```
