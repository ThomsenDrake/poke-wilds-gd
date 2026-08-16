import { beforeEach, describe, expect, it, vi } from "vitest";
import { strToU8, zipSync } from "fflate";
import worker from "../src/index";
import { MAX_COMPRESSED_BYTES, MAX_METADATA_BYTES, sha256Hex } from "../src/security";
import type { Env } from "../src/types";

const findOrCreateIssue = vi.hoisted(() => vi.fn());
vi.mock("../src/github", () => ({ findOrCreateIssue }));
let currentBundleHash = "";

function env(rateAllowed: boolean): Env {
  return {
    DB: {
      prepare: () => ({
        bind: () => ({ first: async () => ({ tester_id: "T-TEST", nickname: "Tester", token_hash: "", cohort_id: "friends" }) }),
      }),
    } as unknown as D1Database,
    REPORTS: {} as R2Bucket,
    REPORT_RATE_LIMITER: { limit: async () => ({ success: rateAllowed }) } as RateLimit,
    ENVIRONMENT: "test", GITHUB_REPOSITORY: "owner/repo", GITHUB_APP_ID: "", GITHUB_INSTALLATION_ID: "",
    GITHUB_PRIVATE_KEY: "", ADMIN_TOKEN: "",
  };
}

describe("feedback report route boundaries", () => {
	beforeEach(() => findOrCreateIssue.mockReset());
  it("fails closed for missing, short, or empty admin credentials", async () => {
    for (const [secret, header] of [["", "Bearer x"], ["short", "Bearer short"], ["a".repeat(32), "Bearer "]] as const) {
      const scoped = env(true);
      scoped.ADMIN_TOKEN = secret;
      const response = await worker.fetch(new Request("https://relay.test/v1/admin/invites", {
        method: "POST", headers: { Authorization: header, "Content-Type": "application/json" }, body: "{}",
      }), scoped);
      expect(response.status).toBe(401);
      expect(await response.json()).toMatchObject({ error: "unauthorized" });
    }
  });

  it("rate limits an authorized invite before multipart parsing", async () => {
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite", "Content-Type": "not-multipart" }, body: "ignored",
    }), env(false));
    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: "rate_limited" });
  });

  it("rejects a streamed multipart body above the hard cap", async () => {
    const bytes = new Uint8Array(MAX_COMPRESSED_BYTES + MAX_METADATA_BYTES + 256 * 1024 + 1);
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite", "Content-Type": "multipart/form-data; boundary=x" }, body: bytes,
    }), env(true));
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ error: "payload_too_large" });
  });

  it("returns the typed status for malformed metadata", async () => {
    const form = new FormData();
    form.set("metadata", "[]");
    form.set("bundle", new Blob([new Uint8Array([1])], { type: "application/zip" }), "report.zip");
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite" }, body: form,
    }), env(true));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ ok: false, error: "metadata_not_object" });
  });

  it("returns 413 for a ZIP whose declared uncompressed size exceeds the limit", async () => {
    const payload = await uploadPayload();
    const bomb = new Uint8Array(payload.bundle);
    const view = new DataView(bomb.buffer, bomb.byteOffset, bomb.byteLength);
    const central = centralOffset(bomb);
    const local = view.getUint32(central + 42, true);
    view.setUint32(central + 24, 0x02000000, true);
    view.setUint32(local + 22, 0x02000000, true);
    payload.metadata.bundle_sha256 = await sha256Hex(bomb);
    payload.metadata.bundle_bytes = bomb.byteLength;
    const form = new FormData();
    form.set("metadata", JSON.stringify(payload.metadata));
    form.set("bundle", new Blob([bomb], { type: "application/zip" }), "report.zip");
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite" }, body: form,
    }), env(true));
    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({ ok: false, error: "bundle_uncompressed_too_large" });
  });

  it("never puts the invite token in the limiter key", async () => {
    const expectedHash = await sha256Hex("invite");
    const keys: string[] = [];
    const scoped = env(false);
    scoped.DB = {
      prepare: () => ({ bind: () => ({ first: async () => ({ tester_id: "T-TEST", nickname: "Tester", token_hash: expectedHash, cohort_id: "friends" }) }), }),
    } as unknown as D1Database;
    scoped.REPORT_RATE_LIMITER = { limit: async ({ key }: { key: string }) => { keys.push(key); return { success: false }; } } as RateLimit;
    await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite", "Content-Type": "multipart/form-data; boundary=x" }, body: "ignored",
    }), scoped);
    expect(keys).toEqual([`T-TEST:${expectedHash}`]);
    expect(keys[0]).not.toContain("invite");
  });

  it("returns a matching completed report before attempting daily admission", async () => {
    const { metadata, bundle } = await uploadPayload();
    const queries: string[] = [];
    const completed = {
      report_id: metadata.report_id, status: "completed", bundle_key: "private", bundle_sha256: metadata.bundle_sha256,
      issue_number: 12, issue_url: "https://github.com/owner/repo/issues/12", updated_at: "2026-08-12T00:00:00Z",
    };
    const scoped = env(true);
    scoped.DB = {
      prepare: (query: string) => {
        queries.push(query);
        return { bind: () => ({ first: async () => query.startsWith("SELECT tester_id")
          ? { tester_id: "T-TEST", nickname: "Tester", token_hash: "", cohort_id: "friends" } : completed }) };
      },
    } as unknown as D1Database;
    const form = new FormData();
    form.set("metadata", JSON.stringify(metadata));
    form.set("bundle", new Blob([bundle], { type: "application/zip" }), "report.zip");
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite" }, body: form,
    }), scoped);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ report_id: metadata.report_id, issue_number: 12 });
    expect(queries.some((query) => query.startsWith("INSERT OR IGNORE INTO reports"))).toBe(false);
  });

  it("keeps a fresh issuing report in progress without touching R2 or issue creation", async () => {
    const { metadata, bundle } = await uploadPayload();
    const scoped = env(true);
    const issuing = {
      report_id: metadata.report_id, status: "issuing", bundle_key: "private", bundle_sha256: metadata.bundle_sha256,
      issue_number: null, issue_url: null, updated_at: new Date().toISOString(), expires_at: "2030-01-02T03:04:05.000Z",
    };
    scoped.DB = {
      prepare: (query: string) => ({ bind: () => ({ first: async () => query.startsWith("SELECT tester_id")
        ? { tester_id: "T-TEST", nickname: "Tester", token_hash: "", cohort_id: "friends" } : issuing }) }),
    } as unknown as D1Database;
    scoped.REPORTS = { put: async () => { throw new Error("R2 must not be touched"); } } as unknown as R2Bucket;
    const form = new FormData();
    form.set("metadata", JSON.stringify(metadata));
    form.set("bundle", new Blob([bundle], { type: "application/zip" }), "report.zip");
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite" }, body: form,
    }), scoped);
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({ error: "issue_in_progress" });
  });

  it("rejects a new report at daily admission before R2 or GitHub", async () => {
    const harness = routeHarness({ admissionChanges: 0 });
    const response = await submit(harness.env);
    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: "daily_limit" });
    expect(harness.put).not.toHaveBeenCalled();
    expect(findOrCreateIssue).not.toHaveBeenCalled();
  });

  it("leaves an admitted report received when R2 fails and does not create an issue", async () => {
    const put = vi.fn().mockRejectedValue(new Error("r2 unavailable"));
    const harness = routeHarness({ put });
    const response = await submit(harness.env);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ ok: false, error: "internal_error" });
		expect(harness.queries.some((query) => query.startsWith("INSERT OR IGNORE"))).toBe(true);
		expect(harness.queries.some((query) => query.startsWith("UPDATE reports SET status='stored'"))).toBe(false);
    expect(put).toHaveBeenCalledOnce();
    expect(findOrCreateIssue).not.toHaveBeenCalled();
  });

  it("retries received and stored reports without quota admission and completes each once", async () => {
    for (const status of ["received", "stored"] as const) {
      const harness = routeHarness({ existing: reportRow(status) });
      findOrCreateIssue.mockResolvedValueOnce({ number: 77, html_url: "https://github.com/o/r/issues/77" });
      const response = await submit(harness.env);
      expect(response.status).toBe(201);
      expect(harness.put).toHaveBeenCalledOnce();
      expect(harness.queries.some((query) => query.startsWith("INSERT OR IGNORE"))).toBe(false);
      expect(findOrCreateIssue).toHaveBeenLastCalledWith(harness.env, expect.anything(), "2030-01-02T03:04:05.000Z");
    }
  });

  it("reconciles a stale issuing report and searches/creates once with stored expiry", async () => {
    const harness = routeHarness({ existing: reportRow("issuing", "2000-01-01T00:00:00Z") });
    findOrCreateIssue.mockResolvedValueOnce({ number: 88, html_url: "https://github.com/o/r/issues/88" });
    const response = await submit(harness.env);
    expect(response.status).toBe(201);
    expect(harness.queries.some((query) => query.includes("status='issuing' AND updated_at=?"))).toBe(true);
    expect(findOrCreateIssue).toHaveBeenCalledTimes(1);
    expect(findOrCreateIssue).toHaveBeenLastCalledWith(harness.env, expect.anything(), "2030-01-02T03:04:05.000Z");
  });

  it("preserves issuing after post-create completion failure and immediate retry is 202 without another create", async () => {
    const completionFailure = new Error("d1 completion failed");
    const first = routeHarness({ completionError: completionFailure });
    findOrCreateIssue.mockResolvedValueOnce({ number: 99, html_url: "https://github.com/o/r/issues/99" });
    const firstResponse = await submit(first.env);
    expect(firstResponse.status).toBe(500);
    expect(await firstResponse.json()).toEqual({ ok: false, error: "internal_error" });
    expect(first.queries.some((query) => query === "UPDATE reports SET status='stored',updated_at=CURRENT_TIMESTAMP WHERE report_id=?")).toBe(false);
    const second = routeHarness({ existing: reportRow("issuing") });
    const secondResponse = await submit(second.env);
    expect(secondResponse.status).toBe(202);
    expect(findOrCreateIssue).toHaveBeenCalledTimes(1);
  });

  it("does not expose unexpected storage errors to clients", async () => {
    const scoped = env(true);
    scoped.DB = { prepare: () => { throw new Error("database credential-shaped detail"); } } as unknown as D1Database;
    const response = await worker.fetch(new Request("https://relay.test/v1/reports", {
      method: "POST", headers: { Authorization: "Bearer invite" }, body: new FormData(),
    }), scoped);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ ok: false, error: "internal_error" });
  });
});

type HarnessOptions = { existing?: ReturnType<typeof reportRow>; admissionChanges?: number; put?: ReturnType<typeof vi.fn>; completionError?: Error };

function routeHarness(options: HarnessOptions = {}) {
  const queries: string[] = [];
  const put = options.put ?? vi.fn().mockResolvedValue(undefined);
  const existing = options.existing;
  const envValue = env(true);
  envValue.REPORTS = { put } as unknown as R2Bucket;
  envValue.DB = {
    prepare: (query: string) => {
      queries.push(query);
      return {
        bind: () => ({
          first: async () => {
            if (query.startsWith("SELECT tester_id")) return { tester_id: "T-TEST", nickname: "Tester", token_hash: "", cohort_id: "friends" };
            if (query.startsWith("SELECT report_id,status")) return existing ? { ...existing, bundle_sha256: existing.bundle_sha256 || currentBundleHash } : null;
            return null;
          },
          run: async () => {
            if (query.startsWith("INSERT OR IGNORE")) return { meta: { changes: options.admissionChanges ?? 1 } };
            if (query.startsWith("UPDATE reports SET status='completed'")) {
              if (options.completionError) throw options.completionError;
              return { meta: { changes: 1 } };
            }
            return { meta: { changes: 1 } };
          },
        }),
      };
    },
  } as unknown as D1Database;
  return { env: envValue, put, queries };
}

function reportRow(status: string, updatedAt = new Date().toISOString()) {
  return {
    report_id: "01234567-89ab-cdef-0123-456789abcdef", status, bundle_key: "private", bundle_sha256: "",
    issue_number: null, issue_url: null, updated_at: updatedAt, expires_at: "2030-01-02T03:04:05.000Z",
  };
}

async function submit(envValue: Env): Promise<Response> {
  const { metadata, bundle } = await uploadPayload();
  currentBundleHash = String(metadata.bundle_sha256);
  const form = new FormData();
  form.set("metadata", JSON.stringify(metadata));
  form.set("bundle", new Blob([bundle], { type: "application/zip" }), "report.zip");
  return worker.fetch(new Request("https://relay.test/v1/reports", {
    method: "POST", headers: { Authorization: "Bearer invite" }, body: form,
  }), envValue);
}

async function uploadPayload(): Promise<{ metadata: Record<string, unknown>; bundle: Uint8Array }> {
  const reportId = "01234567-89ab-cdef-0123-456789abcdef";
  const runtime = { godot_version: "4.6", os_name: "macOS", os_version: "15", architecture: "arm64", locale: "en_US",
    renderer: "gl_compatibility", adapter: "Apple", window_size: [1152, 648] };
  const game = { current_screen: "overworld", world_seed: 7, player_tile: [1, 2], active_area: "field",
    time_of_day_minutes: 480, total_steps: 32, party: [], bag: {}, battle_active: false };
  const capture = { screenshot_available: false, screen: "overworld" };
  const contents = { "trace.jsonl": strToU8("{}\n"), "engine.log": strToU8("ok"), "save.json": strToU8("{}"),
    "ui-tree.json": strToU8("{}"), "README.txt": strToU8("start") };
  const artifacts = await Promise.all(Object.entries(contents).map(async ([path, bytes]) =>
    ({ path, bytes: bytes.byteLength, sha256: await sha256Hex(bytes), truncated: false })));
  const base = { schema_version: 1, report_id: reportId, created_at_utc: "2026-08-12T12:34:56Z", message: "stuck",
    tester_id: "T-TEST", install_id: "a".repeat(32),
    build: { version: "0.0.0", commit_sha: "b".repeat(40), build_id: "beta-1", channel: "friends" }, runtime, game, capture };
  const bundle = zipSync({ ...contents, "report.json": strToU8(JSON.stringify({ ...base, artifacts })) }, { level: 0 });
  return { bundle, metadata: { ...base, bundle_sha256: await sha256Hex(bundle), bundle_bytes: bundle.byteLength } };
}

function centralOffset(bytes: Uint8Array): number {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let offset = bytes.byteLength - 22; offset >= 0; offset--) {
    if (view.getUint32(offset, true) === 0x06054b50) return view.getUint32(offset + 16, true);
  }
  throw new Error("missing test EOCD");
}
