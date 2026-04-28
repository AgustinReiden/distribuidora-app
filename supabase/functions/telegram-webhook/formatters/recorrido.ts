// Formatter para `mi_recorrido_hoy` (recorrido del transportista).
// Cabecera con totales del recorrido + lista de paradas con check de
// entrega, dirección y estado de pago.

import {
  bullet,
  divider,
  escapeMarkdownV2,
  formatCurrency,
  formatFechaCorta,
  header,
  statusBadge,
} from "../../_shared/format.ts";
import type { MiRecorridoHoyResult } from "../../_shared/tools/transportista/mi_recorrido_hoy.ts";

export function formatMiRecorridoResult(r: MiRecorridoHoyResult): string {
  if (r.recorrido === null) {
    return "No tenés recorrido para hoy\\.";
  }

  const lines: string[] = [];
  // `fecha` viene del tool en formato YYYY-MM-DD — pasamos por
  // formatFechaCorta para mostrar dd/mm/yy.
  const fechaTxt = formatFechaCorta(r.recorrido.fecha);
  lines.push(header(`Recorrido del ${fechaTxt}`, "🚚"));
  lines.push(`Estado: *${escapeMarkdownV2(r.recorrido.estado)}*`);
  lines.push(
    `Pedidos: *${r.recorrido.pedidos_entregados}*/${r.recorrido.total_pedidos} entregados`,
  );
  lines.push(
    `Cobrado: *${escapeMarkdownV2(formatCurrency(r.recorrido.total_cobrado))}*` +
      ` de ${escapeMarkdownV2(formatCurrency(r.recorrido.total_facturado))}`,
  );

  if (r.pedidos.length > 0) {
    lines.push(divider());
    lines.push("*Paradas:*");
    for (const p of r.pedidos) {
      const orden = p.orden_entrega != null ? `${p.orden_entrega}\\.` : "•";
      const estado = p.estado_entrega === "entregado"
        ? statusBadge("ok")
        : p.estado_entrega === "no_entregado"
        ? statusBadge("err")
        : statusBadge("pending");
      const dir = p.direccion ? ` \\| 📍 ${escapeMarkdownV2(p.direccion)}` : "";
      const pago = p.estado_pago === "pagado"
        ? ""
        : ` \\(${escapeMarkdownV2(p.estado_pago)}\\)`;
      lines.push(
        bullet(
          `${orden} ${estado} *${escapeMarkdownV2(p.cliente_nombre)}*${dir}\n` +
            `Total: ${escapeMarkdownV2(formatCurrency(p.total))}${pago}`,
        ),
      );
    }
  } else {
    // Edge case: existe el recorrido pero sin paradas asignadas todavía.
    lines.push(divider());
    lines.push("_Sin paradas asignadas\\._");
  }
  return lines.join("\n");
}
