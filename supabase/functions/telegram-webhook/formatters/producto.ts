// Formatter para `buscar_producto`. Resalta productos con bajo_stock con un
// badge ⚠️ adelante para que el operador los detecte de un vistazo.

import {
  bullet,
  escapeMarkdownV2,
  formatCurrency,
  header,
  statusBadge,
} from "../../_shared/format.ts";
import type { BuscarProductoResult } from "../../_shared/tools/common/buscar_producto.ts";

export function formatBuscarProductoResult(r: BuscarProductoResult): string {
  if (r.productos.length === 0) {
    return "No encontré productos con esa búsqueda\\.";
  }

  const plural = r.total === 1 ? "" : "s";
  const titulo = `${r.productos.length} de ${r.total} resultado${plural}`;

  const lines = r.productos.map((p) => {
    const warn = p.bajo_stock ? `${statusBadge("warn")} ` : "";
    const codigo = p.codigo ? `\\[${escapeMarkdownV2(p.codigo)}\\] ` : "";
    const nombre = `*${escapeMarkdownV2(p.nombre)}*`;
    const precio = ` \\| 💰 ${escapeMarkdownV2(formatCurrency(p.precio))}`;
    const stock = p.bajo_stock
      ? ` \\| stock: *${p.stock}*/${p.stock_minimo}`
      : ` \\| stock: ${p.stock}`;
    const cat = p.categoria
      ? ` \\| 🏷️ ${escapeMarkdownV2(p.categoria)}`
      : "";
    return bullet(
      `${warn}${codigo}${nombre}${precio}${stock}${cat}\nID: \`${p.id}\``,
    );
  });

  return [header(titulo, "📦"), "", ...lines].join("\n");
}
