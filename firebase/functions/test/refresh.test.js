'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  DEFAULT_COOLDOWN_MS,
  analyzeWorkflowRuns,
  createRefreshHandler,
  normalizeConfigName,
  triggerWorkflowRefresh,
} = require('../refresh');

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
    async text() {
      return JSON.stringify(body);
    },
  };
}

test('normalizeConfigName accepts valid config names and rejects unsafe input', () => {
  assert.equal(normalizeConfigName(null), null);
  assert.equal(normalizeConfigName('  '), null);
  assert.equal(normalizeConfigName('ecosystem'), 'ecosystem');
  assert.equal(normalizeConfigName('text_input'), 'text_input');
  assert.throws(() => normalizeConfigName('../bad'));
  assert.throws(() => normalizeConfigName(123));
});

test('analyzeWorkflowRuns finds active runs and skips short skipped runs', () => {
  const result = analyzeWorkflowRuns([
    {
      status: 'completed',
      conclusion: 'success',
      run_started_at: '2026-11-10T10:00:00Z',
      updated_at: '2026-11-10T10:00:05Z',
    },
    {
      status: 'completed',
      conclusion: 'success',
      run_started_at: '2026-11-10T09:00:00Z',
      updated_at: '2026-11-10T09:03:00Z',
    },
  ]);
  assert.equal(result.activeRun, null);
  assert.equal(result.lastSuccessUpdatedAtMs, Date.parse('2026-11-10T09:03:00Z'));
});

test('triggerWorkflowRefresh returns running when a workflow is active', async () => {
  const calls = [];
  const res = await triggerWorkflowRefresh({
    repo: 'tarrinneal/packages-triage',
    token: 'tok',
    config: 'ios',
    fetchImpl: async (url, opts) => {
      calls.push({ url, opts });
      return jsonResponse(200, {
        workflow_runs: [
          {
            status: 'in_progress',
            html_url: 'https://github.com/tarrinneal/packages-triage/actions/runs/99',
            run_started_at: '2026-11-10T10:00:00Z',
          },
        ],
      });
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(res.httpStatus, 200);
  assert.equal(res.body.alreadyRunning, true);
  assert.equal(res.body.status, 'running');
});

test('triggerWorkflowRefresh enforces cooldown from last successful run and local burst guard', async () => {
  const recentDispatches = new Map();
  const nowMs = Date.parse('2026-11-10T10:05:00Z');

  const cooldownRes = await triggerWorkflowRefresh({
    repo: 'tarrinneal/packages-triage',
    token: 'tok',
    nowMs,
    recentDispatches,
    fetchImpl: async () =>
      jsonResponse(200, {
        workflow_runs: [
          {
            status: 'completed',
            conclusion: 'success',
            run_started_at: '2026-11-10T10:00:00Z',
            updated_at: '2026-11-10T10:02:30Z',
          },
        ],
      }),
  });
  assert.equal(cooldownRes.httpStatus, 429);
  assert.equal(cooldownRes.body.status, 'cooldown');
  assert.equal(cooldownRes.body.cooldownRemainingSeconds, 150);

  let dispatchBody = null;
  const triggeredRes = await triggerWorkflowRefresh({
    repo: 'tarrinneal/packages-triage',
    token: 'tok',
    config: 'ecosystem',
    nowMs: nowMs + DEFAULT_COOLDOWN_MS,
    recentDispatches,
    fetchImpl: async (url, opts = {}) => {
      if (url.endsWith('/dispatches')) {
        dispatchBody = JSON.parse(opts.body);
        return jsonResponse(204, {});
      }
      return jsonResponse(200, { workflow_runs: [] });
    },
  });
  assert.equal(triggeredRes.httpStatus, 202);
  assert.equal(triggeredRes.body.status, 'triggered');
  assert.deepEqual(dispatchBody, { ref: 'main', inputs: { config: 'ecosystem' } });

  // Second immediate call hits the in-memory burst guard without calling GitHub.
  const burstRes = await triggerWorkflowRefresh({
    repo: 'tarrinneal/packages-triage',
    token: 'tok',
    nowMs: nowMs + DEFAULT_COOLDOWN_MS + 1000,
    recentDispatches,
    fetchImpl: async () => {
      throw new Error('Should not call GitHub during local burst cooldown');
    },
  });
  assert.equal(burstRes.httpStatus, 429);
  assert.equal(burstRes.body.status, 'cooldown');
});

test('createRefreshHandler handles POST, invalid methods, and invalid config names', async () => {
  const handler = createRefreshHandler({
    getRepo: () => 'tarrinneal/packages-triage',
    getToken: () => 'tok',
    fetchImpl: async (url) => {
      if (url.endsWith('/dispatches')) {
        return jsonResponse(204, {});
      }
      return jsonResponse(200, { workflow_runs: [] });
    },
  });

  function mockRes() {
    return {
      statusCode: 200,
      headers: {},
      body: null,
      set(k, v) {
        this.headers[k] = v;
      },
      status(code) {
        this.statusCode = code;
        return this;
      },
      json(payload) {
        this.body = payload;
      },
    };
  }

  const getRes = mockRes();
  await handler({ method: 'GET' }, getRes);
  assert.equal(getRes.statusCode, 405);

  const badConfigRes = mockRes();
  await handler({ method: 'POST', body: { config: 'bad/name' } }, badConfigRes);
  assert.equal(badConfigRes.statusCode, 400);

  const okRes = mockRes();
  await handler({ method: 'POST', body: { config: 'android' } }, okRes);
  assert.equal(okRes.statusCode, 202);
  assert.equal(okRes.body.config, 'android');
});
