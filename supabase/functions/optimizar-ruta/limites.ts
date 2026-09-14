// Topes de tamaño del request de optimizar-ruta. Sin esto, cualquier caller
// autorizado podía mandar un `pedidos` o `repartidores` arbitrariamente
// grande: cada tramo optimizado es una llamada facturable a Google, y un
// array gigante multiplica el costo (y en optimizeTours, el tamaño del
// problema que resuelve Google server-side).

export const MAX_PEDIDOS = 200;
export const MAX_REPARTIDORES = 10;

export type ValidacionLimites =
  | { ok: true }
  | { ok: false; mensaje: string };

/** Valida los tamaños de `pedidos` y `repartidores` antes de tocar Google. */
export function validarLimites(
  pedidosLen: number,
  repartidoresLen: number,
): ValidacionLimites {
  if (pedidosLen > MAX_PEDIDOS) {
    return {
      ok: false,
      mensaje: `Demasiados pedidos: máximo ${MAX_PEDIDOS} por solicitud (recibidos ${pedidosLen})`,
    };
  }
  if (repartidoresLen > MAX_REPARTIDORES) {
    return {
      ok: false,
      mensaje: `Demasiados repartidores: máximo ${MAX_REPARTIDORES} por solicitud (recibidos ${repartidoresLen})`,
    };
  }
  return { ok: true };
}
