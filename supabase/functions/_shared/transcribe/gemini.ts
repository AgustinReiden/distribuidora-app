// Transcriptor Gemini. Reusa el callGemini wrapper existente y manda el
// audio inline (base64) en una `inlineData` part. No requiere API key
// extra — usa GEMINI_API_KEY que ya está configurada para el LLM.
//
// Cost: input audio para Gemini Flash es gratis. Latencia ~1-2s.

import { callGemini } from "../gemini/client.ts";
import { isTextPart } from "../gemini/types.ts";
import type { Transcriber } from "./types.ts";

const PROMPT = "Transcribí literalmente el audio. Devolvé solo el texto " +
  "transcripto, sin explicaciones, sin comillas, sin prefijos. Si el audio " +
  "no se entiende o está vacío, devolvé un string vacío.";

export class GeminiTranscriber implements Transcriber {
  readonly name = "gemini";

  async transcribe(audio: Uint8Array, mimeType: string): Promise<string> {
    const base64 = bytesToBase64(audio);

    const response = await callGemini({
      contents: [{
        role: "user",
        parts: [
          { text: PROMPT },
          { inlineData: { mimeType, data: base64 } },
        ],
      }],
      generationConfig: { temperature: 0.0, maxOutputTokens: 1024 },
    });

    const candidate = response.candidates?.[0];
    if (!candidate) {
      const reason = response.promptFeedback?.blockReason ?? "no_candidate";
      throw new Error(`Gemini transcribe: blocked or empty (${reason})`);
    }
    const parts = candidate.content?.parts ?? [];
    const text = parts.filter(isTextPart).map((p) => p.text).join("").trim();
    if (!text) {
      throw new Error("Gemini transcribe: empty result");
    }
    return text;
  }
}

/**
 * Encode Uint8Array a base64. btoa() solo acepta strings con char codes
 * <= 255 — convertimos byte-by-byte primero. Para audios grandes esto
 * crea un string intermedio largo pero es O(n) y suficientemente rápido
 * en el Edge Runtime.
 */
function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}
