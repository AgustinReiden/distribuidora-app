// Formatter de `clientes_atrasados` para /sugerencias (mig 307; antes era la
// RFM). Lista priorizada por la plata en riesgo, con cuánto lleva cada cliente
// sin comprar contra cada cuánto compraba: lo que el preventista necesita para
// decidir en 5 segundos a quién visitar primero.

import { escapeMarkdownV2, formatCurrency, header } from "../../_shared/format.ts";
import type { ClientesAtrasadosResult } from "../../_shared/tools/common/clientes_atrasados.ts";

const BADGE: Record<string, string> = {
  atrasado: "🔴",
  por_vencer: "🟡",
  inactivo: "⚫",
  ocasional: "⚪",
};

export function formatSugerenciasResult(r: ClientesAtrasadosResult): string {
  if (r.clientes.length === 0) {
    return "No hay clientes atrasados en tu cartera\\. Probá /misclientes para verla completa\\.";
  }

  const riesgo = escapeMarkdownV2(formatCurrency(r.monto_mensual_en_riesgo));
  const titulo = `${r.atrasados} clientes atrasados`;
  const donde = r.cartera === "sucursal" ? "en la sucursal" : "en tu cartera";
  const resumen = `De ${r.clientes_en_cartera} ${donde}\\. ` +
    `Compran ${riesgo} por mes${r.montos === "propios" ? " \\(lo tuyo\\)" : ""}\\.`;

  const lines = r.clientes.map((c, i) => {
    const flag = BADGE[c.estado] ?? "🟢";
    const codigo = c.codigo != null ? `\\#${c.codigo} ` : "";
    const nombre = `*${escapeMarkdownV2(c.nombre)}*`;
    const comodin = c.es_comodin ? escapeMarkdownV2(" (mostrador)") : "";
    const ritmo = c.dias_sin_comprar == null
      ? "sin compras en el año"
      : c.frecuencia_dias
      // "~" es reservado en MarkdownV2 (tachado): va escapado.
      ? `${c.dias_sin_comprar} días sin comprar \\(compraba cada \\~${Math.round(c.frecuencia_dias)}\\)`
      : `${c.dias_sin_comprar} días sin comprar`;
    const datos: string[] = [];
    if (c.monto_mensual > 0) {
      datos.push(`💵 ${escapeMarkdownV2(formatCurrency(c.monto_mensual))}/mes`);
    }
    if (c.saldo > 0) datos.push(`💰 debe ${escapeMarkdownV2(formatCurrency(c.saldo))}`);
    if (c.zona) datos.push(`🗺️ ${escapeMarkdownV2(c.zona)}`);
    const datosLine = datos.length > 0 ? `\n${datos.join(" \\| ")}` : "";
    return `${i + 1}\\. ${flag} ${codigo}${nombre}${comodin}\n→ ${ritmo}${datosLine}`;
  });

  return [header(titulo, "💡"), resumen, "", ...lines].join("\n\n");
}
