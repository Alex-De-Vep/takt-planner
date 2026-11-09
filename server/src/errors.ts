export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public retryAfterSeconds?: number) { super(message); }
}
export function fail(status: number, code: string, message: string): never { throw new ApiError(status, code, message); }
export function requireValue(condition: unknown, code = 'invalid_request', message = 'Некорректный запрос'): asserts condition {
  if (!condition) fail(400, code, message);
}
