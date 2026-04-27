// Cliente low-level para Gemini :generateContent.
//
// Diseño:
//   * fetch directo, sin SDK. Minimiza cold start y nos da control total
//     sobre el wire format.
//   * Retry exponencial con jitter en 429 / 5xx (max 2 retries por default).
//   * 4xx no-429 lanzan inmediatamente (un input malformado no se arregla
//     reintentando).
//   * NO maneja el loop de tool calls — eso es responsabilidad del caller
//     (Task 3.2). Acá solo: una request, una respuesta.
//
// Modelo default: `gemini-2.5-flash` (estable, GA). Override via env var
// `GEMINI_MODEL`. Mantenemos `gemini-2.5-flash` y NO `gemini-3-flash-preview`
// porque el preview tiene un bug activo con thought_signature en parallel
// function calls. Cuando el modelo 3.x sea estable (Q3 2026 estimado), se
// puede bumpear el env var sin re-deploy de la function.

import type {
  GeminiGenerateContentRequest,
  GeminiGenerateContentResponse,
} from "./types.ts";

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
const DEFAULT_MODEL = "gemini-2.5-flash";

export interface CallGeminiOptions {
  /** Override del modelo. Default: env GEMINI_MODEL o gemini-2.5-flash. */
  model?: string;
  /** Máximo de retries ante 429/5xx. Default: 2. */
  maxRetries?: number;
}

export class GeminiError extends Error {
  status?: number;
  body?: unknown;
  constructor(message: string, opts: { status?: number; body?: unknown } = {}) {
    super(message);
    this.name = "GeminiError";
    this.status = opts.status;
    this.body = opts.body;
  }
}

function backoffDelayMs(attempt: number): number {
  // 500ms, 1000ms, 2000ms, ... + jitter aleatorio hasta 200ms.
  return 500 * Math.pow(2, attempt) + Math.random() * 200;
}

/**
 * Llama a Gemini :generateContent con retry exponencial en 429/5xx.
 * Lanza GeminiError ante fallo definitivo.
 */
export async function callGemini(
  request: GeminiGenerateContentRequest,
  options: CallGeminiOptions = {},
): Promise<GeminiGenerateContentResponse> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    throw new GeminiError("GEMINI_API_KEY not set");
  }

  const model = options.model ?? Deno.env.get("GEMINI_MODEL") ?? DEFAULT_MODEL;
  const maxRetries = options.maxRetries ?? 2;
  const url = `${GEMINI_BASE}/${model}:generateContent`;

  let lastError: unknown = null;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "x-goog-api-key": apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(request),
      });

      if (res.ok) {
        return (await res.json()) as GeminiGenerateContentResponse;
      }

      // Error path: leer body para incluir en el error.
      const body = await res.text().catch(() => "<unparseable>");
      const isRetryable = res.status === 429 || res.status >= 500;

      if (isRetryable && attempt < maxRetries) {
        lastError = new GeminiError(
          `Gemini ${res.status}: ${body.slice(0, 500)}`,
          { status: res.status, body },
        );
        await new Promise((r) => setTimeout(r, backoffDelayMs(attempt)));
        continue;
      }

      throw new GeminiError(`Gemini ${res.status}: ${body.slice(0, 500)}`, {
        status: res.status,
        body,
      });
    } catch (err) {
      // Si es un GeminiError 4xx (no 429), no reintentar.
      if (
        err instanceof GeminiError &&
        err.status !== undefined &&
        err.status < 500 &&
        err.status !== 429
      ) {
        throw err;
      }
      lastError = err;
      if (attempt === maxRetries) break;
      await new Promise((r) => setTimeout(r, backoffDelayMs(attempt)));
    }
  }

  if (lastError instanceof GeminiError) throw lastError;
  throw new GeminiError(
    `Gemini call failed after ${maxRetries + 1} attempts: ${String(lastError)}`,
  );
}
