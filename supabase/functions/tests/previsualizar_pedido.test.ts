// Tests para la alerta de crédito de previsualizar_pedido (#531/#587).
//
// El bot alertaba sólo cuando `limite_credito` estaba cargado (1 de 718
// clientes en prod). El dueño pidió el mismo criterio que la app: avisar
// también por `saldo_cuenta > 0` (deuda previa), que es lo que muestra
// `avisoDeudaCliente` en `src/utils/deudaCliente.ts` y lo que usa 121 de esos
// 718 clientes. Cubrimos las dos ramas + que "límite superado" pisa a "deuda"
// cuando las dos aplican (es la alerta más específica).
//
// Correr con: deno task test (desde supabase/functions/).

import { assert, assertEquals } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import { previsualizarPedidoTool } from "../_shared/tools/preventista/previsualizar_pedido.ts";
import type { ToolContext } from "../_shared/tools/base.ts";

// ============================================================================
// Mock genérico: cada tabla resuelve con un dato fijo sin importar la cadena
// de builder que se le aplique (select/eq/in/order/limit/maybeSingle/single).
// A esta tool no le probamos la lógica de pricing (eso lo cubre
// orquestacion_precios.test.ts) — con las tablas de pricing vacías el total
// queda en precio de lista, que es lo que necesitamos para la alerta de
// crédito.
// ============================================================================

interface TableConfig {
  /** Para `.await` sin terminator explícito (selects planos). */
  select?: { data: unknown; error: { message: string } | null };
  /** Para `.maybeSingle()`. */
  maybeSingle?: { data: unknown; error: { message: string } | null };
  /** Para `.insert(...).select(...).single()`. */
  single?: { data: unknown; error: { message: string } | null };
}

function createMockSupabase(
  perTable: Record<string, TableConfig>,
): SupabaseClient {
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from(table: string) {
      const cfg = perTable[table] ?? {};
      // deno-lint-ignore no-explicit-any
      const builder: any = {
        select() {
          return builder;
        },
        insert() {
          return builder;
        },
        eq() {
          return builder;
        },
        in() {
          return builder;
        },
        lte() {
          return builder;
        },
        gte() {
          return builder;
        },
        or() {
          return builder;
        },
        order() {
          return builder;
        },
        limit() {
          return builder;
        },
        maybeSingle() {
          return Promise.resolve(
            cfg.maybeSingle ?? { data: null, error: null },
          );
        },
        single() {
          return Promise.resolve(cfg.single ?? { data: null, error: null });
        },
        then(
          // deno-lint-ignore no-explicit-any
          onFulfilled?: (value: any) => any,
          // deno-lint-ignore no-explicit-any
          onRejected?: (reason: any) => any,
        ) {
          const r = cfg.select ?? { data: [], error: null };
          return Promise.resolve(r).then(onFulfilled, onRejected);
        },
      };
      return builder;
    },
  };
  return client as SupabaseClient;
}

function makeCtx(client: SupabaseClient): ToolContext {
  return {
    perfil_id: "11111111-1111-1111-1111-111111111111",
    rol: "preventista",
    sucursal_id: 1,
    supabase: client,
  };
}

const PRODUCTO_BASE = {
  id: 900,
  codigo: "P900",
  nombre: "Aceite 900ml",
  precio: 1000,
  stock: 100,
  categoria: null,
  porcentaje_iva: 0,
  impuestos_internos: 0,
  cantidad_minima_venta: null,
  sucursal_id: 1,
};

function baseTables(clienteRow: Record<string, unknown>) {
  return {
    clientes: { maybeSingle: { data: clienteRow, error: null } },
    cliente_preventistas: { select: { data: [], error: null } }, // huérfano
    productos: { select: { data: [PRODUCTO_BASE], error: null } },
    cliente_descuentos_categoria: { select: { data: [], error: null } },
    politicas_comerciales: { maybeSingle: { data: null, error: null } },
    bot_pedidos_pendientes: {
      single: { data: { id: "conf-uuid-1" }, error: null },
    },
  };
}

// ============================================================================
// 1. Sin límite cargado pero con saldo_cuenta > 0 → alerta "deuda", mismo
//    texto que ve el preventista en la app.
// ============================================================================

Deno.test("previsualizar_pedido: saldo_cuenta > 0 y sin límite → alerta de deuda", async () => {
  const client = createMockSupabase(
    baseTables({
      id: 42,
      codigo: 7,
      nombre_fantasia: "Almacén Deudor",
      razon_social: "Deudor SA",
      saldo_cuenta: 15000,
      limite_credito: 0,
      descuento_porcentaje: 0,
      activo: true,
      sucursal_id: 1,
      reservado_admin: false,
    }),
  );
  const ctx = makeCtx(client);

  const result = await previsualizarPedidoTool.handler(
    { cliente_id: 42, items: [{ producto_id: 900, cantidad: 1 }] },
    ctx,
  );

  assert(result.alertas.credito, "debió generar alerta de crédito");
  assertEquals(result.alertas.credito!.motivo, "deuda");
  assertEquals(result.alertas.credito!.saldo_actual, 15000);
  assertEquals(result.alertas.credito!.limite, 0);
  // Mismo texto que src/utils/deudaCliente.ts → avisoDeudaCliente().detalle
  // (Intl mete un espacio no-break entre "$" y el número — normalizamos).
  assertEquals(
    result.alertas.credito!.mensaje.replace(/ /g, " "),
    "Este cliente tiene una deuda previa de $ 15.000.",
  );
});

// ============================================================================
// 2. Cliente sin límite y sin saldo → sin alerta.
// ============================================================================

Deno.test("previsualizar_pedido: sin límite y saldo_cuenta 0 → sin alerta de crédito", async () => {
  const client = createMockSupabase(
    baseTables({
      id: 43,
      codigo: 8,
      nombre_fantasia: "Almacén Al Día",
      razon_social: "Al Día SA",
      saldo_cuenta: 0,
      limite_credito: 0,
      descuento_porcentaje: 0,
      activo: true,
      sucursal_id: 1,
      reservado_admin: false,
    }),
  );
  const ctx = makeCtx(client);

  const result = await previsualizarPedidoTool.handler(
    { cliente_id: 43, items: [{ producto_id: 900, cantidad: 1 }] },
    ctx,
  );

  assertEquals(result.alertas.credito, null);
});

// ============================================================================
// 3. Límite cargado y superado por el pedido → alerta "limite" (no "deuda"),
//    aunque el cliente también tenga saldo > 0.
// ============================================================================

Deno.test("previsualizar_pedido: límite superado → alerta de límite, no de deuda", async () => {
  const client = createMockSupabase(
    baseTables({
      id: 44,
      codigo: 9,
      nombre_fantasia: "Almacén Con Límite",
      razon_social: "Con Límite SA",
      saldo_cuenta: 5000,
      limite_credito: 5500,
      descuento_porcentaje: 0,
      activo: true,
      sucursal_id: 1,
      reservado_admin: false,
    }),
  );
  const ctx = makeCtx(client);

  // 1 unidad a $1000: saldo (5000) + total (1000) = 6000 > límite (5500).
  const result = await previsualizarPedidoTool.handler(
    { cliente_id: 44, items: [{ producto_id: 900, cantidad: 1 }] },
    ctx,
  );

  assert(result.alertas.credito, "debió generar alerta de crédito");
  assertEquals(result.alertas.credito!.motivo, "limite");
  assertEquals(result.alertas.credito!.excedente, 500);
});
