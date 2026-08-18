CREATE TABLE IF NOT EXISTS invites (
  tester_id TEXT PRIMARY KEY,
  nickname TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  cohort_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS reports (
  report_id TEXT PRIMARY KEY,
  tester_id TEXT NOT NULL,
  cohort_id TEXT NOT NULL,
  install_id_hash TEXT NOT NULL,
  build_id TEXT NOT NULL,
  status TEXT NOT NULL,
  bundle_key TEXT NOT NULL,
  bundle_sha256 TEXT NOT NULL,
  bundle_bytes INTEGER NOT NULL,
  issue_number INTEGER,
  issue_url TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS reports_install_created
ON reports(install_id_hash, created_at);

CREATE INDEX IF NOT EXISTS reports_cohort_created
ON reports(cohort_id, created_at);

CREATE INDEX IF NOT EXISTS reports_expiry
ON reports(status, expires_at);
