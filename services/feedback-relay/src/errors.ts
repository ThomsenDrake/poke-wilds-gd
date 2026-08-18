export type RelayErrorStatus = 400 | 401 | 413 | 429 | 502;

export class RelayError extends Error {
  readonly code: string;
  readonly status: RelayErrorStatus;

  constructor(code: string, status: RelayErrorStatus) {
    super(code);
    this.name = "RelayError";
    this.code = code;
    this.status = status;
  }
}

export function badRequest(code: string): RelayError {
  return new RelayError(code, 400);
}

export function payloadTooLarge(code: string): RelayError {
  return new RelayError(code, 413);
}

export function upstreamUnavailable(): RelayError {
  return new RelayError("github_unavailable", 502);
}
