// Test de sincronización: verifica que los utils compartidos entre la app
// web (src/utils/) y el bot edge function (supabase/functions/_shared/utils/)
// estén byte-a-byte iguales (excepto el header de comentarios que documenta
// el sync requirement).
//
// Si este test falla, ejecutá:
//   cp src/utils/precioMayorista.ts            supabase/functions/_shared/utils/
//   cp src/utils/promociones.ts                supabase/functions/_shared/utils/
//   cp src/utils/descuentoCliente.ts           supabase/functions/_shared/utils/
//   cp src/utils/orquestacionPrecios.ts        supabase/functions/_shared/utils/
//   cp src/utils/orquestacionPrecios.fixture.ts supabase/functions/_shared/utils/
// y después restablecé los headers de "AUTO-SYNCED" en cada archivo y volvé a
// ponerle la extensión .ts a los imports relativos (Deno la exige).
//
// Razón: la app web calcula precios en TS y se los pasa pre-computados
// a `crear_pedido_completo`. El bot Telegram debe usar EXACTAMENTE la misma
// lógica para que el preventista vea los mismos precios via Telegram que
// via app. La forma más simple de garantizarlo es compartir el código.
//
// No alcanza con sincronizar las capas sueltas: el ORDEN entre ellas
// (promo → mayorista → descuento del cliente) también es lógica, y mientras
// vivió duplicada en `usePromocionPedido` y en `previsualizar_pedido` los dos
// lados cobraban distinto. Por eso `orquestacionPrecios.ts` está acá. Y por eso
// también el fixture: si cada suite escribiera sus propios casos, las dos
// podrían pasar en verde mientras app y bot dan totales distintos.

import { assert, assertEquals } from "std/assert/mod.ts";

const FILES = [
  ["src/utils/precioMayorista.ts", "supabase/functions/_shared/utils/precioMayorista.ts"],
  ["src/utils/promociones.ts", "supabase/functions/_shared/utils/promociones.ts"],
  ["src/utils/descuentoCliente.ts", "supabase/functions/_shared/utils/descuentoCliente.ts"],
  ["src/utils/orquestacionPrecios.ts", "supabase/functions/_shared/utils/orquestacionPrecios.ts"],
  [
    "src/utils/orquestacionPrecios.fixture.ts",
    "supabase/functions/_shared/utils/orquestacionPrecios.fixture.ts",
  ],
];

// Strip de TODO comment block leading + líneas en blanco hasta la primera
// línea de código real, y normaliza los imports relativos sin/con extensión .ts.
function stripHeader(text: string): string {
  const lines = text.split("\n");
  let i = 0;
  // Avanzar mientras la línea esté vacía o sea parte de un comment block
  // (empieza con `/*`, `//`, `*` o ` *`).
  while (i < lines.length) {
    const trimmed = lines[i].trim();
    if (trimmed === "") { i++; continue; }
    if (
      trimmed.startsWith("/*") || trimmed.startsWith("//") ||
      trimmed.startsWith("*") || trimmed.endsWith("*/")
    ) {
      i++;
      continue;
    }
    break;
  }
  // Normalizar los imports: la app usa `'./precioMayorista'`, Deno requiere `.ts`.
  return lines.slice(i).join("\n").replace(
    /from\s+'(\.\/[A-Za-z0-9_.-]+?)(\.ts)?'/g,
    "from '$1.ts'",
  );
}

// Resolvemos el path absoluto al repo root subiendo desde supabase/functions/tests/
const REPO_ROOT = new URL("../../../", import.meta.url).pathname.replace(/^\/([A-Z]:)/, "$1");

for (const [appPath, botPath] of FILES) {
  Deno.test(`utils sync: ${appPath} == ${botPath}`, async () => {
    const appText = await Deno.readTextFile(`${REPO_ROOT}${appPath}`);
    const botText = await Deno.readTextFile(`${REPO_ROOT}${botPath}`);
    const appBody = stripHeader(appText);
    const botBody = stripHeader(botText);
    if (appBody !== botBody) {
      // Encontrar la primera línea que difiere — diagnóstico útil.
      const appLines = appBody.split("\n");
      const botLines = botBody.split("\n");
      const max = Math.max(appLines.length, botLines.length);
      for (let i = 0; i < max; i++) {
        if (appLines[i] !== botLines[i]) {
          console.error(
            `Diff at line ${i + 1}:\n  app: ${appLines[i] ?? "(EOF)"}\n  bot: ${botLines[i] ?? "(EOF)"}`,
          );
          break;
        }
      }
    }
    assertEquals(
      appBody,
      botBody,
      `Los utils del bot y la app divergieron. Re-sincronizá con: cp ${appPath} ${botPath}`,
    );
  });
}

for (const [, botPath] of FILES) {
  Deno.test(`utils sync: ${botPath} tiene el header AUTO-SYNCED`, async () => {
    const text = await Deno.readTextFile(`${REPO_ROOT}${botPath}`);
    assert(
      text.includes("AUTO-SYNCED"),
      `El header AUTO-SYNCED no está presente en ${botPath} — alguien editó el archivo del bot directamente`,
    );
  });
}
