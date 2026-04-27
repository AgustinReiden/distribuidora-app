// Formatters para resultados de tools de cliente (buscar_cliente, ficha_cliente).
//
// Usamos MarkdownV2 porque permite negritas + monospace para IDs sin meter
// HTML (Telegram acepta `MarkdownV2` o `HTML`, no ambos a la vez). El catch
// de MarkdownV2 es que TODO char reservado debe escaparse — incluso dentro
// de "texto seguro" como un nombre. Por eso pasamos cada string user-supplied
// (o de DB) por `escapeMarkdownV2`.
//
// Nota: en strings literales escapamos los chars MarkdownV2 con `\\` para
// que la sintaxis sea válida en TS y llegue a Telegram como `\.`.

import { escapeMarkdownV2 } from "../../_shared/telegram.ts";
import { formatCurrency, formatFechaCorta } from "../../_shared/tools/formatters.ts";
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
  const header = `*${r.clientes.length}* de *${r.total}* resultado${plural}:`;

  const lines = r.clientes.map((c) => {
    const codigo = c.codigo != null ? `\\#${c.codigo} ` : "";
    const nombre = `*${escapeMarkdownV2(c.nombre)}*`;
    const saldo = c.saldo_cuenta !== 0
      ? ` \\| ${escapeMarkdownV2(`saldo: ${formatCurrency(c.saldo_cuenta)}`)}`
      : "";
    const zona = c.zona ? ` \\| zona: ${escapeMarkdownV2(c.zona)}` : "";
    return `${codigo}${nombre}${saldo}${zona}\nID: \`${c.id}\``;
  });

  return [header, ...lines].join("\n\n");
}

/**
 * Formatea la ficha financiera completa (`ficha_cliente`). Bloque cabecera
 * con datos del cliente + bloque numérico con saldo, crédito, totales y
 * últimos movimientos.
 */
export function formatFichaCliente(r: FichaClienteResult): string {
  const c = r.cliente;
  const parts: string[] = [];

  const codigoSuffix = c.codigo != null ? ` \\(\\#${c.codigo}\\)` : "";
  parts.push(`*${escapeMarkdownV2(c.nombre)}*${codigoSuffix}`);
  if (c.zona) parts.push(`Zona: ${escapeMarkdownV2(c.zona)}`);
  if (c.direccion) parts.push(`📍 ${escapeMarkdownV2(c.direccion)}`);
  if (c.telefono) parts.push(`📞 ${escapeMarkdownV2(c.telefono)}`);
  parts.push("");
  parts.push(`*Saldo actual:* ${escapeMarkdownV2(formatCurrency(r.saldo_actual))}`);
  parts.push(
    `*Crédito disponible:* ${escapeMarkdownV2(formatCurrency(r.credito_disponible))}` +
      ` de ${escapeMarkdownV2(formatCurrency(r.limite_credito))}`,
  );
  parts.push(
    `Pedidos: *${r.total_pedidos}* \\| Compras: ${escapeMarkdownV2(formatCurrency(r.total_compras))}` +
      ` \\| Pagos: ${escapeMarkdownV2(formatCurrency(r.total_pagos))}`,
  );
  if (r.pedidos_pendientes_pago > 0) {
    parts.push(`Pendientes de pago: *${r.pedidos_pendientes_pago}*`);
  }
  if (r.ultimo_pedido) {
    const fechaFmt = formatFechaCorta(r.ultimo_pedido.fecha);
    const monto = r.ultimo_pedido.monto != null && r.ultimo_pedido.monto !== 0
      ? ` por ${formatCurrency(r.ultimo_pedido.monto)}`
      : "";
    parts.push(`📦 Último pedido: ${escapeMarkdownV2(`${fechaFmt}${monto}`)}`);
  }
  if (r.ultimo_pago) {
    const fechaFmt = formatFechaCorta(r.ultimo_pago.fecha);
    const monto = r.ultimo_pago.monto != null && r.ultimo_pago.monto !== 0
      ? ` por ${formatCurrency(r.ultimo_pago.monto)}`
      : "";
    parts.push(`💵 Último pago: ${escapeMarkdownV2(`${fechaFmt}${monto}`)}`);
  }
  return parts.join("\n");
}
