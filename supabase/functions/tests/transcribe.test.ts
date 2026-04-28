// Tests del factory de transcribers. Los tests por-provider con mocks de
// red están out of scope acá — los cubre el smoke test post-deploy con un
// voice message real, donde la API del provider es la que importa, no su
// shape de invocación.

import { assert, assertEquals } from "std/assert/mod.ts";
import {
  GeminiTranscriber,
  getTranscriber,
  GroqTranscriber,
  OpenAITranscriber,
} from "../_shared/transcribe/index.ts";

Deno.test("getTranscriber: default sin env var → Gemini", () => {
  Deno.env.delete("BOT_TRANSCRIPTION_MODEL");
  const t = getTranscriber();
  assert(t instanceof GeminiTranscriber, "default debe ser Gemini");
  assertEquals(t.name, "gemini");
});

Deno.test("getTranscriber: BOT_TRANSCRIPTION_MODEL=openai → OpenAI", () => {
  Deno.env.set("BOT_TRANSCRIPTION_MODEL", "openai");
  try {
    const t = getTranscriber();
    assert(t instanceof OpenAITranscriber);
    assertEquals(t.name, "openai");
  } finally {
    Deno.env.delete("BOT_TRANSCRIPTION_MODEL");
  }
});

Deno.test("getTranscriber: BOT_TRANSCRIPTION_MODEL=groq → Groq", () => {
  Deno.env.set("BOT_TRANSCRIPTION_MODEL", "groq");
  try {
    const t = getTranscriber();
    assert(t instanceof GroqTranscriber);
    assertEquals(t.name, "groq");
  } finally {
    Deno.env.delete("BOT_TRANSCRIPTION_MODEL");
  }
});

Deno.test("getTranscriber: valor desconocido → fallback a Gemini con warn", () => {
  Deno.env.set("BOT_TRANSCRIPTION_MODEL", "whisper-de-juancito");
  // Capturamos console.warn para confirmar que se loguea el fallback.
  const orig = console.warn;
  let warned = false;
  console.warn = (...args: unknown[]) => {
    if (args.some((a) => typeof a === "string" && a.includes("no reconocido"))) {
      warned = true;
    }
  };
  try {
    const t = getTranscriber();
    assert(t instanceof GeminiTranscriber);
    assert(warned, "debió loggear warning sobre el valor desconocido");
  } finally {
    console.warn = orig;
    Deno.env.delete("BOT_TRANSCRIPTION_MODEL");
  }
});

Deno.test("getTranscriber: case-insensitive (GEMINI vs gemini)", () => {
  Deno.env.set("BOT_TRANSCRIPTION_MODEL", "GEMINI");
  try {
    const t = getTranscriber();
    assert(t instanceof GeminiTranscriber);
  } finally {
    Deno.env.delete("BOT_TRANSCRIPTION_MODEL");
  }
});
