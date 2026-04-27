// Formatter para `mi_recorrido_hoy` (recorrido del transportista).
// Cabecera con totales del recorrido + lista de paradas con check de
// entrega, dirección y estado de pago.

import { escapeMarkdownV2 } from "../../_shared/telegram.ts";
import { formatCurrency } from "../../_shared/tools/formatters.ts";
import type { MiRecorridoHoyResult } from "../../_shared/tools/transportista/mi_recorrido_hoy.ts";

export function formatMiRecorridoResult(r: MiRecorridoHoyResult): string {
  if (r.recorrido === null) {
    return "No tenés recorrido para hoy\\.";
  }

  const lines: string[] = [];
  lines.push(
    `*Recorrido del ${escapeMarkdownV2(r.recorrido.fecha)}*` +
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
  }
  return lines.join("\n");
}
