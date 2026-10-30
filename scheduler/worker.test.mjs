// scheduler/worker.js 단위 테스트 — 네트워크 호출 없음(fetch 는 전부 가짜).
//   node --test scheduler/worker.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

// 🔴 네트워크 차단: 가짜를 안 넘긴 경로가 있으면 진짜 fetch 대신 여기서 실패한다(실제 GitHub dispatch 방지)
const realFetch = globalThis.fetch;
globalThis.fetch = async (url) => { throw new Error(`테스트 중 실제 fetch 호출 차단: ${url}`); };

const worker = await import("./worker.js");
const { planDispatches, dispatch, fullEveryHours, UPTIME_CRON, BRIEF_CRON } = worker;

const at = (hhmm, day = "2026-11-02") => Date.parse(`${day}T${hhmm}:00Z`);
const mode = (hhmm, env) => planDispatches(UPTIME_CRON, at(hhmm), env)[0].inputs.mode;
const quiet = (fn) => async (...a) => {   // console.error/log 를 잡아 테스트 출력을 깨끗이 + 검사용으로 돌려줌
  const logs = []; const oe = console.error; const ol = console.log;
  console.error = (...x) => logs.push(["error", x.join(" ")]); console.log = (...x) => logs.push(["log", x.join(" ")]);
  try { return await fn(logs, ...a); } finally { console.error = oe; console.log = ol; }
};

test("가드: 실제 fetch 는 차단돼 있다", async () => {
  assert.notEqual(globalThis.fetch, realFetch);
  await assert.rejects(() => globalThis.fetch("https://api.github.com/"), /차단/);
});

test("wrangler.toml 크론 = worker.js 상수 (문자열 동기)", async () => {
  const { readFile } = await import("node:fs/promises");
  const toml = await readFile(new URL("./wrangler.toml", import.meta.url), "utf8");
  const m = toml.match(/^crons\s*=\s*\[(.*)\]\s*$/m);
  assert.ok(m, "wrangler.toml 에 crons 줄 없음");
  const crons = [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
  assert.deepEqual(crons.sort(), [UPTIME_CRON, BRIEF_CRON].sort());
});

test("경계 시각 (FULL_EVERY_HOURS 기본 1)", () => {
  assert.equal(mode("01:04"), "quick");   // KST 10:04 — 영업시간 전
  assert.equal(mode("02:04"), "full");    // KST 11:04 — 첫 full
  assert.equal(mode("02:14"), "quick");   // 04분 슬롯만 full
  assert.equal(mode("02:54"), "quick");
  assert.equal(mode("14:04"), "full");    // KST 23:04 — 마지막 full
  assert.equal(mode("15:04"), "quick");   // KST 00:04
  assert.equal(mode("00:04"), "quick");
  assert.equal(mode("23:54"), "quick");
});

test("브리프 00:17 UTC → neon-usage.yml normal + source=cf", () => {
  assert.deepEqual(planDispatches(BRIEF_CRON, at("00:17"), {}), [
    { workflow: "neon-usage.yml", inputs: { mode: "normal", source: "cf", full_every_hours: "1" } },
  ]);
  assert.equal(planDispatches(BRIEF_CRON, at("00:17"), { FULL_EVERY_HOURS: "3" })[0].inputs.full_every_hours, "3");
});

test("uptime 은 항상 uptime.yml + source=cf, test-alert·preview 는 절대 안 보냄", () => {
  for (let i = 0; i < 144; i++) {
    const t = at("00:04") + i * 600_000;
    const p = planDispatches(UPTIME_CRON, t, {});
    assert.equal(p.length, 1);
    assert.equal(p[0].workflow, "uptime.yml");
    assert.equal(p[0].inputs.source, "cf");
    assert.ok(["quick", "full"].includes(p[0].inputs.mode));
  }
});

const fullsPerDay = (env) => {
  const hours = [];
  for (let i = 0; i < 144; i++) {
    const t = at("00:04") + i * 600_000;
    if (planDispatches(UPTIME_CRON, t, env)[0].inputs.mode === "full") hours.push(new Date(t).getUTCHours());
  }
  return hours;
};

test("FULL_EVERY_HOURS=3 → UTC 02·05·08·11·14시 (KST 11·14·17·20·23시) 5회", () => {
  const env = { FULL_EVERY_HOURS: "3" };
  assert.deepEqual(fullsPerDay(env), [2, 5, 8, 11, 14]);
  assert.equal(mode("02:04", env), "full");
  assert.equal(mode("03:04", env), "quick");
  assert.equal(mode("04:04", env), "quick");
  assert.equal(mode("05:04", env), "full");
  assert.equal(mode("14:04", env), "full");
  assert.equal(mode("15:04", env), "quick");
  assert.equal(mode("01:04", env), "quick");
});

test("하루 full 횟수: 1→13, 2→7, 3→5, 0→0, 잘못된 값→기본 1", () => {
  assert.equal(fullsPerDay({}).length, 13);
  assert.equal(fullsPerDay({ FULL_EVERY_HOURS: "1" }).length, 13);
  assert.deepEqual(fullsPerDay({ FULL_EVERY_HOURS: "2" }), [2, 4, 6, 8, 10, 12, 14]);
  assert.equal(fullsPerDay({ FULL_EVERY_HOURS: "0" }).length, 0);
  for (const bad of ["", " ", "abc", "-1", "1.5", undefined]) assert.equal(fullEveryHours({ FULL_EVERY_HOURS: bad }), 1, `값 ${bad}`);
  assert.equal(fullEveryHours({ FULL_EVERY_HOURS: "99" }), 13);
});

test("판단은 scheduledTime 기준 (실행 지연과 무관)", () => {
  // 예정 02:04:00Z. 실제 실행이 몇 초 늦어도 scheduledTime 은 그대로 → full
  assert.equal(planDispatches(UPTIME_CRON, at("02:04"), {})[0].inputs.mode, "full");
  assert.throws(() => planDispatches(UPTIME_CRON, NaN, {}), /scheduledTime/);
});

test("모르는 크론 → 아무것도 안 보냄 + 오류 로그", quiet((logs) => {
  assert.deepEqual(planDispatches("*/5 * * * *", at("02:05"), {}), []);
  assert.ok(logs.some(([k, s]) => k === "error" && s.includes("알 수 없는 크론")));
}));

// ---- dispatch (가짜 fetch) ----
const TOKEN = "github_pat_TESTONLY_xxxxxxxx";
const fakeFetch = (statuses) => {
  const calls = [];
  const f = async (url, init) => {
    calls.push({ url, init });
    const s = statuses[Math.min(calls.length - 1, statuses.length - 1)];
    if (s instanceof Error) throw s;
    return { status: s, text: async () => (s === 204 ? "" : `{"message":"status ${s}"}`) };
  };
  f.calls = calls;
  return f;
};
const D = { workflow: "uptime.yml", inputs: { mode: "quick", source: "cf" } };

test("dispatch 204 → 성공, URL·헤더·본문", quiet(async (logs) => {
  const f = fakeFetch([204]);
  assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN }, { fetch: f, retryDelayMs: 0 }), true);
  assert.equal(f.calls.length, 1);
  const { url, init } = f.calls[0];
  assert.equal(url, "https://api.github.com/repos/thebluepigu/simparty-monitor/actions/workflows/uptime.yml/dispatches");
  assert.equal(init.method, "POST");
  assert.equal(init.headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(init.headers.Accept, "application/vnd.github+json");
  assert.equal(init.headers["X-GitHub-Api-Version"], "2022-11-28");
  assert.ok(init.headers["User-Agent"]);
  assert.deepEqual(JSON.parse(init.body), { ref: "main", inputs: { mode: "quick", source: "cf" } });
  assert.ok(logs.every(([, s]) => !s.includes(TOKEN)), "로그에 토큰");
}));

test("dispatch 200(run 정보 응답) 도 성공", quiet(async () => {
  assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN }, { fetch: fakeFetch([200]), retryDelayMs: 0 }), true);
}));

test("5xx → 1회 재시도 후 성공", quiet(async () => {
  const f = fakeFetch([502, 204]);
  assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN }, { fetch: f, retryDelayMs: 0 }), true);
  assert.equal(f.calls.length, 2);
}));

test("429·네트워크 오류 → 재시도 1회까지만, 두 번 다 실패면 false", quiet(async () => {
  const f = fakeFetch([429, 503, 204]);
  assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN }, { fetch: f, retryDelayMs: 0 }), false);
  assert.equal(f.calls.length, 2);
  const g = fakeFetch([new TypeError("network down"), new TypeError("network down")]);
  assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN }, { fetch: g, retryDelayMs: 0 }), false);
  assert.equal(g.calls.length, 2);
}));

test("4xx(401·404·422) → 재시도 안 함, 상태·본문 로그, 토큰 미노출", quiet(async (logs) => {
  for (const s of [401, 403, 404, 422]) {
    logs.length = 0;
    const f = fakeFetch([s, 204]);
    assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN }, { fetch: f, retryDelayMs: 0 }), false);
    assert.equal(f.calls.length, 1, `HTTP ${s} 재시도함`);
    assert.ok(logs.some(([k, x]) => k === "error" && x.includes(`HTTP ${s}`) && x.includes(`status ${s}`)));
    assert.ok(logs.every(([, x]) => !x.includes(TOKEN)), "로그에 토큰");
  }
}));

test("DRY_RUN=1 → fetch 안 함 / 토큰 없음 → fetch 안 함·false", quiet(async (logs) => {
  const f = fakeFetch([204]);
  assert.equal(await dispatch(D, { GITHUB_TOKEN: TOKEN, DRY_RUN: "1" }, { fetch: f }), true);
  assert.equal(await dispatch(D, {}, { fetch: f }), false);
  assert.equal(f.calls.length, 0);
  assert.ok(logs.some(([, x]) => x.includes("[DRY_RUN]")));
}));

test("GITHUB_REPO·GITHUB_REF 덮어쓰기", quiet(async () => {
  const f = fakeFetch([204]);
  await dispatch(D, { GITHUB_TOKEN: TOKEN, GITHUB_REPO: "o/r", GITHUB_REF: "feat/x" }, { fetch: f });
  assert.match(f.calls[0].url, /\/repos\/o\/r\/actions\/workflows\/uptime\.yml\/dispatches$/);
  assert.equal(JSON.parse(f.calls[0].init.body).ref, "feat/x");
}));

test("scheduled 핸들러: 성공은 조용히, 실패는 throw (Cron Events 에 실패로 남김)", quiet(async () => {
  const f = fakeFetch([204]);
  globalThis.fetch = f;
  try {
    await worker.default.scheduled({ cron: UPTIME_CRON, scheduledTime: at("02:04"), type: "scheduled" }, { GITHUB_TOKEN: TOKEN }, {});
    assert.equal(f.calls.length, 1);
    assert.equal(JSON.parse(f.calls[0].init.body).inputs.mode, "full");
    globalThis.fetch = fakeFetch([401]);
    await assert.rejects(
      () => worker.default.scheduled({ cron: BRIEF_CRON, scheduledTime: at("00:17") }, { GITHUB_TOKEN: TOKEN }, {}),
      /1\/1건 실패/);
  } finally {
    globalThis.fetch = async (url) => { throw new Error(`테스트 중 실제 fetch 호출 차단: ${url}`); };
  }
}));
