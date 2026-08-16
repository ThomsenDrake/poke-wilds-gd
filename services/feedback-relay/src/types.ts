export interface Env {
  DB: D1Database;
  REPORTS: R2Bucket;
  REPORT_RATE_LIMITER: RateLimit;
  ENVIRONMENT: string;
  GITHUB_REPOSITORY: string;
  GITHUB_APP_ID: string;
  GITHUB_INSTALLATION_ID: string;
  GITHUB_PRIVATE_KEY: string;
  ADMIN_TOKEN: string;
  GITHUB_API_BASE?: string;
}

export interface BuildMetadata {
  version: string;
  commit_sha: string;
  build_id: string;
  channel: string;
}

export interface RuntimeMetadata {
  godot_version: string;
  os_name: string;
  os_version: string;
  architecture: string;
  locale: string;
  renderer: string;
  adapter: string;
  window_size: [number, number];
}

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export interface GameMetadata {
  current_screen: string;
  world_seed: number;
  player_tile: [number, number];
  active_area: string;
  time_of_day_minutes: number;
  total_steps: number;
  party: JsonValue[];
  bag: { [key: string]: JsonValue };
  battle_active: boolean;
}

export interface CaptureMetadata {
  screenshot_available: boolean;
  screen: string;
}

export interface ReportMetadata {
  schema_version: 1;
  report_id: string;
  message: string;
  tester_id: string;
  install_id: string;
  build: BuildMetadata;
  runtime: RuntimeMetadata;
  game: GameMetadata;
  capture: CaptureMetadata;
  bundle_sha256: string;
  bundle_bytes: number;
}

export interface InviteRow {
  tester_id: string;
  nickname: string;
  token_hash: string;
  cohort_id: string;
}

export interface ReportRow {
  report_id: string;
  status: "received" | "stored" | "issuing" | "completed" | "expired";
  bundle_key: string;
  bundle_sha256: string;
  issue_number: number | null;
  issue_url: string | null;
  updated_at: string;
  expires_at: string;
}
