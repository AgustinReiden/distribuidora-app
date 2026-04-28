// Formatters para resultados de tools de cliente (buscar_cliente, ficha_cliente).
//
// Lenguaje visual: header con emoji 👥 (lista) o 👤 (ficha individual) +
// divider + bullets. Helpers vienen de _shared/format.ts. MarkdownV2 todo el
// camino — el caller escapa lo que viene user-supplied o de DB.

import {
  bullet,
  divider,
  escapeMarkdownV2,
  formatCurrency,
  formatFechaCorta,
  header,
  kvRowRaw,
} from "../../_shared/format.ts";
import type { BuscarClienteResult } from "../../_shared/tools/common/buscar_cliente.ts";
import type { FichaClienteResult } from "../../_shared/tools/common/ficha_cliente.ts";

/**
 * Formatea el resultado de `buscar_cliente` como mensaje MarkdownV2.
 * Header con cantidad de resultados + una línea por cliente con
 * código, nombre, saldo (si != 0), zona, y el ID en monospace para que el
 * preventista pueda copiarlo y pegarlo en `/saldo <id>`.
 */
export function formatBuscarClienteResult(r: BuscarClienteResult): string {
  if (r.clientes.length === 0) {
    return "No encontré clientes con esa búsqueda\\.";
  }

  const plural = r.total === 1 ? "" : "s";
  const titulo = `${r.clientes.length} de ${r.total} resultado${plural}`;

  const lines = r.clientes.map((c) => {
    const codigo = c.codigo != null ? `\\#${c.codigo} ` : "";
    const nombre = `*${escapeMarkdownV2(c.nombre)}*`;
    const saldo = c.saldo_cuenta !== 0
      ? ` 💰 ${escapeMarkdownV2(formatCurrency(c.saldo_cuenta))}`
      : "";
    const zona = c.zona ? ` \\| 🗺️ ${escapeMarkdownV2(c.zona)}` : "";
    return bullet(`${codigo}${nombre}${saldo}${zona}\nID: \`${c.id}\``);
  });

  return [header(titulo, "👥"), "", ...lines].join("\n");
}

/**
 * Formatea la ficha financiera completa (`ficha_cliente`). Bloque cabecera
 * con datos del cliente + divider + bloque numérico (saldo, crédito,
 * totales) + divider + últimos movimientos.
 */
export function formatFichaCliente(r: FichaClienteResult): string {
  const c = r.cliente;
  const parts: string[] = [];

  // ----- Cabecera del cliente ----------------------------------------------
  const codigoSuffix = c.codigo != null ? ` \\(\\#${c.codigo}\\)` : "";
  parts.push(header(c.nombre, "👤"));
  // Si el header truncara, el original quedaría sin información — repetimos
  // el código en una línea aparte para que aparezca legible incluso si el
  // nombre es muy largo. (Header solo muestra el nombre uppercase.)
  if (codigoSuffix) parts.push(`Código:${codigoSuffix}`);
  if (c.zona) parts.push(bullet(escapeMarkdownV2(c.zona), "🗺️"));
  if (c.direccion) parts.push(bullet(escapeMarkdownV2(c.direccion), "📍"));
  if (c.telefono) parts.push(bullet(escapeMarkdownV2(c.telefono), "📞"));

  // ----- Bloque numérico ---------------------------------------------------
  parts.push(divider());
  parts.push(
    kvRowRaw(
      "Saldo actual",
      `*${escapeMarkdownV2(formatCurrency(r.saldo_actual))}*`,
    ),
  );
  parts.push(
    kvRowRaw(
      "Crédito disponible",
      `${escapeMarkdownV2(formatCurrency(r.credito_disponible))}` +
        ` de ${escapeMarkdownV2(formatCurrency(r.limite_credito))}`,
    ),
  );
  parts.push(
    `Pedidos: *${r.total_pedidos}* \\| Compras: ${
      escapeMarkdownV2(formatCurrency(r.total_compras))
    }` +
      ` \\| Pagos: ${escapeMarkdownV2(formatCurrency(r.total_pagos))}`,
  );
  if (r.pedidos_pendientes_pago > 0) {
    parts.push(
      `⚠️ Pendientes de pago: *${r.pedidos_pendientes_pago}*`,
    );
  }

  // ----- Últimos movimientos ----------------------------------------------
  if (r.ultimo_pedido || r.ultimo_pago) {
    parts.push(divider());
  }
  if (r.ultimo_pedido) {
    const fechaFmt = formatFechaCorta(r.ultimo_pedido.fecha);
    const monto = r.ultimo_pedido.monto != null && r.ultimo_pedido.monto !== 0
      ? ` por ${formatCurrency(r.ultimo_pedido.monto)}`
      : "";
    parts.push(
      bullet(escapeMarkdownV2(`Último pedido: ${fechaFmt}${monto}`), "📦"),
    );
  }
  if (r.ultimo_pago) {
    const fechaFmt = formatFechaCorta(r.ultimo_pago.fecha);
    const monto = r.ultimo_pago.monto != null && r.ultimo_pago.monto !== 0
      ? ` por ${formatCurrency(r.ultimo_pago.monto)}`
      : "";
    parts.push(
      bullet(escapeMarkdownV2(`Último pago: ${fechaFmt}${monto}`), "💵"),
    );
  }
  return parts.join("\n");
}
