// Formatter para `mis_clientes` (cartera del preventista). Una línea por
// cliente con código, nombre, saldo (si > 0) y "días desde la última compra"
// — pensado para que el preventista priorice rápido qué visitar.

import { escapeMarkdownV2 } from "../../_shared/telegram.ts";
import { formatCurrency } from "../../_shared/tools/formatters.ts";
import type { MisClientesResult } from "../../_shared/tools/preventista/mis_clientes.ts";

export function formatMisClientesResult(r: MisClientesResult): string {
  if (r.clientes.length === 0) {
    return "No tenés clientes asignados\\.";
  }

  const header = `*${r.clientes.length}* de *${r.total}* clientes:`;
  const lines = r.clientes.map((c) => {
    const codigo = c.codigo != null ? `\\#${c.codigo} ` : "";
    const nombre = `*${escapeMarkdownV2(c.nombre)}*`;
    const saldo = c.saldo_cuenta > 0
      ? ` 💰 ${escapeMarkdownV2(formatCurrency(c.saldo_cuenta))}`
      : "";
    const ultima = c.dias_desde_ultima != null
      ? ` \\| ${c.dias_desde_ultima}d`
      : " \\| sin compras";
    return `${codigo}${nombre}${saldo}${ultima}`;
  });
  return [header, ...lines].join("\n");
}
