// Formatter para `sugerir_visitas_rfm` (sugerencias RFM de visitas).
// Lista priorizada con flags de criticidad (🔴 vencido, 🟡 cercano,
// 🟢 al día) + motivo + saldo + zona, pensado para que el preventista
// decida en 5 segundos qué cliente visitar primero.

import {
  escapeMarkdownV2,
  formatCurrency,
  header,
} from "../../_shared/format.ts";
import type { SugerirVisitasRfmResult } from "../../_shared/tools/preventista/sugerir_visitas_rfm.ts";

export function formatSugerenciasResult(r: SugerirVisitasRfmResult): string {
  if (r.sugerencias.length === 0) {
    return "No tengo sugerencias para hoy\\. Probá /misclientes para ver tu cartera completa\\.";
  }

  const titulo = `${r.sugerencias.length} clientes priorizados ` +
    `(top ${r.total} por score RFM)`;

  const lines = r.sugerencias.map((s, i) => {
    const numero = `${i + 1}\\.`;
    // 🔴 vencido (compras atrasadas), 🟡 cerca del re-pedido (>= 30d sin
    // estar formalmente vencido), 🟢 todo bien.
    const flag = s.vencido
      ? "🔴"
      : s.dias_desde_ultima >= 30
      ? "🟡"
      : "🟢";
    const codigo = s.codigo != null ? `\\#${s.codigo} ` : "";
    const nombre = `*${escapeMarkdownV2(s.nombre)}*`;
    const motivoEsc = escapeMarkdownV2(`→ ${s.motivo}`);

    const datos: string[] = [];
    if (s.saldo_cuenta > 0) {
      datos.push(`💰 ${escapeMarkdownV2(formatCurrency(s.saldo_cuenta))}`);
    }
    if (s.zona) {
      datos.push(`🗺️ ${escapeMarkdownV2(s.zona)}`);
    }
    const datosLine = datos.length > 0 ? `\n${datos.join(" \\| ")}` : "";

    return `${numero} ${flag} ${codigo}${nombre}\n${motivoEsc}${datosLine}`;
  });

  return [header(titulo, "💡"), "", ...lines].join("\n\n");
}
