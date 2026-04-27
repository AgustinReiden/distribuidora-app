// Formatter para `mi_recorrido_hoy` (recorrido del transportista).
// Cabecera con totales del recorrido + lista de paradas con check de
// entrega, dirección y estado de pago.

import { escapeMarkdownV2 } from "../../_shared/telegram.ts";
import { formatCurrency, formatFechaCorta } from "../../_shared/tools/formatters.ts";
import type { MiRecorridoHoyResult } from "../../_shared/tools/transportista/mi_recorrido_hoy.ts";

export function formatMiRecorridoResult(r: MiRecorridoHoyResult): string {
  if (r.recorrido === null) {
    return "No tenés recorrido para hoy\\.";
  }

  const lines: string[] = [];
  // `fecha` viene del tool en formato YYYY-MM-DD — la pasamos por
  // formatFechaCorta para mostrar dd/mm/yy en vez de la fecha cruda.
  lines.push(
    `*Recorrido del ${escapeMarkdownV2(formatFechaCorta(r.recorrido.fecha))}*` +
      ` \\| ${escapeMarkdownV2(r.recorrido.estado)}`,
  );
  lines.push(
    `Pedidos: *${r.recorrido.pedidos_entregados}*/${r.recorrido.total_pedidos} entregados`,
  );
  lines.push(
    `Cobrado: *${escapeMarkdownV2(formatCurrency(r.recorrido.total_cobrado))}*` +
      ` de ${escapeMarkdownV2(formatCurrency(r.recorrido.total_facturado))}`,
  );

  if (r.pedidos.length > 0) {
    lines.push("");
    lines.push("*Paradas:*");
    for (const p of r.pedidos) {
      const orden = p.orden_entrega != null ? `${p.orden_entrega}\\.` : "•";
      const estado = p.estado_entrega === "entregado"
        ? "✅"
        : p.estado_entrega === "no_entregado"
        ? "❌"
        : "⏳";
      const dir = p.direccion ? ` \\| ${escapeMarkdownV2(p.direccion)}` : "";
      const pago = p.estado_pago === "pagado"
        ? ""
        : ` \\(${escapeMarkdownV2(p.estado_pago)}\\)`;
      lines.push(
        `${orden} ${estado} *${escapeMarkdownV2(p.cliente_nombre)}*${dir}\n` +
          `Total: ${escapeMarkdownV2(formatCurrency(p.total))}${pago}`,
      );
    }
  } else {
    // Edge case: existe el recorrido pero no tiene paradas asignadas todavía.
    // Sin este bloque el usuario veía solo la cabecera y se quedaba sin
    // entender por qué no hay pedidos.
    lines.push("");
    lines.push("_Sin paradas asignadas\\._");
  }
  return lines.join("\n");
}
