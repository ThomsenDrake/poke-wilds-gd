import { strFromU8, unzipSync } from "fflate";
import type { ReportMetadata } from "./types";

export const MAX_COMPRESSED_BYTES = 16 * 1024 * 1024;
export const MAX_UNCOMPRESSED_BYTES = 24 * 1024 * 1024;
export const MAX_METADATA_BYTES = 64 * 1024;

const REQUIRED = new Set([
  "README.txt", "engine.log", "report.json", "save.json", "trace.jsonl", "ui-tree.json",
]);
const OPTIONAL = new Set(["screenshot.png"]);
const REPORT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const EOCD_SIGNATURE = 0x06054b50;
const CENTRAL_SIGNATURE = 0x02014b50;
const LOCAL_SIGNATURE = 0x04034b50;

type ZipEntry = {
  name: string;
  crc32: number;
  compressed: number;
  uncompressed: number;
  localOffset: number;
  flags: number;
  method: number;
};

export async function sha256Hex(value: ArrayBuffer | Uint8Array | string): Promise<string> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const buffer: ArrayBuffer = bytes instanceof Uint8Array
    ? new Uint8Array(bytes).buffer
    : bytes;
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", buffer))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function validateMetadata(value: unknown): ReportMetadata {
  if (!isObject(value)) throw new Error("metadata_not_object");
  const data = value as Partial<ReportMetadata>;
  validateReportFields(data);
  if (!SHA256.test(String(data.bundle_sha256 ?? ""))) throw new Error("invalid_bundle_hash");
  if (!Number.isInteger(data.bundle_bytes) || Number(data.bundle_bytes) < 1 || Number(data.bundle_bytes) > MAX_COMPRESSED_BYTES) {
    throw new Error("invalid_bundle_size");
  }
  return data as ReportMetadata;
}

export async function inspectBundle(bytes: Uint8Array, metadata: ReportMetadata): Promise<Record<string, unknown>> {
  const entries = centralDirectoryEntries(bytes);
  const names = new Set(entries.map((entry) => entry.name));
  if (entries.length < REQUIRED.size || entries.length > REQUIRED.size + OPTIONAL.size) throw new Error("invalid_entry_count");
  for (const name of REQUIRED) if (!names.has(name)) throw new Error(`missing_${name}`);
  for (const name of names) if (!REQUIRED.has(name) && !OPTIONAL.has(name)) throw new Error("unexpected_entry");
  if (metadata.capture.screenshot_available !== names.has("screenshot.png")) throw new Error("capture_screenshot_mismatch");
  if (entries.reduce((sum, entry) => sum + entry.uncompressed, 0) > MAX_UNCOMPRESSED_BYTES) throw new Error("bundle_uncompressed_too_large");
  let unpacked: Record<string, Uint8Array>;
  try {
    unpacked = unzipSync(bytes);
  } catch (_error) {
    throw new Error("invalid_zip");
  }
  if (Object.keys(unpacked).length !== entries.length) throw new Error("invalid_unpacked_entries");
  for (const entry of entries) {
    const payload = unpacked[entry.name];
    if (!payload || payload.byteLength !== entry.uncompressed) throw new Error(`zip_size_mismatch:${entry.name}`);
    if (crc32(payload) !== entry.crc32) throw new Error(`zip_crc_mismatch:${entry.name}`);
  }
  const raw = unpacked["report.json"];
  if (!raw || raw.byteLength > MAX_METADATA_BYTES) throw new Error("invalid_report_json");
  let report: Record<string, unknown>;
  try {
    report = JSON.parse(strFromU8(raw)) as Record<string, unknown>;
  } catch (_error) {
    throw new Error("invalid_report_json");
  }
  validateManifest(report, names);
  if (!manifestAgrees(report, metadata)) throw new Error("manifest_mismatch");
  const artifacts = report.artifacts as Array<Record<string, unknown>>;
  const expectedArtifacts = new Set([...names].filter((name) => name !== "report.json"));
  if (artifacts.length !== expectedArtifacts.size) throw new Error("artifact_manifest_mismatch");
  for (const artifact of artifacts) {
    const name = String(artifact.path ?? "");
    const payload = unpacked[name];
    if (!expectedArtifacts.delete(name) || !payload) throw new Error("artifact_manifest_mismatch");
    if (artifact.bytes !== payload.byteLength ||
        await sha256Hex(payload) !== artifact.sha256) throw new Error(`artifact_hash_mismatch:${name}`);
  }
  if (expectedArtifacts.size) throw new Error("artifact_manifest_mismatch");
  return report;
}

function validateManifest(report: Record<string, unknown>, names: Set<string>): void {
  validateReportFields(report);
  if (typeof report.created_at_utc !== "string" || !report.created_at_utc.trim() ||
      report.created_at_utc.length > 64 || !/^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?(?:\.\d+)?Z?$/.test(report.created_at_utc)) {
    throw new Error("invalid_created_at_utc");
  }
  if (!Array.isArray(report.artifacts)) throw new Error("invalid_artifacts");
  for (const artifact of report.artifacts) {
    if (!isObject(artifact) || typeof artifact.path !== "string" || !isSafeName(artifact.path) ||
        typeof artifact.bytes !== "number" || !Number.isInteger(artifact.bytes) || artifact.bytes < 0 ||
        !SHA256.test(String(artifact.sha256 ?? "")) ||
        typeof artifact.truncated !== "boolean") throw new Error("invalid_artifact");
  }
  const capture = report.capture as Record<string, unknown>;
  if (capture.screenshot_available !== names.has("screenshot.png")) throw new Error("capture_screenshot_mismatch");
}

function validateReportFields(data: Record<string, unknown> | Partial<ReportMetadata>): void {
  if (data.schema_version !== 1) throw new Error("unsupported_schema");
  if (!REPORT_ID.test(String(data.report_id ?? ""))) throw new Error("invalid_report_id");
  if (typeof data.message !== "string" || data.message.trim().length < 1 || data.message.length > 1000) {
    throw new Error("invalid_message");
  }
  if (!/^[A-Z0-9-]{3,24}$/.test(String(data.tester_id ?? ""))) throw new Error("invalid_tester_id");
  if (!/^[0-9a-f]{32}$/.test(String(data.install_id ?? ""))) throw new Error("invalid_install_id");
  if (!isBuild(data.build)) throw new Error("invalid_build");
  if (!isRuntime(data.runtime) || !isGame(data.game)) throw new Error("invalid_runtime_or_game");
  if (!isCapture(data.capture, data.game)) throw new Error("invalid_capture");
}

function isBuild(value: unknown): value is Record<string, unknown> {
  return isObject(value) && typeof value.version === "string" && value.version.length > 0 && value.version.length <= 128 &&
    /^[A-Za-z0-9._-]{1,128}$/.test(String(value.build_id ?? "")) &&
    /^[a-z0-9-]{1,40}$/.test(String(value.channel ?? "")) &&
    /^(unknown|[0-9a-f]{7,64})$/.test(String(value.commit_sha ?? ""));
}

function isRuntime(value: unknown): value is Record<string, unknown> {
  if (!isObject(value) || !isIntegerPair(value.window_size)) return false;
  return ["godot_version", "os_name", "os_version", "architecture", "locale", "renderer", "adapter"]
    .every((field) => typeof value[field] === "string" && (value[field] as string).length <= 256);
}

function isGame(value: unknown): value is Record<string, unknown> {
  return isObject(value) && typeof value.current_screen === "string" && value.current_screen.trim().length > 0 &&
    value.current_screen.length <= 128 && Number.isInteger(value.world_seed) && isIntegerPair(value.player_tile) &&
    typeof value.active_area === "string" && typeof value.time_of_day_minutes === "number" &&
    Number.isFinite(value.time_of_day_minutes) && Number.isInteger(value.total_steps) && Array.isArray(value.party) &&
    isObject(value.bag) && typeof value.battle_active === "boolean";
}

function isCapture(value: unknown, game: unknown): value is Record<string, unknown> {
  return isObject(value) && isObject(game) && typeof value.screenshot_available === "boolean" &&
    typeof value.screen === "string" && Boolean(value.screen.trim()) && value.screen.length <= 128 &&
    value.screen === game.current_screen;
}

function isIntegerPair(value: unknown): value is [number, number] {
  return Array.isArray(value) && value.length === 2 && value.every(Number.isInteger);
}

export function sanitizePublicText(value: string): string {
  return value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .trim().slice(0, 1000).replaceAll("@", "@\u200b");
}

export function issueTitle(message: string): string {
  const first = sanitizePublicText(message).split(/(?<=[.!?])\s|\n/, 1)[0] || "Playtest report";
  return `[Playtest] ${first.slice(0, 90)}`;
}

export function constantTimeEqual(left: string, right: string): boolean {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  let diff = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i++) diff |= (a[i % Math.max(a.length, 1)] ?? 0) ^ (b[i % Math.max(b.length, 1)] ?? 0);
  return diff === 0;
}

function manifestAgrees(report: Record<string, unknown>, metadata: ReportMetadata): boolean {
  return report.schema_version === metadata.schema_version && report.report_id === metadata.report_id &&
    report.message === metadata.message && report.tester_id === metadata.tester_id &&
    report.install_id === metadata.install_id && sameJson(report.build, metadata.build) &&
    sameJson(report.runtime, metadata.runtime) && sameJson(report.game, metadata.game) &&
    sameJson(report.capture, metadata.capture);
}

function sameJson(left: unknown, right: unknown): boolean {
  if (!isJsonValue(left) || !isJsonValue(right)) return false;
  if (left === null || right === null || typeof left !== "object" || typeof right !== "object") return left === right;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) && left.length === right.length &&
      left.every((value, index) => sameJson(value, right[index]));
  }
  const leftObject = left as Record<string, unknown>;
  const rightObject = right as Record<string, unknown>;
  const leftKeys = Object.keys(leftObject).sort();
  const rightKeys = Object.keys(rightObject).sort();
  return leftKeys.length === rightKeys.length && leftKeys.every((key, index) =>
    key === rightKeys[index] && sameJson(leftObject[key], rightObject[key]));
}

function isJsonValue(value: unknown): boolean {
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(isJsonValue);
  if (!isObject(value)) return false;
  return Object.keys(value).every((key) => isJsonValue(value[key]));
}

function isObject(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function centralDirectoryEntries(bytes: Uint8Array): ZipEntry[] {
  if (bytes.byteLength < 22) throw new Error("invalid_zip");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const eocd = findEocd(view, bytes.byteLength);
  if (eocd >= 20 && view.getUint32(eocd - 20, true) === 0x07064b50) throw new Error("zip64_unsupported");
  if (view.getUint16(eocd + 4, true) !== 0 || view.getUint16(eocd + 6, true) !== 0) throw new Error("zip_multidisk");
  const entriesOnDisk = view.getUint16(eocd + 8, true);
  const entriesTotal = view.getUint16(eocd + 10, true);
  const directorySize = view.getUint32(eocd + 12, true);
  const directoryOffset = view.getUint32(eocd + 16, true);
  if (entriesOnDisk !== entriesTotal) throw new Error("zip_multidisk");
  if (entriesTotal === 0xffff || directorySize === 0xffffffff || directoryOffset === 0xffffffff) throw new Error("zip64_unsupported");
  const directoryEnd = directoryOffset + directorySize;
  if (directoryEnd !== eocd || directoryEnd < directoryOffset) throw new Error("invalid_zip_directory");
  const entries: ZipEntry[] = [];
  let offset = directoryOffset;
  for (let index = 0; index < entriesTotal; index++) {
    if (offset + 46 > directoryEnd || view.getUint32(offset, true) !== CENTRAL_SIGNATURE) throw new Error("invalid_zip_directory");
    const flags = view.getUint16(offset + 8, true);
    const method = view.getUint16(offset + 10, true);
    const crc32 = view.getUint32(offset + 16, true);
    const compressed = view.getUint32(offset + 20, true);
    const uncompressed = view.getUint32(offset + 24, true);
    const nameLength = view.getUint16(offset + 28, true);
    const extraLength = view.getUint16(offset + 30, true);
    const commentLength = view.getUint16(offset + 32, true);
    const diskStart = view.getUint16(offset + 34, true);
    const externalAttributes = view.getUint32(offset + 38, true);
    const localOffset = view.getUint32(offset + 42, true);
    const entryEnd = offset + 46 + nameLength + extraLength + commentLength;
    if (entryEnd > directoryEnd || diskStart !== 0) throw new Error("invalid_zip_directory");
    if (compressed === 0xffffffff || uncompressed === 0xffffffff || localOffset === 0xffffffff || hasZip64Extra(bytes, offset + 46 + nameLength, extraLength)) {
      throw new Error("zip64_unsupported");
    }
    if (flags & ~0x0800) throw new Error("unsupported_zip_flags");
    if (method !== 0 && method !== 8) throw new Error("unsupported_zip_method");
    const unixFileType = (externalAttributes >>> 16) & 0xf000;
    if ((externalAttributes & 0x10) !== 0 || (unixFileType !== 0 && unixFileType !== 0x8000)) {
      throw new Error("unsafe_entry_type");
    }
    const name = new TextDecoder().decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
    if (!isSafeName(name)) throw new Error("unsafe_entry_name");
    entries.push({ name, crc32, compressed, uncompressed, localOffset, flags, method });
    offset = entryEnd;
  }
  if (offset !== directoryEnd || entries.length !== entriesTotal) throw new Error("invalid_zip_directory");
  if (new Set(entries.map((entry) => entry.name)).size !== entries.length) throw new Error("duplicate_zip_entry");
  validateLocalHeaders(bytes, view, entries, directoryOffset);
  return entries;
}

function findEocd(view: DataView, length: number): number {
  const start = Math.max(0, length - 22 - 0xffff);
  for (let offset = length - 22; offset >= start; offset--) {
    if (view.getUint32(offset, true) !== EOCD_SIGNATURE) continue;
    const commentLength = view.getUint16(offset + 20, true);
    if (offset + 22 + commentLength === length) return offset;
  }
  throw new Error("missing_zip_eocd");
}

function hasZip64Extra(bytes: Uint8Array, offset: number, length: number): boolean {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let cursor = offset;
  const end = offset + length;
  while (cursor + 4 <= end) {
    const id = view.getUint16(cursor, true);
    const size = view.getUint16(cursor + 2, true);
    cursor += 4;
    if (cursor + size > end) throw new Error("invalid_zip_extra");
    if (id === 0x0001) return true;
    cursor += size;
  }
  if (cursor !== end) throw new Error("invalid_zip_extra");
  return false;
}

function validateLocalHeaders(bytes: Uint8Array, view: DataView, entries: ZipEntry[], directoryOffset: number): void {
  const ranges: Array<[number, number]> = [];
  for (const entry of entries) {
    const offset = entry.localOffset;
    if (offset + 30 > directoryOffset || view.getUint32(offset, true) !== LOCAL_SIGNATURE) throw new Error("invalid_local_header");
    const flags = view.getUint16(offset + 6, true);
    const method = view.getUint16(offset + 8, true);
    const crc32 = view.getUint32(offset + 14, true);
    const compressed = view.getUint32(offset + 18, true);
    const uncompressed = view.getUint32(offset + 22, true);
    const nameLength = view.getUint16(offset + 26, true);
    const extraLength = view.getUint16(offset + 28, true);
    const dataStart = offset + 30 + nameLength + extraLength;
    const dataEnd = dataStart + entry.compressed;
    if (dataEnd > directoryOffset || flags !== entry.flags || method !== entry.method || crc32 !== entry.crc32 ||
        compressed !== entry.compressed || uncompressed !== entry.uncompressed) throw new Error("local_header_mismatch");
    const name = new TextDecoder().decode(bytes.subarray(offset + 30, offset + 30 + nameLength));
    if (name !== entry.name || hasZip64Extra(bytes, offset + 30 + nameLength, extraLength)) throw new Error("local_header_mismatch");
    ranges.push([offset, dataEnd]);
  }
  ranges.sort((left, right) => left[0] - right[0]);
  for (let index = 1; index < ranges.length; index++) if (ranges[index][0] < ranges[index - 1][1]) throw new Error("overlapping_zip_entries");
}

function crc32(bytes: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function isSafeName(name: string): boolean {
  return Boolean(name) && !name.includes("/") && !name.includes("\\") && !name.includes("..") && !name.endsWith("/");
}
