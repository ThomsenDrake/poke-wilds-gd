import { findOrCreateIssue } from "./github";
import { badRequest, payloadTooLarge, RelayError } from "./errors";
import { constantTimeEqual, inspectBundle, MAX_COMPRESSED_BYTES, MAX_METADATA_BYTES, sha256Hex, validateMetadata } from "./security";
import type { Env, InviteRow, ReportMetadata, ReportRow } from "./types";
import { artifactKey, latestKey, parseArtifactPath, parseChannel, parseManifest } from "./updates";

const MAX_MULTIPART_BYTES = MAX_COMPRESSED_BYTES + MAX_METADATA_BYTES + 256 * 1024;
const CLEANUP_PAGE_SIZE = 100;
const CLEANUP_MAX_BATCHES = 10;
const ACTIVE_LEASE_TIMEOUT_SQL = "datetime('now','-2 minutes')";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json({
          ok: true,
          environment: env.ENVIRONMENT,
          report_schema: 1,
          version_id: env.WORKER_VERSION.id,
          version_tag: env.WORKER_VERSION.tag,
        });
      }
      if (url.pathname.startsWith("/v1/admin/")) return await adminRoute(request, env, url);
      if (request.method === "GET" && url.pathname === "/v1/updates/latest") {
        return await latestUpdate(request, env, url);
      }
      const artifact = parseArtifactPath(url.pathname);
      if (request.method === "GET" && artifact) {
        return await serveUpdateArtifact(env, artifact.channel, artifact.buildId, artifact.os);
      }
      if (request.method === "POST" && url.pathname === "/v1/reports") return await createReport(request, env);
      return json({ ok: false, error: "not_found" }, 404);
    } catch (error) {
      const classified = classifyError(error);
      console.error(JSON.stringify({ event: "feedback_relay_error", error_class: classified.error }));
      return json({ ok: false, error: classified.error }, classified.status);
    }
  },

  async scheduled(_event: ScheduledController, env: Env): Promise<void> {
    await cleanupExpiredReports(env);
  },
} satisfies ExportedHandler<Env>;

export async function cleanupExpiredReports(env: Env): Promise<{ batches: number; processed: number; limited: boolean }> {
  let processed = 0;
  for (let batch = 0; batch < CLEANUP_MAX_BATCHES; batch += 1) {
    const claimed = await env.DB.prepare(
      "UPDATE reports SET status='expiring', updated_at=CURRENT_TIMESTAMP " +
      "WHERE report_id IN (SELECT report_id FROM reports " +
      "WHERE datetime(expires_at) <= CURRENT_TIMESTAMP AND status != 'expired' " +
      `AND (status NOT IN ('uploading','issuing') OR datetime(updated_at) <= ${ACTIVE_LEASE_TIMEOUT_SQL}) ` +
      "ORDER BY datetime(expires_at), report_id LIMIT ?) " +
      "AND datetime(expires_at) <= CURRENT_TIMESTAMP AND status != 'expired' " +
      `AND (status NOT IN ('uploading','issuing') OR datetime(updated_at) <= ${ACTIVE_LEASE_TIMEOUT_SQL}) ` +
      "RETURNING report_id, bundle_key",
    ).bind(CLEANUP_PAGE_SIZE).all<{ report_id: string; bundle_key: string }>();
    const rows = claimed.results;
    if (rows.length === 0) return { batches: batch, processed, limited: false };
    await env.REPORTS.delete(rows.map((row) => row.bundle_key));
    await env.DB.prepare(
      "UPDATE reports SET status='expired', updated_at=CURRENT_TIMESTAMP " +
      "WHERE status='expiring' " +
      "AND report_id IN (SELECT value FROM json_each(?))",
    ).bind(JSON.stringify(rows.map((row) => row.report_id))).run();
    processed += rows.length;
    if (rows.length < CLEANUP_PAGE_SIZE) return { batches: batch + 1, processed, limited: false };
  }
  console.warn(JSON.stringify({ event: "feedback_cleanup_batch_limit", batches: CLEANUP_MAX_BATCHES, processed }));
  return { batches: CLEANUP_MAX_BATCHES, processed, limited: true };
}

async function createReport(request: Request, env: Env): Promise<Response> {
  const started = Date.now();
  const authorized = await authorizeInvite(request, env);
  const limited = await env.REPORT_RATE_LIMITER.limit({ key: `${authorized.invite.tester_id}:${authorized.tokenHash}` });
  if (!limited.success) return json({ ok: false, error: "rate_limited" }, 429, { "Retry-After": "60" });
  const form = await boundedFormData(request);
  const metadataField = form.get("metadata");
  const bundleField = form.get("bundle");
  if (typeof metadataField !== "string" || new TextEncoder().encode(metadataField).byteLength > MAX_METADATA_BYTES) throw badRequest("invalid_metadata_part");
  if (!(bundleField instanceof File) || bundleField.size > MAX_COMPRESSED_BYTES) return json({ ok: false, error: "bundle_too_large" }, 413);
  let metadata: ReportMetadata;
  try {
    metadata = validateMetadata(JSON.parse(metadataField));
  } catch (error) {
    if (error instanceof SyntaxError) throw badRequest("invalid_metadata_json");
    throw error;
  }
  if (metadata.tester_id !== authorized.invite.tester_id) throw badRequest("tester_mismatch");
  if (metadata.build.channel !== authorized.invite.cohort_id) throw badRequest("cohort_mismatch");
  const bytes = new Uint8Array(await bundleField.arrayBuffer());
  if (bytes.byteLength !== metadata.bundle_bytes || await sha256Hex(bytes) !== metadata.bundle_sha256) throw badRequest("bundle_hash_mismatch");
  await inspectBundle(bytes, metadata);
  const existing = await env.DB.prepare(
    "SELECT report_id,status,bundle_key,bundle_sha256,issue_number,issue_url,updated_at,expires_at FROM reports WHERE report_id=?",
  ).bind(metadata.report_id).first<ReportRow>();
  if (existing && existing.bundle_sha256 !== metadata.bundle_sha256) return json({ ok: false, error: "report_id_conflict" }, 409);
  if (existing?.status === "expiring" || existing?.status === "expired") {
    return json({ ok: false, report_id: metadata.report_id, error: "report_expired" }, 410);
  }
  if (existing?.status === "completed") return json({ ok: true, report_id: metadata.report_id, issue_number: existing.issue_number, issue_url: existing.issue_url }, 200);
  if (existing?.status === "uploading") {
    const updatedAt = Date.parse(existing.updated_at.endsWith("Z") ? existing.updated_at : `${existing.updated_at}Z`);
    if (!Number.isFinite(updatedAt) || Date.now() - updatedAt < 120_000) {
      return json({ ok: false, report_id: metadata.report_id, error: "upload_in_progress" }, 202, { "Retry-After": "30" });
    }
    await env.DB.prepare("UPDATE reports SET status='received',updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status='uploading' AND updated_at=?")
      .bind(metadata.report_id, existing.updated_at).run();
  }
  if (existing?.status === "issuing") {
    const updatedAt = Date.parse(existing.updated_at.endsWith("Z") ? existing.updated_at : `${existing.updated_at}Z`);
    if (!Number.isFinite(updatedAt) || Date.now() - updatedAt < 120_000) {
      return json({ ok: false, report_id: metadata.report_id, error: "issue_in_progress" }, 202, { "Retry-After": "30" });
    }
    await env.DB.prepare("UPDATE reports SET status='stored',updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status='issuing' AND updated_at=?")
      .bind(metadata.report_id, existing.updated_at).run();
  }
  const installHash = await sha256Hex(`${authorized.invite.cohort_id}:${metadata.install_id}`);
  const key = `reports/${authorized.invite.cohort_id}/${metadata.report_id}/bundle.zip`;
  const expires = new Date(Date.now() + 180 * 86400_000).toISOString();
  if (!existing) {
    const admission = await env.DB.prepare(
      "INSERT OR IGNORE INTO reports(report_id,tester_id,cohort_id,install_id_hash,build_id,status,bundle_key,bundle_sha256,bundle_bytes,expires_at) " +
      "SELECT ?,?,?,?,?, 'received',?,?,?,? WHERE " +
      "(SELECT COUNT(*) FROM reports WHERE install_id_hash=? AND created_at >= datetime('now','-1 day')) < 20 AND " +
      "(SELECT COUNT(*) FROM reports WHERE cohort_id=? AND created_at >= datetime('now','-1 day')) < 200",
    ).bind(metadata.report_id, authorized.invite.tester_id, authorized.invite.cohort_id, installHash, metadata.build.build_id, key,
      metadata.bundle_sha256, bytes.byteLength, expires, installHash, authorized.invite.cohort_id).run();
    if ((admission.meta.changes ?? 0) !== 1) {
      const raced = await env.DB.prepare(
        "SELECT report_id,status,bundle_sha256,issue_number,issue_url,updated_at,expires_at FROM reports WHERE report_id=?",
      ).bind(metadata.report_id).first<ReportRow>();
      if (raced && raced.bundle_sha256 !== metadata.bundle_sha256) return json({ ok: false, error: "report_id_conflict" }, 409);
      if (raced?.status === "expiring" || raced?.status === "expired") {
        return json({ ok: false, report_id: metadata.report_id, error: "report_expired" }, 410);
      }
      if (raced?.status === "completed") return json({ ok: true, report_id: metadata.report_id, issue_number: raced.issue_number, issue_url: raced.issue_url }, 200);
      if (raced) return json({ ok: false, report_id: metadata.report_id, error: "issue_in_progress" }, 202, { "Retry-After": "30" });
      return json({ ok: false, error: "daily_limit" }, 429, { "Retry-After": "3600" });
    }
  }
  const uploadClaim = await env.DB.prepare(
    "UPDATE reports SET status='uploading',updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status IN ('received','stored')",
  ).bind(metadata.report_id).run();
  if ((uploadClaim.meta.changes ?? 0) !== 1) return await reportStateResponse(env, metadata.report_id);
  try {
    await env.REPORTS.put(key, bytes, { httpMetadata: { contentType: "application/zip", contentDisposition: `attachment; filename="feedback-${metadata.report_id}.zip"` },
      customMetadata: { report_id: metadata.report_id, sha256: metadata.bundle_sha256 } });
  } catch (error) {
    await env.DB.prepare("UPDATE reports SET status='received',updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status='uploading'")
      .bind(metadata.report_id).run();
    throw error;
  }
  const stored = await env.DB.prepare("UPDATE reports SET status='stored',updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status='uploading'")
    .bind(metadata.report_id).run();
  if ((stored.meta.changes ?? 0) !== 1) {
    await env.REPORTS.delete(key);
    return await reportStateResponse(env, metadata.report_id);
  }
  const claim = await env.DB.prepare("UPDATE reports SET status='issuing',updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status='stored'")
    .bind(metadata.report_id).run();
  if ((claim.meta.changes ?? 0) !== 1) return await reportStateResponse(env, metadata.report_id);
  try {
    const issue = await findOrCreateIssue(env, metadata, existing?.expires_at ?? expires);
    const completed = await env.DB.prepare(
      "UPDATE reports SET status='completed',issue_number=?,issue_url=?,updated_at=CURRENT_TIMESTAMP WHERE report_id=? AND status='issuing'",
    ).bind(issue.number, issue.html_url, metadata.report_id).run();
    if ((completed.meta.changes ?? 0) !== 1) return await reportStateResponse(env, metadata.report_id);
    console.log(JSON.stringify({ event: "feedback_report_created", report_id: metadata.report_id,
      build_id: metadata.build.build_id, status: "completed", bundle_bytes: bytes.byteLength,
      issue_number: issue.number, latency_ms: Date.now() - started }));
    return json({ ok: true, report_id: metadata.report_id, issue_number: issue.number, issue_url: issue.html_url }, 201);
  } catch (error) {
    throw error;
  }
}

async function reportStateResponse(env: Env, reportId: string): Promise<Response> {
  const row = await env.DB.prepare(
    "SELECT status,issue_number,issue_url FROM reports WHERE report_id=?",
  ).bind(reportId).first<Pick<ReportRow, "status" | "issue_number" | "issue_url">>();
  if (row?.status === "expiring" || row?.status === "expired") {
    return json({ ok: false, report_id: reportId, error: "report_expired" }, 410);
  }
  if (row?.status === "completed") {
    return json({ ok: true, report_id: reportId, issue_number: row.issue_number, issue_url: row.issue_url }, 200);
  }
  return json({ ok: false, report_id: reportId, error: "issue_in_progress" }, 202, { "Retry-After": "30" });
}

async function authorizeInvite(request: Request, env: Env): Promise<{ invite: InviteRow; tokenHash: string }> {
  const auth = request.headers.get("authorization") ?? "";
  if (!auth.startsWith("Bearer ")) throw new RelayError("missing_invite_token", 401);
  const tokenHash = await sha256Hex(auth.slice(7));
  const invite = await env.DB.prepare(
    "SELECT tester_id,nickname,token_hash,cohort_id FROM invites WHERE token_hash=? AND revoked_at IS NULL",
  ).bind(tokenHash).first<InviteRow>();
  if (!invite) throw new RelayError("invalid_invite_token", 401);
  return { invite, tokenHash };
}

async function boundedFormData(request: Request): Promise<FormData> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_MULTIPART_BYTES) throw payloadTooLarge("payload_too_large");
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.startsWith("multipart/form-data")) throw badRequest("invalid_multipart");
  if (!request.body) throw badRequest("invalid_multipart");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const next = await reader.read();
    if (next.done) break;
    total += next.value.byteLength;
    if (total > MAX_MULTIPART_BYTES) {
      await reader.cancel();
      throw payloadTooLarge("payload_too_large");
    }
    chunks.push(next.value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return await new Response(bytes, { headers: { "Content-Type": contentType } }).formData();
}

async function adminRoute(request: Request, env: Env, url: URL): Promise<Response> {
  const auth = request.headers.get("authorization") ?? "";
  const presented = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  const configured = env.ADMIN_TOKEN ?? "";
  if (configured.length < 32 || !presented || !constantTimeEqual(presented, configured)) return json({ ok: false, error: "unauthorized" }, 401);
  if (request.method === "PUT" && url.pathname === "/v1/admin/updates") {
    return await publishUpdate(request, env);
  }
  if (request.method === "POST" && url.pathname === "/v1/admin/invites") {
    const body = await request.json() as Record<string, unknown>;
    const testerId = String(body.tester_id ?? "");
    const nickname = String(body.nickname ?? "").trim().slice(0, 100);
    const tokenHash = String(body.token_hash ?? "");
    const cohortId = String(body.cohort_id ?? "friends-1");
    if (!/^[A-Z0-9-]{3,24}$/.test(testerId) || !nickname || !/^[0-9a-f]{64}$/.test(tokenHash) || !/^[a-z0-9-]{1,40}$/.test(cohortId)) {
      return json({ ok: false, error: "invalid_invite" }, 400);
    }
    const existing = await env.DB.prepare("SELECT revoked_at FROM invites WHERE tester_id=?")
      .bind(testerId).first<{ revoked_at: string | null }>();
    if (existing?.revoked_at) {
      return json({ ok: false, error: "invite_revoked" }, 409);
    }
    await env.DB.prepare("INSERT INTO invites(tester_id,nickname,token_hash,cohort_id) VALUES(?,?,?,?) ON CONFLICT(tester_id) DO UPDATE SET nickname=excluded.nickname,token_hash=excluded.token_hash,cohort_id=excluded.cohort_id")
      .bind(testerId, nickname, tokenHash, cohortId).run();
    return json({ ok: true, tester_id: testerId }, 201);
  }
  const inviteMatch = url.pathname.match(/^\/v1\/admin\/invites\/([A-Z0-9-]+)$/);
  if (request.method === "DELETE" && inviteMatch) {
    await env.DB.prepare("UPDATE invites SET revoked_at=CURRENT_TIMESTAMP WHERE tester_id=?").bind(inviteMatch[1]).run();
    return json({ ok: true });
  }
  const reportMatch = url.pathname.match(/^\/v1\/admin\/reports\/([0-9a-f-]+)\/bundle$/);
  if (request.method === "GET" && reportMatch) {
    const row = await env.DB.prepare("SELECT status,bundle_key,bundle_sha256 FROM reports WHERE report_id=?")
      .bind(reportMatch[1]).first<{ status: ReportRow["status"]; bundle_key: string; bundle_sha256: string }>();
    if (!row) return json({ ok: false, error: "not_found" }, 404);
    if (row.status === "expiring" || row.status === "expired") return json({ ok: false, error: "artifact_expired" }, 410);
    const object = await env.REPORTS.get(row.bundle_key);
    if (!object) return json({ ok: false, error: "artifact_expired" }, 410);
    return new Response(object.body, { headers: { "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="feedback-${reportMatch[1]}.zip"`, "X-Content-SHA256": row.bundle_sha256,
      "Cache-Control": "private, no-store" } });
  }
  return json({ ok: false, error: "not_found" }, 404);
}

async function serveUpdateArtifact(env: Env, channel: string, buildId: string, os: string): Promise<Response> {
  const key = artifactKey(channel, buildId, os);
  if (!key.startsWith("updates/")) return json({ ok: false, error: "not_found" }, 404);
  const object = await env.REPORTS.get(key);
  if (!object) return json({ ok: false, error: "not_found" }, 404);
  return new Response(object.body, { status: 200, headers: {
    "Content-Type": "application/octet-stream",
    "Content-Disposition": `attachment; filename="PokeWilds-${os}"`,
    "Cache-Control": "public, max-age=3600",
  } });
}

async function latestUpdate(_request: Request, env: Env, url: URL): Promise<Response> {
  const channel = parseChannel(url.searchParams.get("channel"));
  const object = await env.REPORTS.get(latestKey(channel));
  if (!object) return json({ ok: false, error: "not_found" }, 404);
  return new Response(object.body, { status: 200, headers: { "Content-Type": "application/json",
    "Cache-Control": "no-store" } });
}

async function publishUpdate(request: Request, env: Env): Promise<Response> {
  const manifest = parseManifest(await request.json());
  for (const os of Object.keys(manifest.builds)) {
    const key = artifactKey(manifest.channel, manifest.build_id, os);
    const object = await env.REPORTS.head(key);
    if (!object) return json({ ok: false, error: "artifact_missing" }, 400);
  }
  await env.REPORTS.put(latestKey(manifest.channel), JSON.stringify(manifest), {
    httpMetadata: { contentType: "application/json" },
  });
  return json({ ok: true, build_id: manifest.build_id, channel: manifest.channel }, 201);
}

function json(value: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store", ...extra } });
}

function classifyError(error: unknown): { error: string; status: number } {
  if (error instanceof RelayError) return { error: error.code, status: error.status };
  return { error: "internal_error", status: 500 };
}
