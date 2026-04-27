// Tests Deno para el plumbing de Gemini (Phase 3 task 3.1).
// Correr con: deno task test (desde supabase/functions/).
//
// Cubrimos:
//   1. toolToGeminiDeclaration: tool con description vacía lanza
//   2. toolToGeminiDeclaration: happy path retorna shape correcto
//   3. callGemini: 200 OK → parsea JSON y devuelve la respuesta
//   4. callGemini: 429 una vez + 200 → retry y devuelve la 2da response
//   5. callGemini: 400 → throw GeminiError sin retry
//   6. callGemini: sin GEMINI_API_KEY → throw GeminiError "not set"
//   7. getSystemPrompt: carga prompt admin desde el FS y retorna texto

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "std/assert/mod.ts";

import { callGemini, GeminiError } from "../_shared/gemini/client.ts";
import {
  toolToGeminiDeclaration,
  toolsToGeminiDeclarations,
} from "../_shared/gemini/schema.ts";
import {
  clearSystemPromptCache,
  getSystemPrompt,
  setSystemPromptForTests,
} from "../_shared/gemini/prompts/base.ts";
import type { Tool } from "../_shared/tools/base.ts";

// ============================================================================
// 1. toolToGeminiDeclaration: description vacía
// ============================================================================

Deno.test("toolToGeminiDeclaration lanza si la tool no tiene description", () => {
  const sinDesc: Tool = {
    name: "sin_desc",
    description: "",
    parameters: { type: "object", properties: {} },
    allowedRoles: ["admin"],
    handler: () => Promise.resolve({}),
  };
  let threw = false;
  try {
    toolToGeminiDeclaration(sinDesc);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "no tiene description",
    );
  }
  assert(threw, "toolToGeminiDeclaration debió lanzar con description vacía");

  // Espacios puros = vacío.
  const soloEspacios: Tool = { ...sinDesc, description: "   " };
  let threw2 = false;
  try {
    toolToGeminiDeclaration(soloEspacios);
  } catch {
    threw2 = true;
  }
  assert(threw2, "toolToGeminiDeclaration debió lanzar con description blank");
});

// ============================================================================
// 2. toolToGeminiDeclaration happy path
// ============================================================================

Deno.test("toolToGeminiDeclaration retorna name/description/parameters correctos", () => {
  const tool: Tool = {
    name: "buscar_x",
    description: "Busca cosas X",
    parameters: {
      type: "object",
      properties: {
        q: { type: "string", description: "query" },
      },
      required: ["q"],
    },
    allowedRoles: ["admin", "preventista"],
    handler: () => Promise.resolve({}),
  };

  const decl = toolToGeminiDeclaration(tool);
  assertEquals(decl.name, "buscar_x");
  assertEquals(decl.description, "Busca cosas X");
  // El schema se pasa tal cual — Gemini acepta este subset.
  assertEquals(decl.parameters, tool.parameters);

  // toolsToGeminiDeclarations: convenience wrapper.
  const arr = toolsToGeminiDeclarations([tool, tool]);
  assertEquals(arr.length, 2);
  assertEquals(arr[0].name, "buscar_x");
});

// ============================================================================
// 3. callGemini: happy path 200 OK
// ============================================================================

Deno.test("callGemini retorna el JSON parseado ante 200 OK", async () => {
  const original = globalThis.fetch;
  Deno.env.set("GEMINI_API_KEY", "test-key");

  let capturedUrl: string | URL | Request | null = null;
  let capturedInit: RequestInit | undefined;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    capturedUrl = input;
    capturedInit = init;
    return Promise.resolve(
      new Response(
        JSON.stringify({
          candidates: [
            {
              content: { role: "model", parts: [{ text: "hola" }] },
              finishReason: "STOP",
            },
          ],
          usageMetadata: { totalTokenCount: 12 },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
  }) as typeof fetch;

  try {
    const res = await callGemini({
      contents: [{ role: "user", parts: [{ text: "hola" }] }],
    });

    assertEquals(res.candidates?.length, 1);
    assertEquals(res.candidates?.[0].finishReason, "STOP");
    assertEquals(res.usageMetadata?.totalTokenCount, 12);

    // Verificamos que se mandó la URL y headers correctos.
    const urlStr = String(capturedUrl);
    assertStringIncludes(urlStr, "/v1beta/models/gemini-2.5-flash:generateContent");
    const headers = capturedInit?.headers as Record<string, string>;
    assertEquals(headers["x-goog-api-key"], "test-key");
    assertEquals(headers["Content-Type"], "application/json");
    assertEquals(capturedInit?.method, "POST");
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("GEMINI_API_KEY");
  }
});

// ============================================================================
// 4. callGemini: 429 una vez → retry y 2da response
// ============================================================================

Deno.test("callGemini reintenta tras 429 y devuelve la 2da response", async () => {
  const original = globalThis.fetch;
  Deno.env.set("GEMINI_API_KEY", "test-key");

  let callCount = 0;
  globalThis.fetch = (() => {
    callCount++;
    if (callCount === 1) {
      return Promise.resolve(
        new Response(
          JSON.stringify({ error: { code: 429, message: "Too Many Requests" } }),
          { status: 429, headers: { "Content-Type": "application/json" } },
        ),
      );
    }
    return Promise.resolve(
      new Response(
        JSON.stringify({
          candidates: [
            {
              content: { role: "model", parts: [{ text: "ok ahora sí" }] },
              finishReason: "STOP",
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
  }) as typeof fetch;

  try {
    const res = await callGemini(
      { contents: [{ role: "user", parts: [{ text: "test" }] }] },
      { maxRetries: 2 },
    );
    assertEquals(callCount, 2, "debió llamar a fetch dos veces (1 fail + 1 retry)");
    assertEquals(res.candidates?.[0].finishReason, "STOP");
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("GEMINI_API_KEY");
  }
});

// ============================================================================
// 5. callGemini: 400 → no retry, throw GeminiError
// ============================================================================

Deno.test("callGemini lanza GeminiError sin retry ante 400", async () => {
  const original = globalThis.fetch;
  Deno.env.set("GEMINI_API_KEY", "test-key");

  let callCount = 0;
  globalThis.fetch = (() => {
    callCount++;
    return Promise.resolve(
      new Response(
        JSON.stringify({ error: { code: 400, message: "Invalid request" } }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      ),
    );
  }) as typeof fetch;

  try {
    let threw = false;
    let caught: unknown = null;
    try {
      await callGemini(
        { contents: [{ role: "user", parts: [{ text: "x" }] }] },
        { maxRetries: 3 },
      );
    } catch (err) {
      threw = true;
      caught = err;
    }
    assert(threw, "callGemini debió lanzar ante 400");
    assert(caught instanceof GeminiError, "el error debe ser GeminiError");
    assertEquals((caught as GeminiError).status, 400);
    assertEquals(callCount, 1, "no debió reintentar ante 400");
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("GEMINI_API_KEY");
  }
});

// ============================================================================
// 6. callGemini: sin GEMINI_API_KEY → throw inmediato
// ============================================================================

Deno.test("callGemini lanza GeminiError 'not set' sin GEMINI_API_KEY", async () => {
  const original = globalThis.fetch;
  // Asegurar que no haya key seteada por tests previos.
  Deno.env.delete("GEMINI_API_KEY");

  let fetchCalled = false;
  globalThis.fetch = (() => {
    fetchCalled = true;
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;

  try {
    let threw = false;
    let caught: unknown = null;
    try {
      await callGemini({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      });
    } catch (err) {
      threw = true;
      caught = err;
    }
    assert(threw, "debió lanzar sin GEMINI_API_KEY");
    assert(caught instanceof GeminiError);
    assertStringIncludes((caught as Error).message, "not set");
    assertEquals(fetchCalled, false, "no debió llegar a fetch");
  } finally {
    globalThis.fetch = original;
  }
});

// ============================================================================
// 7. getSystemPrompt: carga prompt admin desde el FS
// ============================================================================

Deno.test("getSystemPrompt carga el prompt admin y devuelve texto", async () => {
  clearSystemPromptCache();
  const prompt = await getSystemPrompt("admin");
  assert(prompt.length > 100, "el prompt admin debería tener contenido");
  assertStringIncludes(prompt.toLowerCase(), "admin");
  assertStringIncludes(prompt, "distribuidora");
  clearSystemPromptCache();
});

Deno.test("getSystemPrompt carga prompts distintos por rol", async () => {
  clearSystemPromptCache();
  const admin = await getSystemPrompt("admin");
  const prev = await getSystemPrompt("preventista");
  const trans = await getSystemPrompt("transportista");
  assert(admin !== prev, "admin y preventista deben ser distintos");
  assert(prev !== trans, "preventista y transportista deben ser distintos");
  // Sanity sobre el contenido específico.
  assertStringIncludes(prev.toLowerCase(), "preventista");
  assertStringIncludes(trans.toLowerCase(), "transportista");
  clearSystemPromptCache();
});

Deno.test("setSystemPromptForTests permite override sin tocar el FS", async () => {
  clearSystemPromptCache();
  setSystemPromptForTests("encargado", "PROMPT_DE_TEST_FAKE");
  const got = await getSystemPrompt("encargado");
  assertEquals(got, "PROMPT_DE_TEST_FAKE");
  clearSystemPromptCache();
});
