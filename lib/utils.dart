// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'types.dart';

/// Formats a date as YYYY-MM-DD, in local time.
String formatAsDay(DateTime date) {
  final DateTime local = date.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-${_twoDigits(local.month)}-'
      '${_twoDigits(local.day)}';
}

/// Formats a date as "YYYY-MM-DD HH:MM TZ", in local time.
String formatAsMinute(DateTime date) {
  final DateTime local = date.toLocal();
  return '${formatAsDay(local)} ${_twoDigits(local.hour)}:${_twoDigits(local.minute)} '
      '${local.timeZoneName}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// Whole days from [from] to [now], or 0 if [from] is in the future.
int daysBetween(DateTime from, DateTime now) {
  final int days = now.difference(from).inDays;
  return days < 0 ? 0 : days;
}

/// Returns the newest of [comments], ignoring nulls.
Comment? newestComment(List<Comment?> comments) {
  final List<Comment> nonNull = comments.whereType<Comment>().toList();
  nonNull.sort((a, b) => b.date.compareTo(a.date));
  return nonNull.firstOrNull;
}

/// The emoji used for [state].
String emojiForReviewState(ReviewState state) {
  return switch (state) {
    ReviewState.approved => '✅',
    ReviewState.changesRequested => '❌',
    ReviewState.pending => '🟠',
    ReviewState.commented => '💬',
  };
}

/// The emoji used for [type].
String emojiForContributorType(ContributorType type) {
  return switch (type) {
    ContributorType.member => '💼',
    ContributorType.bot => '🤖',
    ContributorType.community => '🌎',
  };
}

/// A reviewer and the review states to show for them.
typedef ReviewerEntry = ({String name, List<ReviewState> states});

// The order reviewers are listed in: whoever is holding the PR up first.
const List<ReviewState> _reviewerOrder = <ReviewState>[
  ReviewState.changesRequested,
  ReviewState.commented,
  ReviewState.pending,
  ReviewState.approved,
];

/// The reviewers of [pr] that have something to show, with blocking
/// reviewers first.
List<ReviewerEntry> reviewerEntries(PRInfo pr) {
  int rank(ReviewerEntry entry) =>
      entry.states.map(_reviewerOrder.indexOf).reduce((int a, int b) => a < b ? a : b);
  final entries = <ReviewerEntry>[
    for (final MapEntry<String, ReviewerStatus> reviewer in pr.reviewers.entries)
      if (reviewer.value.displayStates.isNotEmpty)
        (name: reviewer.key, states: reviewer.value.displayStates),
  ];
  entries.sort((ReviewerEntry a, ReviewerEntry b) {
    final int byState = rank(a).compareTo(rank(b));
    return byState != 0 ? byState : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

/// The emoji for each of [entry]'s states, followed by the reviewer's name.
String reviewerText(ReviewerEntry entry) =>
    '${entry.states.map(emojiForReviewState).join()} ${entry.name}';

/// The reviewers of [pr] as a single line, e.g. "❌ alice 🟠 bob ✅💬 carol".
String reviewersText(PRInfo pr) => reviewerEntries(pr).map(reviewerText).join('  ');
