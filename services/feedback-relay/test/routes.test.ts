import { beforeEach, describe, expect, it, vi } from "vitest";
import { strToU8, zipSync } from "fflate";
import worker, { cleanupExpiredReports } from "../src/index";
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
    WORKER_VERSION: { id: "version-test", tag: "commit-test", timestamp: "2026-08-18T00:00:00Z" },
    ENVIRONMENT: "test", GITHUB_REPOSITORY: "owner/repo", GITHUB_APP_ID: "", GITHUB_INSTALLATION_ID: "",
    GITHUB_PRIVATE_KEY: "", ADMIN_TOKEN: "",
  };
}

describe("feedback report route boundaries", () => {
	beforeEach(() => findOrCreateIssue.mockReset());
  it("identifies the exact Worker version in health responses", async () => {
    const response = await worker.fetch(new Request("https://relay.test/healthz"), env(true));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      environment: "test",
      report_schema: 1,
      version_id: "version-test",
      version_tag: "commit-test",
    });
  });

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

  it("rejects an expired report before restoring its private bundle", async () => {
    const harness = routeHarness({ existing: reportRow("expired") });
    const response = await submit(harness.env);
    expect(response.status).toBe(410);
    expect(await response.json()).toMatchObject({ error: "report_expired" });
    expect(harness.put).not.toHaveBeenCalled();
    expect(findOrCreateIssue).not.toHaveBeenCalled();
  });

  it("loses an upload claim to cleanup without restoring the private bundle", async () => {
    const harness = routeHarness({
      existing: reportRow("received"),
      existingAfterUploadClaim: reportRow("expiring"),
      uploadClaimChanges: 0,
    });
    const response = await submit(harness.env);
    expect(response.status).toBe(410);
    expect(await response.json()).toMatchObject({ error: "report_expired" });
    expect(harness.put).not.toHaveBeenCalled();
    expect(findOrCreateIssue).not.toHaveBeenCalled();
  });

  it("keeps an active upload lease in progress without a second R2 write", async () => {
    const harness = routeHarness({ existing: reportRow("uploading") });
    const response = await submit(harness.env);
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({ error: "upload_in_progress" });
    expect(harness.put).not.toHaveBeenCalled();
  });

  it("denies admin bundle reads as soon as cleanup owns the report", async () => {
    const scoped = env(true);
    const get = vi.fn();
    scoped.ADMIN_TOKEN = "a".repeat(32);
    scoped.REPORTS = { get } as unknown as R2Bucket;
    scoped.DB = {
      prepare: () => ({ bind: () => ({ first: async () => ({ status: "expiring", bundle_key: "private", bundle_sha256: "hash" }) }) }),
    } as unknown as D1Database;
    const response = await worker.fetch(new Request(
      "https://relay.test/v1/admin/reports/01234567-89ab-cdef-0123-456789abcdef/bundle",
      { headers: { Authorization: `Bearer ${"a".repeat(32)}` } },
    ), scoped);
    expect(response.status).toBe(410);
    expect(await response.json()).toMatchObject({ error: "artifact_expired" });
    expect(get).not.toHaveBeenCalled();
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

describe("expired report cleanup", () => {
  it("drains more than one deterministic page with bulk storage operations", async () => {
    const harness = cleanupHarness([cleanupRows(100, 0), cleanupRows(55, 100)]);
    const result = await cleanupExpiredReports(harness.env);
    expect(result).toEqual({ batches: 2, processed: 155, limited: false });
    expect(harness.deleted).toHaveBeenCalledTimes(2);
    expect(harness.claimed).toEqual([cleanupIds(100, 0), cleanupIds(55, 100)]);
    expect(harness.updated).toEqual([cleanupIds(100, 0), cleanupIds(55, 100)]);
    expect(harness.queries[0]).toContain("datetime(expires_at) <= CURRENT_TIMESTAMP");
    expect(harness.queries[0]).toContain("ORDER BY datetime(expires_at), report_id LIMIT ?");
    expect(harness.queries[0]).toContain("SET status='expiring'");
    expect(harness.queries[0]).toContain("RETURNING report_id, bundle_key");
    expect(harness.queries[0]).toContain("status NOT IN ('uploading','issuing')");
    expect(harness.events.slice(0, 3)).toEqual(["claim", "delete", "finalize"]);
  });

  it("stops immediately on an empty page", async () => {
    const harness = cleanupHarness([[]]);
    await expect(cleanupExpiredReports(harness.env)).resolves.toEqual({ batches: 0, processed: 0, limited: false });
    expect(harness.deleted).not.toHaveBeenCalled();
    expect(harness.claimed).toEqual([]);
    expect(harness.updated).toEqual([]);
  });

  it("stops at the batch cap and emits aggregate-only telemetry", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const harness = cleanupHarness(Array.from({ length: 10 }, (_, page) => cleanupRows(100, page * 100)));
    await expect(cleanupExpiredReports(harness.env)).resolves.toEqual({ batches: 10, processed: 1000, limited: true });
    expect(harness.deleted).toHaveBeenCalledTimes(10);
    expect(warning).toHaveBeenCalledOnce();
    expect(warning.mock.calls[0][0]).toBe('{"event":"feedback_cleanup_batch_limit","batches":10,"processed":1000}');
    warning.mockRestore();
  });

  it("does not mark rows expired when bulk R2 deletion fails", async () => {
    const harness = cleanupHarness([cleanupRows(1, 0)], { deleteFailures: 1 });
    await expect(cleanupExpiredReports(harness.env)).rejects.toThrow("storage delete failed");
    expect(harness.claimed).toEqual([cleanupIds(1, 0)]);
    expect(harness.updated).toEqual([]);
  });

  it("does not touch R2 when the cleanup claim fails", async () => {
    const harness = cleanupHarness([cleanupRows(1, 0)], { claimFailures: 1 });
    await expect(cleanupExpiredReports(harness.env)).rejects.toThrow("database claim failed");
    expect(harness.deleted).not.toHaveBeenCalled();
    expect(harness.updated).toEqual([]);
  });

  it("retries an idempotent R2 delete after a D1 update failure", async () => {
    const rows = cleanupRows(1, 0);
    const harness = cleanupHarness([rows, rows], { updateFailures: 1 });
    await expect(cleanupExpiredReports(harness.env)).rejects.toThrow("database update failed");
    await expect(cleanupExpiredReports(harness.env)).resolves.toEqual({ batches: 1, processed: 1, limited: false });
    expect(harness.deleted).toHaveBeenCalledTimes(2);
    expect(harness.updated).toEqual([cleanupIds(1, 0)]);
  });
});

type HarnessOptions = {
  existing?: ReturnType<typeof reportRow>;
  existingAfterUploadClaim?: ReturnType<typeof reportRow>;
  admissionChanges?: number;
  uploadClaimChanges?: number;
  put?: ReturnType<typeof vi.fn>;
  completionError?: Error;
};

function cleanupHarness(pages: Array<Array<{ report_id: string; bundle_key: string }>>,
  failures: { claimFailures?: number; deleteFailures?: number; updateFailures?: number } = {}) {
  let page = 0;
  let claimFailures = failures.claimFailures ?? 0;
  let deleteFailures = failures.deleteFailures ?? 0;
  let updateFailures = failures.updateFailures ?? 0;
  const claimed: string[][] = [];
  const updated: string[][] = [];
  const queries: string[] = [];
  const events: string[] = [];
  const deleted = vi.fn(async () => {
    events.push("delete");
    if (deleteFailures > 0) {
      deleteFailures -= 1;
      throw new Error("storage delete failed");
    }
  });
  const envValue = env(true);
  envValue.REPORTS = { delete: deleted } as unknown as R2Bucket;
  envValue.DB = {
    prepare: (query: string) => {
      queries.push(query);
      return {
        bind: (value: number | string) => ({
          all: async () => {
            events.push("claim");
            if (claimFailures > 0) {
              claimFailures -= 1;
              throw new Error("database claim failed");
            }
            const rows = pages[page++] ?? [];
            if (rows.length > 0) claimed.push(rows.map((row) => row.report_id));
            return { results: rows };
          },
          run: async () => {
            const ids = JSON.parse(String(value)) as string[];
            events.push("finalize");
            if (updateFailures > 0) {
              updateFailures -= 1;
              throw new Error("database update failed");
            }
            updated.push(ids);
            return { meta: { changes: updated.at(-1)?.length ?? 0 } };
          },
        }),
      };
    },
  } as unknown as D1Database;
  return { env: envValue, deleted, claimed, updated, queries, events };
}

function cleanupRows(count: number, offset: number): Array<{ report_id: string; bundle_key: string }> {
  return cleanupIds(count, offset).map((report_id) => ({ report_id, bundle_key: `private/${report_id}` }));
}

function cleanupIds(count: number, offset: number): string[] {
  return Array.from({ length: count }, (_, index) => `report-${offset + index}`);
}

function routeHarness(options: HarnessOptions = {}) {
  const queries: string[] = [];
  const put = options.put ?? vi.fn().mockResolvedValue(undefined);
  const existing = options.existing;
  const envValue = env(true);
  envValue.REPORTS = { put, delete: vi.fn().mockResolvedValue(undefined) } as unknown as R2Bucket;
  envValue.DB = {
    prepare: (query: string) => {
      queries.push(query);
      return {
        bind: () => ({
          first: async () => {
            if (query.startsWith("SELECT tester_id")) return { tester_id: "T-TEST", nickname: "Tester", token_hash: "", cohort_id: "friends" };
            if (query.startsWith("SELECT report_id,status")) return existing ? { ...existing, bundle_sha256: existing.bundle_sha256 || currentBundleHash } : null;
            if (query.startsWith("SELECT status,issue_number")) {
              const row = options.existingAfterUploadClaim ?? existing;
              return row ? { ...row, bundle_sha256: row.bundle_sha256 || currentBundleHash } : null;
            }
            return null;
          },
          run: async () => {
            if (query.startsWith("INSERT OR IGNORE")) return { meta: { changes: options.admissionChanges ?? 1 } };
            if (query.includes("SET status='uploading'")) return { meta: { changes: options.uploadClaimChanges ?? 1 } };
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

describe("shared update routes", () => {
  const digest = "c".repeat(64);
  const manifest = {
    schema_version: 1, channel: "playtest", published_at: "2026-08-19T18:00:00Z",
    build_id: "playtest-abc1234567-20260819T180000Z", commit_sha: "b".repeat(40), min_save_version: 6,
    builds: {
      linux: { url: "https://cdn.test/linux", sha256: digest, bytes: 8, filename: "PokeWilds-linux.x86_64" },
      windows: { url: "https://cdn.test/windows", sha256: digest, bytes: 8, filename: "PokeWilds-windows.exe" },
      macos: { url: "https://cdn.test/macos", sha256: digest, bytes: 8, filename: "PokeWilds-macos.zip" },
    },
  };

  it("serves a public artifact without exposing report objects", async () => {
    const scoped = env(true);
    const body = new Uint8Array([7, 7, 7, 7]);
    const get = vi.fn(async (key: string) => key === "updates/playtest/b1/linux"
      ? { body, customMetadata: { sha256: digest } } : null);
    scoped.REPORTS = { get } as unknown as R2Bucket;
    const response = await worker.fetch(new Request("https://relay.test/v1/updates/artifacts/playtest/b1/linux"), scoped);
    expect(response.status).toBe(200);
    expect(get).toHaveBeenCalledWith("updates/playtest/b1/linux");
    expect(get).not.toHaveBeenCalledWith(expect.stringContaining("reports/"));
    const missing = await worker.fetch(new Request("https://relay.test/v1/updates/artifacts/playtest/b1/reports"), scoped);
    expect(missing.status).toBe(404);
  });

  it("serves a public latest manifest", async () => {
    const scoped = env(true);
    scoped.REPORTS = {
      get: async (key: string) => key === "updates/playtest/latest.json"
        ? { body: JSON.stringify(manifest) } : null,
    } as unknown as R2Bucket;
    const response = await worker.fetch(new Request("https://relay.test/v1/updates/latest?channel=playtest"), scoped);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ build_id: manifest.build_id, channel: "playtest" });
  });

  it("refuses unauthenticated manifest publish", async () => {
    const scoped = env(true);
    scoped.ADMIN_TOKEN = "a".repeat(32);
    const response = await worker.fetch(new Request("https://relay.test/v1/admin/updates", {
      method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(manifest),
    }), scoped);
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: "unauthorized" });
  });

  it("refuses publish when an OS checksum is missing", async () => {
    const scoped = env(true);
    scoped.ADMIN_TOKEN = "a".repeat(32);
    scoped.REPORTS = { head: async () => null, put: vi.fn() } as unknown as R2Bucket;
    const response = await worker.fetch(new Request("https://relay.test/v1/admin/updates", {
      method: "PUT",
      headers: { Authorization: `Bearer ${"a".repeat(32)}`, "Content-Type": "application/json" },
      body: JSON.stringify(manifest),
    }), scoped);
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "checksum_missing" });
    expect(scoped.REPORTS.put).not.toHaveBeenCalled();
  });

  it("publishes when checksums are stored in cache-control", async () => {
    const scoped = env(true);
    scoped.ADMIN_TOKEN = "a".repeat(32);
    const put = vi.fn();
    scoped.REPORTS = {
      head: async () => ({ httpMetadata: { cacheControl: `sha256=${digest}` } }),
      put,
    } as unknown as R2Bucket;
    const response = await worker.fetch(new Request("https://relay.test/v1/admin/updates", {
      method: "PUT",
      headers: { Authorization: `Bearer ${"a".repeat(32)}`, "Content-Type": "application/json" },
      body: JSON.stringify(manifest),
    }), scoped);
    expect(response.status).toBe(201);
    expect(put).toHaveBeenCalled();
  });

  it("publishes after all three artifact checksums exist", async () => {
    const scoped = env(true);
    scoped.ADMIN_TOKEN = "a".repeat(32);
    const put = vi.fn();
    scoped.REPORTS = {
      head: async () => ({ customMetadata: { sha256: digest } }),
      put,
    } as unknown as R2Bucket;
    const response = await worker.fetch(new Request("https://relay.test/v1/admin/updates", {
      method: "PUT",
      headers: { Authorization: `Bearer ${"a".repeat(32)}`, "Content-Type": "application/json" },
      body: JSON.stringify(manifest),
    }), scoped);
    expect(response.status).toBe(201);
    expect(put).toHaveBeenCalled();
  });
});

function centralOffset(bytes: Uint8Array): number {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let offset = bytes.byteLength - 22; offset >= 0; offset--) {
    if (view.getUint32(offset, true) === 0x06054b50) return view.getUint32(offset + 16, true);
  }
  throw new Error("missing test EOCD");
}
