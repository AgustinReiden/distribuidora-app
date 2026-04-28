// Formatter para `ficha_producto` — análogo a formatFichaCliente. Header
// con emoji 📦 + bold del nombre + bloque numérico (precio, stock,
// categoría) + bloque de métricas (ventas 30d, última venta).

import {
  bullet,
  divider,
  escapeMarkdownV2,
  formatCurrency,
  formatFechaCorta,
  header,
  kvRowRaw,
  statusBadge,
} from "../../_shared/format.ts";
import type { FichaProductoResult } from "../../_shared/tools/common/ficha_producto.ts";

export function formatFichaProducto(r: FichaProductoResult): string {
  const p = r.producto;
  const parts: string[] = [];

  // ----- Cabecera del producto -------------------------------------------
  parts.push(header(p.nombre, "📦"));
  if (p.codigo) {
    parts.push(`Código: \`${escapeMarkdownV2(p.codigo)}\``);
  }
  if (p.categoria) {
    parts.push(bullet(escapeMarkdownV2(p.categoria), "🏷️"));
  }

  // ----- Bloque numérico --------------------------------------------------
  parts.push(divider());
  parts.push(
    kvRowRaw("Precio", `*${escapeMarkdownV2(formatCurrency(p.precio))}*`),
  );

  // Stock con badge si está bajo el mínimo.
  const stockBadge = p.bajo_stock ? `${statusBadge("warn")} ` : "";
  const stockTxt = p.bajo_stock
    ? `*${p.stock}*/${p.stock_minimo} \\(bajo mínimo\\)`
    : `${p.stock} \\(mínimo: ${p.stock_minimo}\\)`;
  parts.push(`*Stock:* ${stockBadge}${stockTxt}`);

  // ----- Métricas de ventas ----------------------------------------------
  parts.push(divider());
  parts.push(
    bullet(`Ventas \\(30d\\): *${r.ventas_30d_cantidad}* unidades`, "📊"),
  );
  if (r.ultima_venta) {
    parts.push(
      bullet(
        `Última venta: ${escapeMarkdownV2(formatFechaCorta(r.ultima_venta))}`,
        "📅",
      ),
    );
  } else {
    parts.push(bullet("Sin ventas registradas", "📅"));
  }

  return parts.join("\n");
}
