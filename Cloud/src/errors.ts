import type { ContentfulStatusCode } from "hono/utils/http-status";

export class APIError extends Error {
  constructor(readonly status: ContentfulStatusCode, readonly code: string, message: string) {
    super(message);
    this.name = "APIError";
  }
}

export const invalidRequest = () => new APIError(400, "invalid_request", "The request contains invalid capture metadata or parameters.");

export function publicError(error: unknown): APIError {
  if (error instanceof APIError) return error;
  return new APIError(500, "internal_error", "The cloud request could not be completed. Please retry.");
}
