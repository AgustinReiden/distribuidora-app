// Compra mínima y cargo de envío del pedido (mig 389 y cargo_1_base, #1220).
//
// Copia de `motivoRechazoMinimo` y `cargoEnvioPedido` de src/utils/montoMinimo.ts
// (el bot no puede importar de src/). Las dos reglas viven en la base
// (`pedido_incumple_minimo`, `pedido_cargo_envio`) y valen igual en la app, en el
// replay offline y acá. El gate es el mismo fixture que corre la app y el SQL:
// tests/cargoEnvio.test.ts recorre `cargo_envio_pedido` de
// src/utils/cargoEnvio.espejo.json. Si cambiás una regla, cambiá las tres.
//
// El `total` que reciben es la suma de los ítems, SIN el cargo: el servidor
// decide el cargo y lo suma al guardar.

import { formatCurrency } from "../tools/formatters.ts";

export type ModoMinimoPedido = "bloquear" | "cargo" | "escalas";

export interface ReglaMinimoPedido {
  modo: ModoMinimoPedido;
  montoMinimo: number;
  montoEnvioGratis: number;
  cargoEnvio: number;
}

/** La regla a partir de la fila de `politicas_comerciales` (null = sin política). */
export function reglaMinimoDeFila(
  fila:
    | {
      modo_minimo_pedido?: string | null;
      monto_minimo_pedido?: number | string | null;
      monto_envio_gratis?: number | string | null;
      cargo_envio_pedido?: number | string | null;
    }
    | null
    | undefined,
): ReglaMinimoPedido {
  const modo = fila?.modo_minimo_pedido;
  return {
    modo: modo === "cargo" || modo === "escalas" ? modo : "bloquear",
    montoMinimo: Number(fila?.monto_minimo_pedido ?? 0) || 0,
    montoEnvioGratis: Number(fila?.monto_envio_gratis ?? 0) || 0,
    cargoEnvio: Number(fila?.cargo_envio_pedido ?? 0) || 0,
  };
}

/**
 * Motivo del rechazo según el modo, o null si el pedido puede cargarse.
 * En `cargo` nunca se rechaza: bajo el mínimo el pedido paga el envío.
 */
export function motivoRechazoMinimo(total: number, regla: ReglaMinimoPedido): string | null {
  if (regla.modo === "cargo") return null;
  const minimo = regla.montoMinimo;
  if (!Number.isFinite(minimo) || minimo <= 0) return null; // 0 = sin política
  const t = Number.isFinite(total) ? total : 0;
  if (t >= minimo) return null;
  return (
    `El pedido no alcanza la compra mínima de ${formatCurrency(minimo)}. ` +
    `Faltan ${formatCurrency(minimo - t)}.`
  );
}

/** Cargo de envío que le toca a un pedido nuevo (0 si ninguno). */
export function cargoEnvioPedido(total: number, regla: ReglaMinimoPedido): number {
  const t = Number.isFinite(total) ? total : 0;
  if (t <= 0) return 0; // sin productos no hay envío que cobrar
  if (!(regla.cargoEnvio > 0)) return 0;
  if (regla.modo === "cargo") {
    return regla.montoMinimo > 0 && t < regla.montoMinimo ? regla.cargoEnvio : 0;
  }
  if (regla.modo === "escalas") {
    return t >= regla.montoMinimo && t < regla.montoEnvioGratis ? regla.cargoEnvio : 0;
  }
  return 0;
}
