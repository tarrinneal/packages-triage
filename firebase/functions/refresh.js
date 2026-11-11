'use strict';

const DEFAULT_COOLDOWN_MS = 5 * 60 * 1000;
const MIN_VALID_RUN_DURATION_MS = 20 * 1000;
const DEFAULT_WORKFLOW_FILE = 'deploy_pages.yml';
const DEFAULT_BRANCH = 'main';
const CONFIG_NAME_RE = /^[A-Za-z0-9_-]{1,64}$/;
const REPO_RE = /^[\w.-]+\/[\w.-]+$/;

/**
 * Validates an optional config name passed from the report page.
 * Returns null if empty/omitted, or throws an Error if invalid.
 */
function normalizeConfigName(raw) {
  if (raw === undefined || raw === null) {
    return null;
  }
  if (typeof raw !== 'string') {
    throw new Error('Config name must be a string.');
  }
  const trimmed = raw.trim();
  if (trimmed === '') {
    return null;
  }
  if (!CONFIG_NAME_RE.test(trimmed)) {
    throw new Error('Invalid config name.');
  }
  return trimmed;
}

/**
 * Inspects recent workflow runs to detect an active run or the latest
 * completed successful run (>20s duration, ignoring skipped runs).
 */
function analyzeWorkflowRuns(runs) {
  let activeRun = null;
  let lastSuccessUpdatedAtMs = 0;

  for (const run of runs) {
    if (!run || typeof run !== 'object') {
      continue;
    }
    if (!activeRun && run.status !== 'completed') {
      activeRun = run;
    }
    if (lastSuccessUpdatedAtMs === 0 && run.conclusion === 'success') {
      const startedMs = Date.parse(run.run_started_at || run.created_at || '') || 0;
      const updatedMs = Date.parse(run.updated_at || '') || 0;
      if (updatedMs - startedMs >= MIN_VALID_RUN_DURATION_MS) {
        lastSuccessUpdatedAtMs = updatedMs;
      }
    }
    if (activeRun && lastSuccessUpdatedAtMs > 0) {
      break;
    }
  }

  return { activeRun, lastSuccessUpdatedAtMs };
}

/**
 * Checks recent GitHub Actions runs and triggers workflow_dispatch if no run
 * is currently active and the cooldown has elapsed.
 */
async function triggerWorkflowRefresh({
  repo,
  token,
  config = null,
  workflowFile = DEFAULT_WORKFLOW_FILE,
  branch = DEFAULT_BRANCH,
  cooldownMs = DEFAULT_COOLDOWN_MS,
  nowMs = Date.now(),
  recentDispatches = new Map(),
  fetchImpl = fetch,
}) {
  if (!REPO_RE.test(repo || '')) {
    throw new Error(`Invalid workflow repo: ${repo}`);
  }
  if (!token) {
    throw new Error('Missing GitHub Actions token.');
  }

  const normalizedConfig = normalizeConfigName(config);
  const baseUrl = `https://api.github.com/repos/${repo}/actions/workflows/${workflowFile}`;
  const headers = {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${token}`,
    'User-Agent': 'packages-triage-firebase',
  };

  // Short-circuit in-memory bursts before GitHub lists the newly queued run.
  const localLastDispatch = recentDispatches.get(repo) || 0;
  if (localLastDispatch > 0 && nowMs - localLastDispatch < cooldownMs) {
    const remainingSec = Math.max(1, Math.ceil((cooldownMs - (nowMs - localLastDispatch)) / 1000));
    return {
      httpStatus: 429,
      body: {
        ok: false,
        status: 'cooldown',
        cooldownRemainingSeconds: remainingSec,
        retryAfterSeconds: remainingSec,
        nextAllowedAt: new Date(localLastDispatch + cooldownMs).toISOString(),
        lastRunAt: new Date(localLastDispatch).toISOString(),
      },
    };
  }

  const runsRes = await fetchImpl(`${baseUrl}/runs?per_page=10`, { headers });
  if (!runsRes.ok) {
    const detail = await runsRes.text().catch(() => '');
    throw new Error(`Failed to list workflow runs (HTTP ${runsRes.status}): ${detail}`);
  }
  const runsJson = await runsRes.json();
  const runs = Array.isArray(runsJson.workflow_runs) ? runsJson.workflow_runs : [];
  const { activeRun, lastSuccessUpdatedAtMs } = analyzeWorkflowRuns(runs);

  if (activeRun) {
    return {
      httpStatus: 200,
      body: {
        ok: true,
        status: 'running',
        alreadyRunning: true,
        runUrl: activeRun.html_url || `https://github.com/${repo}/actions/workflows/${workflowFile}`,
        startedAt: activeRun.run_started_at || activeRun.created_at || null,
      },
    };
  }

  if (lastSuccessUpdatedAtMs > 0 && nowMs - lastSuccessUpdatedAtMs < cooldownMs) {
    const remainingSec = Math.max(
      1,
      Math.ceil((cooldownMs - (nowMs - lastSuccessUpdatedAtMs)) / 1000),
    );
    return {
      httpStatus: 429,
      body: {
        ok: false,
        status: 'cooldown',
        cooldownRemainingSeconds: remainingSec,
        retryAfterSeconds: remainingSec,
        nextAllowedAt: new Date(lastSuccessUpdatedAtMs + cooldownMs).toISOString(),
        lastRunAt: new Date(lastSuccessUpdatedAtMs).toISOString(),
      },
    };
  }

  const payload = normalizedConfig
    ? { ref: branch, inputs: { config: normalizedConfig } }
    : { ref: branch };

  const dispatchRes = await fetchImpl(`${baseUrl}/dispatches`, {
    method: 'POST',
    headers: {
      ...headers,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });

  if (!dispatchRes.ok) {
    const detail = await dispatchRes.text().catch(() => '');
    throw new Error(`Failed to dispatch workflow (HTTP ${dispatchRes.status}): ${detail}`);
  }

  recentDispatches.set(repo, nowMs);

  return {
    httpStatus: 202,
    body: {
      ok: true,
      status: 'triggered',
      config: normalizedConfig,
      actionsUrl: `https://github.com/${repo}/actions/workflows/${workflowFile}`,
    },
  };
}

/**
 * Creates an HTTP request handler compatible with Firebase Functions v2 onRequest.
 */
function createRefreshHandler({
  getRepo,
  getToken,
  recentDispatches = new Map(),
  fetchImpl = fetch,
  now = () => Date.now(),
}) {
  return async (req, res) => {
    if (req.method !== 'POST') {
      res.set('Allow', 'POST');
      res.status(405).json({ ok: false, error: 'Method not allowed. Use POST.' });
      return;
    }

    let rawConfig = null;
    if (req.body && typeof req.body === 'object' && 'config' in req.body) {
      rawConfig = req.body.config;
    } else if (typeof req.body === 'string' && req.body.trim() !== '') {
      try {
        const parsed = JSON.parse(req.body);
        rawConfig = parsed && typeof parsed === 'object' ? parsed.config : null;
      } catch {
        res.status(400).json({ ok: false, error: 'Invalid JSON request body.' });
        return;
      }
    } else if (req.query && typeof req.query.config === 'string') {
      rawConfig = req.query.config;
    }

    try {
      normalizeConfigName(rawConfig);
    } catch (err) {
      res.status(400).json({ ok: false, error: err.message });
      return;
    }

    try {
      const result = await triggerWorkflowRefresh({
        repo: getRepo(),
        token: getToken(),
        config: rawConfig,
        nowMs: now(),
        recentDispatches,
        fetchImpl,
      });
      if (result.body.retryAfterSeconds) {
        res.set('Retry-After', String(result.body.retryAfterSeconds));
      }
      res.status(result.httpStatus).json(result.body);
    } catch (err) {
      console.error('Error refreshing triage workflow:', err);
      res.status(502).json({ ok: false, error: 'Failed to trigger GitHub Actions workflow.' });
    }
  };
}

module.exports = {
  DEFAULT_COOLDOWN_MS,
  MIN_VALID_RUN_DURATION_MS,
  analyzeWorkflowRuns,
  createRefreshHandler,
  normalizeConfigName,
  triggerWorkflowRefresh,
};
