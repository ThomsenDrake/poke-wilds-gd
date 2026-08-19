import { badRequest } from "./errors";

const OS_KEYS = ["linux", "windows", "macos"] as const;
const SHA256 = /^[0-9a-f]{64}$/;
const CHANNEL = /^[a-z0-9-]{1,40}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const BUILD_ID = /^[A-Za-z0-9._:-]{1,80}$/;
const PUBLISHED = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

export type UpdateOs = (typeof OS_KEYS)[number];

export interface UpdateBuild {
  url: string;
  sha256: string;
  bytes: number;
  filename: string;
}

export interface UpdateManifest {
  schema_version: 1;
  channel: string;
  published_at: string;
  build_id: string;
  commit_sha: string;
  min_save_version: number;
  builds: Record<UpdateOs, UpdateBuild>;
}

export function latestKey(channel: string): string {
  return `updates/${channel}/latest.json`;
}

export function artifactKey(channel: string, buildId: string, os: string): string {
  return `updates/${channel}/${buildId}/${os}`;
}

export function parseChannel(value: string | null): string {
  const channel = value || "playtest";
  if (!CHANNEL.test(channel)) throw badRequest("invalid_channel");
  return channel;
}

export function parseManifest(value: unknown): UpdateManifest {
  if (!value || typeof value !== "object") throw badRequest("invalid_manifest");
  const body = value as Record<string, unknown>;
  if (Number(body.schema_version) !== 1) throw badRequest("invalid_manifest");
  const channel = String(body.channel ?? "");
  const published = String(body.published_at ?? "");
  const buildId = String(body.build_id ?? "");
  const commit = String(body.commit_sha ?? "").toLowerCase();
  const minSave = Number(body.min_save_version);
  if (!CHANNEL.test(channel) || !PUBLISHED.test(published) || !BUILD_ID.test(buildId) || !COMMIT.test(commit)) {
    throw badRequest("invalid_manifest");
  }
  if (!Number.isInteger(minSave) || minSave < 1) throw badRequest("invalid_manifest");
  if (!body.builds || typeof body.builds !== "object") throw badRequest("invalid_manifest");
  const builds = {} as Record<UpdateOs, UpdateBuild>;
  for (const os of OS_KEYS) {
    builds[os] = parseBuild((body.builds as Record<string, unknown>)[os]);
  }
  return {
    schema_version: 1, channel, published_at: published, build_id: buildId,
    commit_sha: commit, min_save_version: minSave, builds,
  };
}

function parseBuild(value: unknown): UpdateBuild {
  if (!value || typeof value !== "object") throw badRequest("checksum_missing");
  const body = value as Record<string, unknown>;
  const url = String(body.url ?? "").trim();
  const digest = String(body.sha256 ?? "").toLowerCase();
  const filename = String(body.filename ?? "");
  const bytes = Number(body.bytes);
  if (!SHA256.test(digest)) throw badRequest("checksum_missing");
  if (!Number.isInteger(bytes) || bytes < 1 || !filename || filename.includes("/") || filename.includes("\\")) {
    throw badRequest("invalid_manifest");
  }
  if (!url.toLowerCase().startsWith("https://") || /[?#@\\]/.test(url)) throw badRequest("invalid_manifest");
  return { url, sha256: digest, bytes, filename };
}
