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
  version?: string;
  commit_sha: string;
  build_id: string;
  channel: string;
}

export interface ReportMetadata {
  schema_version: number;
  report_id: string;
  message: string;
  tester_id: string;
  install_id: string;
  build: BuildMetadata;
  runtime: Record<string, unknown>;
  game: Record<string, unknown>;
  capture: { screenshot_available: boolean; screen: string };
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
  status: string;
  bundle_key: string;
  bundle_sha256: string;
  issue_number: number | null;
  issue_url: string | null;
  updated_at: string;
  expires_at: string;
}
