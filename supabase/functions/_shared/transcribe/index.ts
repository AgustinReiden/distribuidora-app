// Factory + re-export del módulo de transcripción.
//
// El handler invoca `getTranscriber()` que lee la env var
// BOT_TRANSCRIPTION_MODEL (gemini | openai | groq, default gemini) y
// devuelve la implementación correspondiente. Cada provider valida sus
// propios secrets cuando transcribe — la factory NO los lee, así que
// crear un transcriber sin la key correspondiente NO falla; falla la
// primera transcripción.
//
// Por qué lazy: porque BOT_TRANSCRIPTION_MODEL puede cambiarse sin
// reiniciar el isolate (un nuevo deploy o un restart aplica). El handler
// llama getTranscriber() en cada turno y el cost es trivial (constructor
// de clase vacía).

import { GeminiTranscriber } from "./gemini.ts";
import { OpenAITranscriber } from "./openai.ts";
import { GroqTranscriber } from "./groq.ts";
import type { Transcriber } from "./types.ts";
import { modeloActivo, proveedorDe } from "../llm/modelo.ts";

export type { Transcriber } from "./types.ts";
export { GeminiTranscriber } from "./gemini.ts";
export { OpenAITranscriber } from "./openai.ts";
export { GroqTranscriber } from "./groq.ts";

export type TranscriptionModel = "gemini" | "openai" | "groq";

export function getTranscriber(): Transcriber {
  const raw = Deno.env.get("BOT_TRANSCRIPTION_MODEL")?.toLowerCase().trim();
  switch (raw) {
    case "openai":
      return new OpenAITranscriber();
    case "groq":
      return new GroqTranscriber();
    case "gemini":
      return new GeminiTranscriber();
    case "":
    case undefined:
      // Sin variable, la voz va con el proveedor del chat (#979): si el agente
      // está en OpenAI (gpt-6-luna, que no recibe audio), OpenAI transcribe y
      // no queda una dependencia de Gemini sólo por la voz. Con Gemini en el
      // chat, Gemini transcribe como siempre.
      return proveedorDe(modeloActivo()) === "openai" ? new OpenAITranscriber() : new GeminiTranscriber();
    default:
      // Valor desconocido — log + fallback a Gemini para no romper el bot.
      console.warn(
        `[transcribe] BOT_TRANSCRIPTION_MODEL=${raw} no reconocido, fallback a gemini`,
      );
      return new GeminiTranscriber();
  }
}
