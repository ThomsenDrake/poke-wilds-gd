import type { Env, ReportMetadata } from "./types";
import { issueTitle, sanitizePublicText } from "./security";
import { upstreamUnavailable } from "./errors";

let cachedToken = "";
let cachedUntil = 0;

export async function findOrCreateIssue(env: Env, metadata: ReportMetadata, expiresAt: string): Promise<{ number: number; html_url: string }> {
  const token = await installationToken(env);
  const existing = await findIssue(env, token, metadata.report_id);
  if (existing) return existing;
  const response = await githubFetch(env, `/repos/${env.GITHUB_REPOSITORY}/issues`, token, {
    method: "POST",
    body: JSON.stringify({
      title: issueTitle(metadata.message),
      labels: ["playtest-feedback", "needs-triage"],
      body: issueBody(metadata, expiresAt),
    }),
  });
  if (!response.ok) throw upstreamUnavailable();
  return await response.json() as { number: number; html_url: string };
}

export function issueBody(metadata: ReportMetadata, expiresAt: string = new Date(Date.now() + 180 * 86400_000).toISOString()): string {
	const expires = new Date(expiresAt).toISOString().slice(0, 10);
	const screen = sanitizePublicText(metadata.game.current_screen);
	const platform = sanitizePublicText(metadata.runtime.os_name);
	return `<!-- feedback-report-id:${metadata.report_id} -->\n` +
    `## Player report\n\n${sanitizePublicText(metadata.message)}\n\n` +
    `## Agent handoff\n\n` +
    `| Field | Value |\n|---|---|\n` +
    `| Report | \`${metadata.report_id}\` |\n` +
    `| Tester | \`${metadata.tester_id}\` |\n` +
    `| Build | \`${sanitizePublicText(metadata.build.build_id)}\` |\n` +
    `| Commit | \`${sanitizePublicText(metadata.build.commit_sha)}\` |\n` +
		`| Platform | ${platform} |\n| Screen | ${screen} |\n\n` +
    `Private reproduction bundle (expires ${expires}):\n\n` +
    `\`python3 tools/fetch_feedback_report.py ${metadata.report_id}\`\n`;
}

async function findIssue(env: Env, token: string, reportId: string): Promise<{ number: number; html_url: string } | null> {
  const query = encodeURIComponent(`repo:${env.GITHUB_REPOSITORY} in:body "feedback-report-id:${reportId}"`);
  const response = await githubFetch(env, `/search/issues?q=${query}`, token);
  if (!response.ok) throw upstreamUnavailable();
  const result = await response.json() as { items?: Array<{ number: number; html_url: string }> };
  return result.items?.[0] ?? null;
}

async function installationToken(env: Env): Promise<string> {
  if (cachedToken && cachedUntil > Date.now() + 60_000) return cachedToken;
  const jwt = await appJwt(env.GITHUB_APP_ID, env.GITHUB_PRIVATE_KEY);
  const response = await githubFetch(env, `/app/installations/${env.GITHUB_INSTALLATION_ID}/access_tokens`, jwt, { method: "POST" });
  if (!response.ok) throw upstreamUnavailable();
  const result = await response.json() as { token: string; expires_at: string };
  cachedToken = result.token;
  cachedUntil = Date.parse(result.expires_at);
  return cachedToken;
}

async function appJwt(appId: string, pem: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const encodedHeader = base64Url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const encodedPayload = base64Url(new TextEncoder().encode(JSON.stringify({ iat: now - 60, exp: now + 480, iss: appId })));
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (char) => char.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function githubFetch(env: Env, path: string, token: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/vnd.github+json");
  headers.set("Authorization", `Bearer ${token}`);
  headers.set("X-GitHub-Api-Version", "2022-11-28");
  headers.set("User-Agent", "poke-wilds-feedback-relay");
  if (init.body) headers.set("Content-Type", "application/json");
  return fetch(`${env.GITHUB_API_BASE ?? "https://api.github.com"}${path}`, { ...init, headers });
}
