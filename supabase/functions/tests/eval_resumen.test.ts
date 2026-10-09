// El repo es PÚBLICO: en GitHub Actions el resumen de la evaluación lo lee
// cualquiera. Este test fija que en modo público no salgan respuestas,
// números ni motivos con datos (#979, revisión adversarial del PR 3a).

import { assert, assertStringIncludes } from "std/assert/mod.ts";
import { armarResumen, type ResultadoCaso } from "../_eval/correr.ts";

const RESULTADO: ResultadoCaso = {
  caso: "a15",
  rol: "admin",
  modelo: "gpt-6-luna",
  texto: "Fulano Pérez debe $1.019.850 en 5 pedidos",
  herramientas: ["pendientes_pago"],
  toolCalls: [],
  evaluacion: {
    eleccionOk: true,
    argsOk: false,
    prohibidasOk: true,
    sinPreguntaOk: true,
    inventados: [1019850],
    ok: false,
    motivos: ["args: cliente esperado Fulano Pérez"],
  },
  costoUsd: 0.0012,
  ms: 2300,
};

Deno.test("armarResumen público: sin respuestas, sin números y sin el detalle de los motivos", () => {
  const r = armarResumen([RESULTADO], ["gpt-6-luna"], "2026-10-08", true);
  assert(!r.includes("Fulano"), "un nombre real se filtró al resumen público");
  assert(!r.includes("1019850") && !r.includes("1.019.850"), "un monto real se filtró");
  assert(!r.includes("Respuestas de los casos que fallaron"));
  // Lo agregado sí: el caso, la herramienta y el tipo de motivo.
  assertStringIncludes(r, "pendientes_pago");
  assertStringIncludes(r, "| args |");
});

Deno.test("armarResumen local: con el detalle completo", () => {
  const r = armarResumen([RESULTADO], ["gpt-6-luna"], "2026-10-08");
  assertStringIncludes(r, "Fulano");
  assertStringIncludes(r, "1019850");
});

Deno.test("armarResumen público: muestra los errores del proveedor, no los de la base", () => {
  const conError = (error: string): ResultadoCaso => ({
    ...RESULTADO,
    texto: "",
    error,
    evaluacion: { ...RESULTADO.evaluacion, motivos: [`error: ${error}`] },
  });
  const r = armarResumen(
    [
      conError("OpenAI 404: The model `gpt-6-luna` does not exist"),
      conError("OpenAI 404: The model `gpt-6-luna` does not exist"),
      conError('duplicate key value violates unique constraint "x" (cliente Fulano)'),
    ],
    ["gpt-6-luna"],
    "2026-10-08",
    true,
  );
  assertStringIncludes(r, "Errores del proveedor");
  // Deduplicado: una línea por error distinto.
  assert(r.split("does not exist").length === 2);
  assert(!r.includes("Fulano"), "un error de la base no puede salir en el resumen público");
});
