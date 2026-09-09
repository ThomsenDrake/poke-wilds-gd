import { badRequest, RelayError } from "./errors";
import { sha256Hex } from "./security";
import type { Env, InviteRow, ReportMetadata } from "./types";

const PUBLIC_TESTER_ID = "PUBLIC-ALPHA";
const PUBLIC_CHANNELS = new Set(["public", "playtest"]);

type ReportIdentity = { testerId: string; cohortId: string };
type ReportAccess =
  | { kind: "public"; rateLimitKey: string }
  | { kind: "invited"; rateLimitKey: string; identity: ReportIdentity };

export async function authorizeReport(request: Request, env: Env): Promise<ReportAccess> {
  // A supplied but invalid credential must never bypass invitation revocation.
  if (request.headers.has("authorization")) {
    const auth = request.headers.get("authorization") ?? "";
    if (!auth.startsWith("Bearer ") || !auth.slice(7).trim()) {
      throw new RelayError("missing_invite_token", 401);
    }
    const tokenHash = await sha256Hex(auth.slice(7));
    const invite = await env.DB.prepare(
      "SELECT tester_id,nickname,token_hash,cohort_id FROM invites WHERE token_hash=? AND revoked_at IS NULL",
    ).bind(tokenHash).first<InviteRow>();
    if (!invite) throw new RelayError("invalid_invite_token", 401);
    return {
      kind: "invited",
      rateLimitKey: `${invite.tester_id}:${tokenHash}`,
      identity: { testerId: invite.tester_id, cohortId: invite.cohort_id },
    };
  }

  // Cloudflare supplies this address. Do not trust a client-selected forwarded
  // header or collapse missing addresses into one shared anonymous limit.
  const address = request.headers.get("CF-Connecting-IP")?.trim().toLowerCase();
  if (!address || address.length > 64 || !/^[0-9a-f:.]+$/.test(address)) {
    throw badRequest("client_address_required");
  }
  return { kind: "public", rateLimitKey: `public:${await sha256Hex(address)}` };
}

export function reportIdentity(access: ReportAccess, metadata: ReportMetadata): ReportIdentity {
  if (access.kind === "invited") {
    if (metadata.tester_id !== access.identity.testerId) throw badRequest("tester_mismatch");
    if (metadata.build.channel !== access.identity.cohortId) throw badRequest("cohort_mismatch");
    return access.identity;
  }
  // The stamp labels public alpha reports; it is not proof of a trusted binary.
  if (metadata.tester_id !== PUBLIC_TESTER_ID) throw badRequest("tester_mismatch");
  if (!PUBLIC_CHANNELS.has(metadata.build.channel)) throw badRequest("cohort_mismatch");
  return { testerId: PUBLIC_TESTER_ID, cohortId: metadata.build.channel };
}
