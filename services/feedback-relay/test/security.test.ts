import { zipSync, strToU8 } from "fflate";
import { describe, expect, it } from "vitest";
import { inspectBundle, issueTitle, sanitizePublicText, sha256Hex, validateMetadata } from "../src/security";
import { issueBody } from "../src/github";
import { RelayError } from "../src/errors";
import type { ReportMetadata } from "../src/types";

const reportId = "01234567-89ab-cdef-0123-456789abcdef";

function metadata(): ReportMetadata {
  return {
    schema_version: 1, report_id: reportId, message: "I got stuck @maintainer.", tester_id: "T-4K7",
    install_id: "a".repeat(32), build: { version: "0.0.0", commit_sha: "b".repeat(40), build_id: "beta-1", channel: "friends" },
    runtime: { godot_version: "4.6", os_name: "macOS", os_version: "15", architecture: "arm64", locale: "en_US",
      renderer: "gl_compatibility", adapter: "Apple", window_size: [1152, 648] },
    game: { current_screen: "overworld", world_seed: 7, player_tile: [17, 28], active_area: "field",
      time_of_day_minutes: 480, total_steps: 32, party: [{ species_id: "geodude", stats: [40, 80] }],
      bag: { pockets: [{ name: "items", slots: [{ id: "potion", count: 2 }] }] }, battle_active: false },
    capture: { screenshot_available: false, screen: "overworld" },
    bundle_sha256: "0".repeat(64), bundle_bytes: 1,
  };
}

function bundle(meta: ReportMetadata = metadata(), readme = "start with report.json",
  patch: Record<string, unknown> = {}, screenshot = false) {
  const contents: Record<string, Uint8Array> = {
    "trace.jsonl": strToU8("{}\n"), "engine.log": strToU8("ok"),
    "save.json": strToU8("{}"), "ui-tree.json": strToU8("{}"),
    "README.txt": strToU8(readme),
  };
  if (screenshot) contents["screenshot.png"] = strToU8("not-a-real-png");
  const artifacts = Object.entries(contents).map(([path, bytes]) => ({
    path, bytes: bytes.byteLength, sha256: "", truncated: false,
  }));
  return Promise.all(artifacts.map(async (entry, index) => {
    artifacts[index].sha256 = await sha256Hex(contents[entry.path as keyof typeof contents]);
  })).then(() => zipSync({ ...contents,
    "report.json": strToU8(JSON.stringify({ schema_version: 1, report_id: meta.report_id,
      created_at_utc: "2026-08-12T12:34:56Z", message: meta.message,
      tester_id: meta.tester_id, install_id: meta.install_id, build: meta.build, runtime: meta.runtime, game: meta.game,
      capture: meta.capture, artifacts, ...patch })),
  }, { level: 0 }));
}

describe("feedback relay contracts", () => {
  it("validates metadata, checksums, and the exact safe bundle entry set", async () => {
    const meta = validateMetadata(metadata());
    expect((await inspectBundle(await bundle(), meta)).report_id).toBe(reportId);
  });

  it("rejects traversal, missing entries, and manifest mismatches", async () => {
    const meta = validateMetadata(metadata());
    await expect(inspectBundle(zipSync({ "../report.json": strToU8("{}") }), meta)).rejects.toThrow();
    await expect(inspectBundle(zipSync({ "report.json": strToU8("{}") }), meta)).rejects.toThrow();
    await expect(inspectBundle(await bundle({ ...metadata(), message: "different" }), meta)).rejects.toThrow("manifest_mismatch");
    await expect(inspectBundle(await bundle({ ...metadata(), runtime: { ...metadata().runtime, os_name: "other" } }), meta)).rejects.toThrow("manifest_mismatch");
    await expect(inspectBundle(await bundle({ ...metadata(), game: { ...metadata().game,
      bag: { pockets: [{ name: "items", slots: [{ id: "potion", count: 3 }] }] } } }), meta)).rejects.toThrow("manifest_mismatch");
  });

  it("accepts production-shaped recursive JSON agreement", async () => {
    const meta = validateMetadata(metadata());
    expect(await inspectBundle(await bundle(meta), meta)).toMatchObject({ runtime: meta.runtime, game: meta.game });
  });

  it("rejects corrupted artifact bytes", async () => {
    const meta = validateMetadata(metadata());
    const valid = await bundle();
    const report = await inspectBundle(valid, meta);
    const tampered = zipSync({
      "report.json": strToU8(JSON.stringify(report)), "trace.jsonl": strToU8("changed\n"),
      "engine.log": strToU8("ok"), "save.json": strToU8("{}"), "ui-tree.json": strToU8("{}"),
      "README.txt": strToU8("start with report.json"),
    });
    await expect(inspectBundle(tampered, meta)).rejects.toThrow("artifact_hash_mismatch");
  });

  it("neutralizes mentions in public issue text", () => {
    const meta = metadata();
    expect(sanitizePublicText(meta.message)).toContain("@\u200bmaintainer");
    expect(issueTitle(meta.message)).toMatch(/^\[Playtest\]/);
    expect(issueBody(meta)).not.toContain("@maintainer");
    expect(issueBody(meta)).toContain(`feedback-report-id:${reportId}`);
    expect(issueBody(meta)).not.toContain("State");
    expect(issueBody({ ...meta, game: { ...meta.game, party: ["private"], player_tile: [1, 2] } })).not.toContain("private");
    expect(issueBody(meta, "2030-01-02T03:04:05.000Z")).toContain("expires 2030-01-02");
  });

  it("hashes byte-identically", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });

  it("rejects malformed metadata bounds", () => {
    expect(() => validateMetadata({ ...metadata(), message: "" })).toThrow("invalid_message");
    expect(() => validateMetadata({ ...metadata(), message: "😀".repeat(1000) })).not.toThrow();
    expect(() => validateMetadata({ ...metadata(), message: "😀".repeat(1001) })).toThrow("invalid_message");
    expect(() => validateMetadata({ ...metadata(), bundle_bytes: 16 * 1024 * 1024 + 1 })).toThrow("invalid_bundle_size");
    expect(() => validateMetadata({ ...metadata(), capture: { screenshot_available: false, screen: "title" } })).toThrow("invalid_capture");
  });

  it("attaches explicit client statuses to metadata and bundle validation failures", async () => {
    try {
      validateMetadata([]);
      throw new Error("metadata validation unexpectedly passed");
    } catch (error) {
      expect(error).toBeInstanceOf(RelayError);
      expect(error).toMatchObject({ code: "metadata_not_object", status: 400 });
    }
    const meta = validateMetadata(metadata());
    const valid = await bundle();
    const bomb = new Uint8Array(valid);
    const bombView = new DataView(bomb.buffer);
    const central = bombView.getUint32(findEocd(bomb) + 16, true);
    const local = bombView.getUint32(central + 42, true);
    bombView.setUint32(central + 24, 0x02000000, true);
    bombView.setUint32(local + 22, 0x02000000, true);
    await expect(inspectBundle(bomb, meta)).rejects.toMatchObject({
      code: "bundle_uncompressed_too_large", status: 413,
    });
  });

  it("requires the complete v1 manifest and matching screenshot capture", async () => {
    const meta = validateMetadata(metadata());
    await expect(inspectBundle(await bundle(meta, "", { created_at_utc: undefined }), meta)).rejects.toThrow("invalid_created_at_utc");
    await expect(inspectBundle(await bundle(meta, "", { runtime: [] }), meta)).rejects.toThrow("invalid_runtime_or_game");
    await expect(inspectBundle(await bundle(meta, "", {
      artifacts: [{ path: "README.txt", bytes: 1, sha256: "0".repeat(64), truncated: "false" }],
    }), meta)).rejects.toThrow("invalid_artifact");
    await expect(inspectBundle(await bundle(meta, "", {}, true), meta)).rejects.toThrow("capture_screenshot_mismatch");
  });

  it("uses the EOCD directory rather than signatures inside file data", async () => {
    const meta = validateMetadata(metadata());
    const valid = await bundle(metadata(), "PK\x01\x02 is data, not a directory entry");
    expect([...valid].some((byte, index) => byte === 0x50 && valid[index + 1] === 0x4b && valid[index + 2] === 1 && valid[index + 3] === 2)).toBe(true);
    await expect(inspectBundle(valid, meta)).resolves.toMatchObject({ report_id: reportId });
  });

  it("rejects duplicate entries and declared bombs before decompression", async () => {
    const meta = validateMetadata(metadata());
    const valid = await bundle();
    const originalEocd = findEocd(valid);
    const originalView = new DataView(valid.buffer, valid.byteOffset, valid.byteLength);
    const central = originalView.getUint32(originalEocd + 16, true);
    const entryLength = 46 + originalView.getUint16(central + 28, true) +
      originalView.getUint16(central + 30, true) + originalView.getUint16(central + 32, true);
    const duplicate = new Uint8Array(valid.length + entryLength);
    duplicate.set(valid.slice(0, originalEocd));
    duplicate.set(valid.slice(central, central + entryLength), originalEocd);
    duplicate.set(valid.slice(originalEocd), originalEocd + entryLength);
    const eocd = originalEocd + entryLength;
    const view = new DataView(duplicate.buffer);
    view.setUint16(eocd + 8, originalView.getUint16(originalEocd + 8, true) + 1, true);
    view.setUint16(eocd + 10, originalView.getUint16(originalEocd + 10, true) + 1, true);
    view.setUint32(eocd + 12, originalView.getUint32(originalEocd + 12, true) + entryLength, true);
    await expect(inspectBundle(duplicate, meta)).rejects.toThrow("duplicate_zip_entry");
    const bomb = new Uint8Array(valid);
    const bombView = new DataView(bomb.buffer);
    const bombCentral = bombView.getUint32(findEocd(bomb) + 16, true);
    const bombLocal = bombView.getUint32(bombCentral + 42, true);
    bombView.setUint32(bombCentral + 24, 0x02000000, true);
    bombView.setUint32(bombLocal + 22, 0x02000000, true);
    await expect(inspectBundle(bomb, meta)).rejects.toThrow("bundle_uncompressed_too_large");
  });

  it("rejects unsupported methods and central/local/computed CRC mismatches", async () => {
    const meta = validateMetadata(metadata());
    const valid = await bundle();
    const central = centralOffset(valid);
    const local = new DataView(valid.buffer, valid.byteOffset, valid.byteLength).getUint32(central + 42, true);
    const unsupported = new Uint8Array(valid);
    const unsupportedView = new DataView(unsupported.buffer);
    unsupportedView.setUint16(central + 10, 99, true);
    unsupportedView.setUint16(local + 8, 99, true);
    await expect(inspectBundle(unsupported, meta)).rejects.toThrow("unsupported_zip_method");
    const mismatched = new Uint8Array(valid);
    new DataView(mismatched.buffer).setUint32(central + 16, 0x12345678, true);
    await expect(inspectBundle(mismatched, meta)).rejects.toThrow("local_header_mismatch");
    const badCrc = new Uint8Array(valid);
    const badView = new DataView(badCrc.buffer);
    badView.setUint32(central + 16, 0x12345678, true);
    badView.setUint32(local + 14, 0x12345678, true);
    await expect(inspectBundle(badCrc, meta)).rejects.toThrow("zip_crc_mismatch");
  });

  it("rejects unsafe central attributes, unsupported flags, and short archives", async () => {
    const meta = validateMetadata(metadata());
    const valid = await bundle();
    const central = centralOffset(valid);
    const symlink = new Uint8Array(valid);
    new DataView(symlink.buffer).setUint32(central + 38, 0xa1ff0000, true);
    await expect(inspectBundle(symlink, meta)).rejects.toThrow("unsafe_entry_type");
    const flagged = new Uint8Array(valid);
    new DataView(flagged.buffer).setUint16(central + 8, 0x0020, true);
    await expect(inspectBundle(flagged, meta)).rejects.toThrow("unsupported_zip_flags");
    await expect(inspectBundle(new Uint8Array([0x50, 0x4b]), meta)).rejects.toThrow("invalid_zip");
  });
});

function findEocd(bytes: Uint8Array): number {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let index = bytes.byteLength - 22; index >= 0; index--) if (view.getUint32(index, true) === 0x06054b50) return index;
  throw new Error("missing test EOCD");
}

function centralOffset(bytes: Uint8Array): number {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(findEocd(bytes) + 16, true);
}
