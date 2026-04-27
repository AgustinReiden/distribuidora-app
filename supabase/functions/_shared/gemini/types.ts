// Tipos mínimos de la Gemini API (subset de :generateContent).
//
// NO importamos del SDK oficial: queremos control total sobre el shape del
// request/response y minimizar cold start en edge. Si Google cambia el wire
// format, basta con tocar este archivo.
//
// Referencia:
// https://ai.google.dev/api/generate-content
// https://ai.google.dev/api/caching#Tool

export type GeminiRole = "user" | "model";

export interface GeminiTextPart {
  text: string;
}

export interface GeminiFunctionCall {
  name: string;
  args: Record<string, unknown>;
}

export interface GeminiFunctionCallPart {
  functionCall: GeminiFunctionCall;
}

export interface GeminiFunctionResponse {
  name: string;
  response: Record<string, unknown>;
}

export interface GeminiFunctionResponsePart {
  functionResponse: GeminiFunctionResponse;
}

export type GeminiPart =
  | GeminiTextPart
  | GeminiFunctionCallPart
  | GeminiFunctionResponsePart;

export interface GeminiContent {
  role: GeminiRole;
  parts: GeminiPart[];
}

export interface GeminiFunctionDeclaration {
  name: string;
  description: string;
  /** JSON Schema subset (compat OpenAPI 3.0). Las tools del registry ya cumplen. */
  parameters: Record<string, unknown>;
}

export interface GeminiToolConfig {
  function_calling_config: {
    mode: "AUTO" | "ANY" | "NONE";
    allowed_function_names?: string[];
  };
}

export interface GeminiGenerateContentRequest {
  system_instruction?: { parts: GeminiTextPart[] };
  contents: GeminiContent[];
  tools?: Array<{ function_declarations: GeminiFunctionDeclaration[] }>;
  tool_config?: GeminiToolConfig;
  generationConfig?: {
    temperature?: number;
    maxOutputTokens?: number;
    topP?: number;
    topK?: number;
  };
}

export interface GeminiUsageMetadata {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
  totalTokenCount?: number;
}

export interface GeminiCandidate {
  content: GeminiContent;
  finishReason?:
    | "STOP"
    | "MAX_TOKENS"
    | "SAFETY"
    | "RECITATION"
    | "MALFORMED_FUNCTION_CALL"
    | string;
  index?: number;
}

export interface GeminiGenerateContentResponse {
  candidates?: GeminiCandidate[];
  usageMetadata?: GeminiUsageMetadata;
  promptFeedback?: { blockReason?: string; safetyRatings?: unknown[] };
}

// ----------------------------------------------------------------------------
// Type guards. Útiles porque GeminiPart es union y no podemos usar `in` sin
// que TS se queje en algunos paths.
// ----------------------------------------------------------------------------

export function isFunctionCallPart(
  part: GeminiPart,
): part is GeminiFunctionCallPart {
  const candidate = (part as GeminiFunctionCallPart).functionCall;
  return typeof candidate === "object" && candidate !== null;
}

export function isTextPart(part: GeminiPart): part is GeminiTextPart {
  return typeof (part as GeminiTextPart).text === "string";
}

export function isFunctionResponsePart(
  part: GeminiPart,
): part is GeminiFunctionResponsePart {
  const candidate = (part as GeminiFunctionResponsePart).functionResponse;
  return typeof candidate === "object" && candidate !== null;
}
