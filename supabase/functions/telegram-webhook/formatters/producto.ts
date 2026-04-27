// Formatter para `buscar_producto`. Resalta productos con bajo_stock con un
// emoji ⚠️ al principio de la línea para que el operador los detecte de un
// vistazo.

import { escapeMarkdownV2 } from "../../_shared/telegram.ts";
import { formatCurrency } from "../../_shared/tools/formatters.ts";
import type { BuscarProductoResult } from "../../_shared/tools/common/buscar_producto.ts";

export function formatBuscarProductoResult(r: BuscarProductoResult): string {
  if (r.productos.length === 0) {
    return "No encontré productos con esa búsqueda\\.";
  }

  const plural = r.total === 1 ? "" : "s";
  const header = `*${r.productos.length}* de *${r.total}* resultado${plural}:`;

  const lines = r.productos.map((p) => {
    const warn = p.bajo_stock ? "⚠️ " : "";
    const codigo = p.codigo ? `\\[${escapeMarkdownV2(p.codigo)}\\] ` : "";
    const nombre = `*${escapeMarkdownV2(p.nombre)}*`;
    const precio = ` \\| ${escapeMarkdownV2(formatCurrency(p.precio))}`;
    const stock = p.bajo_stock
      ? ` \\| stock: *${p.stock}*/${p.stock_minimo}`
      : ` \\| stock: ${p.stock}`;
    const cat = p.categoria ? ` \\| ${escapeMarkdownV2(p.categoria)}` : "";
    return `${warn}${codigo}${nombre}${precio}${stock}${cat}\nID: \`${p.id}\``;
  });

  return [header, ...lines].join("\n\n");
}
