// Transcriptor Groq. Misma spec que OpenAI Whisper (Groq cumple la API
// de OpenAI), endpoint distinto + modelo whisper-large-v3-turbo (~$0.04/h
// audio, ~300x más barato que OpenAI). Latencia bajo 500ms.
//
// Requiere GROQ_API_KEY. Factory lo selecciona si
// BOT_TRANSCRIPTION_MODEL=groq.

import type { Transcriber } from "./types.ts";

const ENDPOINT = "https://api.groq.com/openai/v1/audio/transcriptions";
const MODEL = "whisper-large-v3-turbo";

export class GroqTranscriber implements Transcriber {
  readonly name = "groq";

  async transcribe(audio: Uint8Array, mimeType: string): Promise<string> {
    const apiKey = Deno.env.get("GROQ_API_KEY");
    if (!apiKey) {
      throw new Error(
        "GROQ_API_KEY no está seteada. Configurala como secret de Supabase " +
          "Edge Functions o cambiá BOT_TRANSCRIPTION_MODEL.",
      );
    }

    const form = new FormData();
    // Cast por discrepancy generic Uint8Array<ArrayBufferLike> → BlobPart
    // (mismo patrón que en openai.ts).
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
        `Groq transcribe failed (status ${res.status}): ${
          await res.text().catch(() => "<no body>")
        }`,
      );
    }
    const text = (await res.text()).trim();
    if (!text) {
      throw new Error("Groq transcribe: empty result");
    }
    return text;
  }
}
