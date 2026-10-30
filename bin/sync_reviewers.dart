// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pr_inspector/github_client.dart';
import 'package:pr_inspector/token.dart';
import 'package:pr_inspector/triage.dart';

final ArgParser _argParser = ArgParser()
  ..addOption(
    'config',
    abbr: 'c',
    help: 'Path to a single .dart config file (defaults to all configs/*.dart).',
    valueHelp: 'path',
  )
  ..addOption(
    'only',
    help: 'Only sync the named config in configs/ (e.g. ecosystem).',
    valueHelp: 'name',
  )
  ..addOption(
    'only-schedule',
    help: 'Only sync configs in configs/ matching this cron expression.',
    valueHelp: 'cron',
  )
  ..addOption(
    'from-file',
    help: 'Read the reviewers markdown from a local file instead of GitHub API.',
    valueHelp: 'path',
  )
  ..addFlag(
    'schedules-only',
    negatable: false,
    help:
        'Only sync refreshSchedule crons from configs/*.dart into .github/workflows/deploy_pages.yml.',
  )
  ..addFlag(
    'check',
    negatable: false,
    help: 'Exit with code 1 if teamMembers or workflow schedules differ without writing.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this usage information.');

Future<void> main(List<String> args) async {
  final ArgResults parsed;
  try {
    parsed = _argParser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}\n');
    stderr.writeln('Usage: dart run bin/sync_reviewers.dart [options]\n');
    stderr.writeln(_argParser.usage);
    exit(2);
  }

  if (parsed['help'] as bool) {
    stdout.writeln(
      'Syncs teamMembers in configs/*.dart with SUGGESTED_REVIEWERS.md and '
      'updates cron schedules in .github/workflows/deploy_pages.yml.\n',
    );
    stdout.writeln('Usage: dart run bin/sync_reviewers.dart [options]\n');
    stdout.writeln(_argParser.usage);
    return;
  }

  final checkOnly = parsed['check'] as bool;
  final schedulesOnly = parsed['schedules-only'] as bool;
  final fromFilePath = parsed['from-file'] as String?;
  final configOption = parsed['config'] as String?;
  final String? onlyConfig = (parsed['only'] as String?)?.trim();
  final String? onlySchedule = (parsed['only-schedule'] as String?)?.trim();

  final Directory configsDir = configsDirectoryFor(Platform.script);
  final List<File> configFiles;
  if (configOption != null) {
    final file = File(configOption);
    if (!file.existsSync()) {
      stderr.writeln('Error: Config file not found: ${file.path}');
      exit(2);
    }
    configFiles = <File>[file];
  } else {
    if (!configsDir.existsSync()) {
      stderr.writeln('Error: Configs directory not found: ${configsDir.path}');
      exit(2);
    }
    configFiles =
        configsDir.listSync().whereType<File>().where((File f) => f.path.endsWith('.dart')).toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
  }

  var anyOutOfSync = false;

  // Always sync workflow schedules in .github/workflows/deploy_pages.yml from configs/*.dart.
  if (configsDir.existsSync()) {
    final Map<String, TriageConfig> allConfigs = loadConfigsDirectory(configsDir);
    final workflowFile = File(
      '${configsDir.parent.path}${Platform.pathSeparator}'
      '.github${Platform.pathSeparator}workflows${Platform.pathSeparator}deploy_pages.yml',
    );
    if (workflowFile.existsSync()) {
      final String currentYaml = workflowFile.readAsStringSync();
      final String updatedYaml = updateWorkflowSchedulesInYaml(currentYaml, allConfigs);
      if (currentYaml != updatedYaml) {
        anyOutOfSync = true;
        if (checkOnly) {
          stdout.writeln('Δ ${workflowFile.path}: schedule crons differ from configs/*.dart.');
        } else {
          workflowFile.writeAsStringSync(updatedYaml);
          stdout.writeln('  Updated schedule crons in ${workflowFile.path}.');
        }
      }
    }
  }

  if (schedulesOnly) {
    if (checkOnly && anyOutOfSync) {
      exit(1);
    }
    return;
  }

  final GitHubToken? token = findToken(
    environment: Platform.environment,
    envFile: envFileFor(Platform.script),
  );
  final client = GitHubClient(token: token?.value ?? '');

  try {
    for (final configFile in configFiles) {
      final String stem = configFile.uri.pathSegments.last.replaceAll(RegExp(r'\.dart$'), '');
      if (onlyConfig != null && onlyConfig.isNotEmpty && stem != onlyConfig) {
        continue;
      }
      final TriageConfig config = parseDartConfigFile(configFile);
      if (onlySchedule != null &&
          onlySchedule.isNotEmpty &&
          config.refreshSchedule?.trim() != onlySchedule) {
        continue;
      }
      final String? rosterFile = config.rosterFile;
      if (rosterFile == null || rosterFile.isEmpty) {
        continue;
      }

      final int colonIndex = rosterFile.indexOf(':');
      final String targetRepo = colonIndex > 0
          ? rosterFile.substring(0, colonIndex)
          : config.repos.first;
      final String targetPath = colonIndex > 0 ? rosterFile.substring(colonIndex + 1) : rosterFile;

      final String markdown;
      if (fromFilePath != null) {
        markdown = File(fromFilePath).readAsStringSync();
      } else {
        final GitHubResponse response = await client.get(
          Uri.https('api.github.com', '/repos/$targetRepo/contents/$targetPath'),
        );
        final content = (response.json! as Map<String, dynamic>)['content']! as String;
        markdown = utf8.decode(base64.decode(content.replaceAll(RegExp(r'\s'), '')));
      }

      final List<String> latestMembers = extractSuggestedReviewerHandles(markdown);
      final List<String> currentMembers = config.teamMembers;

      final currentLower = <String>{for (final String m in currentMembers) m.toLowerCase()};
      final latestLower = <String>{for (final String m in latestMembers) m.toLowerCase()};
      final added = <String>[
        for (final String m in latestMembers)
          if (!currentLower.contains(m.toLowerCase())) m,
      ];
      final removed = <String>[
        for (final String m in currentMembers)
          if (!latestLower.contains(m.toLowerCase())) m,
      ];

      final bool exactMatch =
          currentMembers.length == latestMembers.length &&
          Iterable<int>.generate(
            currentMembers.length,
          ).every((int i) => currentMembers[i] == latestMembers[i]);

      if (exactMatch) {
        stdout.writeln(
          '✓ ${configFile.path}: teamMembers is up to date '
          '(${latestMembers.length} members from $targetRepo:$targetPath).',
        );
        continue;
      }

      anyOutOfSync = true;
      stdout.writeln('Δ ${configFile.path}: teamMembers differs from $targetRepo:$targetPath:');
      for (final handle in added) {
        stdout.writeln('  + @$handle');
      }
      for (final handle in removed) {
        stdout.writeln('  - @$handle');
      }

      if (!checkOnly) {
        final String updatedConfig = updateTeamMembersInDartConfig(
          configFile.readAsStringSync(),
          latestMembers,
        );
        configFile.writeAsStringSync(updatedConfig);
        stdout.writeln('  Updated ${configFile.path}.');

        if (configFile.uri.pathSegments.last == 'ecosystem.dart') {
          final defaultConfigFile = File(
            '${configFile.parent.parent.path}${Platform.pathSeparator}lib${Platform.pathSeparator}config.dart',
          );
          if (defaultConfigFile.existsSync()) {
            final String updatedDefault = updateTeamMembersInDartConfig(
              defaultConfigFile.readAsStringSync(),
              latestMembers,
            );
            defaultConfigFile.writeAsStringSync(updatedDefault);
            stdout.writeln('  Updated ${defaultConfigFile.path}.');
          }
        }
      }
    }
  } finally {
    client.close();
  }

  if (checkOnly && anyOutOfSync) {
    exit(1);
  }
}
