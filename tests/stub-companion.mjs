#!/usr/bin/env node
// stub-companion.mjs — scripted stand-in for codex-companion.mjs (plan D7).
//
// Implements the subset of the companion contract that ultrablitz depends on
// (setup / task / status / result) so the whole orchestration seam can be
// driven in CI without Codex, an API key, or a network.
//
// Selected with ULTRABLITZ_COMPANION_OVERRIDE, honoured only when
// ULTRABLITZ_TEST=1. Scenario comes from STUB_SCENARIO; per-run counters live
// in STUB_STATE (a JSON file).
import fs from "node:fs";

const args = process.argv.slice(2);
const sub = args[0];
const scenario = process.env.STUB_SCENARIO || "happy";
const statePath = process.env.STUB_STATE || "/tmp/ultrablitz-stub-state.json";

const flag = (name) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? null : args[i + 1];
};
const has = (name) => args.includes(`--${name}`);

const readState = () => {
  try {
    return JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    return { turns: 0, jobs: {}, launches: 0, repairs: 0, prompts: [] };
  }
};
const writeState = (s) => fs.writeFileSync(statePath, JSON.stringify(s, null, 2));

const THREAD = "01a0-stub-thread-0001";
const ALT_THREAD = "01a0-stub-thread-9999";
const SESSION = "stub-claude-session";
const ALT_SESSION = "stub-other-session";

const validBody = (scores = [24, 18, 19, 15, 18], nCrit = 1) => {
  const names = [
    "Runtime contract fidelity & execution robustness",
    "Gate & safety integrity",
    "Verifiability & regression resistance",
    "Protocol coherence & drift resistance",
    "Operability & maintenance economics",
  ];
  const lines = names.map((n, i) => `- ${n}: ${scores[i]}`).join("\n");
  let crit = "";
  for (let i = 1; i <= nCrit; i++) {
    crit += `${i}. **[MAJOR]** Stub finding ${i}\n   - Evidence: stub evidence ${i}\n   - Impact: stub impact ${i}\n   - Suggestion: stub suggestion ${i}\n`;
  }
  if (nCrit === 0) crit = "- None.\n";
  return `## CATEGORY SCORES:\n${lines}\n\n## CRITIQUES:\n${crit}\n## STRENGTHS:\n- Stub strength.\n\n## VERDICT:\nStub verdict paragraph.`;
};

const malformedBody = "I have some thoughts about the plan but no structured sections here.";

// The account-refusal error shape recorded live on 2026-09-14 (codex 0.154.0).
const refusalError = (m) =>
  `{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The '${m}' model is not supported when using Codex with a ChatGPT account."}}`;
// A 400 whose shape ultrablitz does NOT recognise as a model refusal.
const weird400 = `{"type":"error","status":400,"error":{"type":"mystery_error","message":"upstream said no"}}`;

// Which body/thread/session/status this turn produces.
function turnResult(state, reqModel) {
  const n = state.turns; // 1-based after increment
  switch (scenario) {
    case "empty-output":
      return { status: 1, rawOutput: "", threadId: THREAD, sessionId: SESSION };
    case "model-refused":
      // The newest model is refused for this account; anything else works.
      if (reqModel === "gpt-6-astra") {
        return { status: 1, rawOutput: "", threadId: THREAD, sessionId: SESSION, errorText: refusalError(reqModel) };
      }
      return { status: 0, rawOutput: validBody(), threadId: THREAD, sessionId: SESSION };
    case "model-refused-all":
      return { status: 1, rawOutput: "", threadId: THREAD, sessionId: SESSION, errorText: refusalError(reqModel || "default") };
    case "model-refused-unknown-shape":
      // First model fails with a 400 ultrablitz does not recognise; the next works.
      if (n === 1) {
        return { status: 1, rawOutput: "", threadId: THREAD, sessionId: SESSION, errorText: weird400 };
      }
      return { status: 0, rawOutput: validBody(), threadId: THREAD, sessionId: SESSION };
    case "mismatch":
      return {
        status: 0,
        rawOutput: validBody(),
        threadId: n === 1 ? THREAD : ALT_THREAD,
        sessionId: SESSION,
      };
    case "session-mismatch":
      return {
        status: 0,
        rawOutput: validBody(),
        threadId: THREAD,
        sessionId: n === 1 ? SESSION : ALT_SESSION,
      };
    case "invalid-structure":
      // first turn malformed, repair turn (turn 2) valid
      return {
        status: 0,
        rawOutput: n === 1 ? malformedBody : validBody(),
        threadId: THREAD,
        sessionId: SESSION,
      };
    case "invalid-structure-persistent":
      return { status: 0, rawOutput: malformedBody, threadId: THREAD, sessionId: SESSION };
    case "repair-changed-substance":
      // malformed first; the "repair" is well formed but silently rescores
      return {
        status: 0,
        rawOutput:
          n === 1
            ? `## CATEGORY SCORES:\n- Runtime contract fidelity & execution robustness: 10\n- Gate & safety integrity: 10\n- Verifiability & regression resistance: 10\n- Protocol coherence & drift resistance: 10\n- Operability & maintenance economics: 10\n\n## CRITIQUES:\n1. **[MAJOR]** Stub finding 1\n   - Evidence: e\n   - Impact: i\n`
            : validBody([24, 18, 19, 15, 18], 1),
        threadId: THREAD,
        sessionId: SESSION,
      };
    case "out-of-bounds":
      return { status: 0, rawOutput: validBody([99, 18, 19, 15, 18]), threadId: THREAD, sessionId: SESSION };
    default:
      return { status: 0, rawOutput: validBody(), threadId: THREAD, sessionId: SESSION };
  }
}

if (sub === "setup") {
  process.stdout.write(
    JSON.stringify({ ready: true, node: { available: true }, codex: { available: true }, auth: { available: true, loggedIn: true } }, null, 2) + "\n",
  );
  process.exit(0);
}

if (sub === "task") {
  const state = readState();
  state.launches += 1;
  // Record argv so tests can assert which flags actually reached the companion.
  state.argv = state.argv || [];
  state.argv.push(args.join(" "));
  const promptFile = flag("prompt-file");
  if (promptFile) {
    try {
      state.prompts.push(fs.readFileSync(promptFile, "utf8"));
    } catch {
      /* ignore */
    }
  }
  const resuming = has("resume-last");

  // in-flight: the first resume attempt throws, like the real companion.
  if ((scenario === "inflight" && resuming && !state.inflightCleared) || scenario === "inflight-stuck") {
    if (scenario === "inflight") state.inflightCleared = true;
    state.jobs["task-stub-running"] = { id: "task-stub-running", status: "running" };
    writeState(state);
    process.stderr.write("Error: a Codex task is still running for this workspace.\n");
    process.exit(1);
  }

  state.turns += 1;
  const jobId = `task-stub-${state.turns}`;
  const r = turnResult(state, flag("model"));
  state.jobs[jobId] = {
    id: jobId,
    status: r.status === 0 ? "completed" : "failed",
    threadId: r.threadId,
    sessionId: r.sessionId,
    errorText: r.errorText || null,
    result: { status: r.status, threadId: r.threadId, rawOutput: r.rawOutput, touchedFiles: [], reasoningSummary: [] },
    // `timeout` scenario: the job never finishes.
    finished: scenario !== "timeout",
  };
  writeState(state);
  process.stdout.write(JSON.stringify({ jobId, status: "queued", title: "Codex Task" }) + "\n");
  process.exit(0);
}

if (sub === "status") {
  const state = readState();
  const jobId = args[1] && !args[1].startsWith("--") ? args[1] : null;
  const running = Object.values(state.jobs).filter((j) => j.status === "running" || j.finished === false);
  if (!jobId) {
    process.stdout.write(
      JSON.stringify({ workspaceRoot: flag("cwd") || process.cwd(), running, latestFinished: null, recent: [] }, null, 2) + "\n",
    );
    process.exit(0);
  }
  const job = state.jobs[jobId];
  if (!job) {
    process.stderr.write(`no such job ${jobId}\n`);
    process.exit(1);
  }
  if (job.finished === false) {
    // --wait times out without completing
    process.stdout.write(JSON.stringify({ id: jobId, status: "running", phase: "running", timedOut: true }, null, 2) + "\n");
    process.exit(0);
  }
  process.stdout.write(JSON.stringify({ id: jobId, status: job.status, phase: "done", threadId: job.threadId }, null, 2) + "\n");
  process.exit(0);
}

if (sub === "result") {
  const state = readState();
  const jobId = args[1] && !args[1].startsWith("--") ? args[1] : Object.keys(state.jobs).pop();
  const job = state.jobs[jobId];
  if (!job || job.finished === false) {
    // Nothing to return yet — mirrors a timed-out wait.
    process.stdout.write(JSON.stringify({ job: { id: jobId, status: "running" } }, null, 2) + "\n");
    process.exit(0);
  }
  process.stdout.write(
    JSON.stringify(
      {
        job: { id: jobId, status: job.status, phase: "done", threadId: job.threadId, sessionId: job.sessionId, summary: job.errorText || (job.result.rawOutput ? "ok" : "no output") },
        storedJob: { id: jobId, sessionId: job.sessionId, result: job.result, rendered: job.result.rawOutput },
      },
      null,
      2,
    ) + "\n",
  );
  process.exit(0);
}

process.stderr.write(`stub-companion: unknown subcommand ${sub}\n`);
process.exit(2);
