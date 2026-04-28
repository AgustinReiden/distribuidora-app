// Tests para los inline keyboard builders.
//
// Cubrimos:
//   * Forma del shape: 1 fila por item, 1 botón por fila.
//   * callback_data armado con prefijo de versión + action + id.
//   * Truncate del texto del botón si supera 28 chars.
//   * callback_data dentro del límite de 64 bytes UTF-8.
//   * Lista vacía → keyboard sin filas (el caller decide si mandarlo o no).

import { assert, assertEquals } from "std/assert/mod.ts";
import {
  _internal,
  buildClienteListKeyboard,
  buildMisClientesKeyboard,
  buildProductoListKeyboard,
  buildSugerenciasKeyboard,
} from "../_shared/telegram-keyboards.ts";

// ----------------------------------------------------------------------------
// 1. cliente list: shape básico
// ----------------------------------------------------------------------------

Deno.test("buildClienteListKeyboard: 1 fila por cliente con callback_data v1:cliente:<id>", () => {
  // Nombres deliberadamente cortos para no caer en truncate — la truncación
  // se verifica en su propio test más abajo.
  const kb = buildClienteListKeyboard([
    { id: 42, nombre: "Pepito" },
    { id: 100, nombre: "Don Tito" },
  ]);

  assertEquals(kb.inline_keyboard.length, 2);
  assertEquals(kb.inline_keyboard[0].length, 1);
  assertEquals(kb.inline_keyboard[1].length, 1);

  const b0 = kb.inline_keyboard[0][0];
  assertEquals(b0.text, "👤 Ver ficha — Pepito");
  assertEquals(b0.callback_data, "v1:cliente:42");

  const b1 = kb.inline_keyboard[1][0];
  assertEquals(b1.text, "👤 Ver ficha — Don Tito");
  assertEquals(b1.callback_data, "v1:cliente:100");
});

// ----------------------------------------------------------------------------
// 2. cliente list: vacío
// ----------------------------------------------------------------------------

Deno.test("buildClienteListKeyboard: lista vacía retorna inline_keyboard vacío", () => {
  const kb = buildClienteListKeyboard([]);
  assertEquals(kb.inline_keyboard.length, 0);
});

// ----------------------------------------------------------------------------
// 3. truncate: textos largos quedan bajo el max
// ----------------------------------------------------------------------------

Deno.test("buildClienteListKeyboard: truncate de nombres largos", () => {
  const kb = buildClienteListKeyboard([
    {
      id: 1,
      nombre: "Distribuidora de Productos del Sur Sociedad Anónima",
    },
  ]);
  const text = kb.inline_keyboard[0][0].text;
  assert(
    text.length <= _internal.BUTTON_TEXT_MAX,
    `texto del botón excede ${_internal.BUTTON_TEXT_MAX} chars: "${text}" (${text.length})`,
  );
  // Debe terminar con ellipsis cuando se truncó.
  assert(text.endsWith("…"), `texto truncado debe terminar con elipsis: "${text}"`);
});

// ----------------------------------------------------------------------------
// 4. callback_data: bajo el límite de 64 bytes UTF-8
// ----------------------------------------------------------------------------

Deno.test("buildClienteListKeyboard: callback_data bajo 64 bytes", () => {
  const kb = buildClienteListKeyboard([
    { id: 999999999, nombre: "Test" },
  ]);
  const cb = kb.inline_keyboard[0][0].callback_data!;
  const bytes = new TextEncoder().encode(cb).length;
  assert(bytes <= 64, `callback_data de ${bytes} bytes excede 64`);
});

// ----------------------------------------------------------------------------
// 5. producto list: action='producto'
// ----------------------------------------------------------------------------

Deno.test("buildProductoListKeyboard: action es 'producto'", () => {
  const kb = buildProductoListKeyboard([
    { id: 1234, nombre: "Coca 2L" },
  ]);
  assertEquals(kb.inline_keyboard[0][0].callback_data, "v1:producto:1234");
  assertEquals(kb.inline_keyboard[0][0].text, "📦 Ver detalle — Coca 2L");
});

// ----------------------------------------------------------------------------
// 6. sugerencias: routea al action 'cliente' (no 'sugerencia')
// ----------------------------------------------------------------------------

Deno.test("buildSugerenciasKeyboard: callback va a action='cliente' con cliente_id", () => {
  const kb = buildSugerenciasKeyboard([
    { cliente_id: 555, nombre: "Almacén Norte" },
  ]);
  assertEquals(kb.inline_keyboard[0][0].callback_data, "v1:cliente:555");
});

// ----------------------------------------------------------------------------
// 7. misclientes: action='cliente'
// ----------------------------------------------------------------------------

Deno.test("buildMisClientesKeyboard: callback va a action='cliente' con id", () => {
  const kb = buildMisClientesKeyboard([
    { id: 7, nombre: "Boliche Don Tito" },
  ]);
  assertEquals(kb.inline_keyboard[0][0].callback_data, "v1:cliente:7");
});

// ----------------------------------------------------------------------------
// 8. truncate helper: comportamiento exacto
// ----------------------------------------------------------------------------

Deno.test("truncate: respeta el max y agrega elipsis", () => {
  assertEquals(_internal.truncate("hola", 10), "hola");
  assertEquals(_internal.truncate("hola mundo!", 5), "hola…");
  // Espacio antes del elipsis se trimmea.
  assertEquals(_internal.truncate("hola mundo!", 6), "hola…");
});
