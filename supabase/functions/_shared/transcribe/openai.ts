// Transcriptor OpenAI Whisper. Multipart form upload del audio.
// Endpoint: https://api.openai.com/v1/audio/transcriptions
// Modelo: whisper-1 (~$0.006/min audio).
//
// Requiere OPENAI_API_KEY como secret de Supabase Edge Functions. La
// factory en transcribe/index.ts solo selecciona este transcriber si
// BOT_TRANSCRIPTION_MODEL=openai.

import type { Transcriber } from "./types.ts";

const ENDPOINT = "https://api.openai.com/v1/audio/transcriptions";
const MODEL = "whisper-1";

export class OpenAITranscriber implements Transcriber {
  readonly name = "openai";

  async transcribe(audio: Uint8Array, mimeType: string): Promise<string> {
    const apiKey = Deno.env.get("OPENAI_API_KEY");
    if (!apiKey) {
      throw new Error(
        "OPENAI_API_KEY no está seteada. Configurala como secret de Supabase " +
          "Edge Functions o cambiá BOT_TRANSCRIPTION_MODEL.",
      );
    }

    const form = new FormData();
    // Uint8Array<ArrayBufferLike> no encaja con BlobPart por una generic
    // discrepancy en la lib de Deno; el cast es seguro (Uint8Array implementa
    // ArrayBufferView, que sí es BlobPart en runtime).
    form.append("file", new Blob([audio as BlobPart], { type: mimeType }), "audio.ogg");
    form.append("model", MODEL);
    form.append("response_format", "text");

    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
    });

    if (!res.ok) {
      throw new Error(
        `OpenAI transcribe failed (status ${res.status}): ${
          await res.text().catch(() => "<no body>")
        }`,
      );
    }
    // response_format=text → la API devuelve el texto plano directamente.
    const text = (await res.text()).trim();
    if (!text) {
      throw new Error("OpenAI transcribe: empty result");
    }
    return text;
  }
}
