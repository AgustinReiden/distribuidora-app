// Formatter de `resumen_cliente_visita` para el botón "🧾 <cliente>" del
// resumen de la mañana del preventista (mig 311). Sin modelo: es lo que el
// preventista lee en la puerta del comercio, así que va primero lo accionable
// (qué dejó de llevar, para ofrecérselo) y después el contexto.

import { escapeMarkdownV2, formatCurrency, formatFechaCorta } from "../../_shared/format.ts";
import type { ResumenClienteVisitaResult } from "../../_shared/tools/preventista/resumen_cliente_visita.ts";

const ESTADO: Record<string, string> = {
  atrasado: "🔴 Atrasado",
  por_vencer: "🟡 Por vencer",
  al_dia: "🟢 Al día",
  inactivo: "⚫ Inactivo",
  ocasional: "⚪ Compra de vez en cuando",
  perdido: "⚫ No compra hace más de 6 meses",
  sin_compras: "⚪ Sin compras en el año",
};

export function formatResumenVisita(r: ResumenClienteVisitaResult): string {
  const e = escapeMarkdownV2;
  if (r.error || !r.cliente) {
    return e(r.error ?? "No encontré ese cliente.");
  }
  const c = r.cliente;
  const lineas: string[] = [];

  const codigo = c.codigo != null ? ` \\#${c.codigo}` : "";
  const comodin = c.es_comodin ? e(" (mostrador)") : "";
  lineas.push(`🧾 *${e(c.nombre)}*${codigo}${comodin}`);
  const contacto = [c.direccion, c.telefono].filter((x): x is string => !!x && x.trim() !== "");
  if (contacto.length > 0) lineas.push(e(contacto.join(" · ")));

  if (r.ritmo) {
    const estado = ESTADO[r.ritmo.estado] ?? r.ritmo.estado;
    const detalle = r.ritmo.dias_sin_comprar == null
      ? ""
      : r.ritmo.frecuencia_dias
      ? ` — ${r.ritmo.dias_sin_comprar} días sin comprar, compraba cada ~${Math.round(r.ritmo.frecuencia_dias)}`
      : ` — ${r.ritmo.dias_sin_comprar} días sin comprar`;
    lineas.push("", e(`${estado}${detalle}`));
  }

  if (r.dejados.length > 0) {
    lineas.push("", "*Dejó de llevar \\(ofrecele\\):*");
    for (const p of r.dejados) {
      const cuando = p.ultima_vez ? ` — última vez ${formatFechaCorta(p.ultima_vez)}` : "";
      lineas.push(e(`• ${p.nombre}${cuando}`));
    }
  }

  if (r.top_productos.length > 0) {
    lineas.push("", "*Lo que más lleva \\(90 días\\):*");
    for (const p of r.top_productos) {
      lineas.push(e(`• ${p.nombre} — en ${p.pedidos_con_producto} pedidos, ${p.unidades_totales} u.`));
    }
  }

  const plata: string[] = [];
  if (r.saldo != null && r.saldo > 0) {
    plata.push(`Debe ${formatCurrency(r.saldo)}` +
      (r.limite_credito ? ` (límite ${formatCurrency(r.limite_credito)})` : ""));
  } else if (r.saldo != null && r.saldo < 0) {
    plata.push(`Saldo a favor ${formatCurrency(-r.saldo)}`);
  }
  if (r.ultimo_pedido) {
    // Para el preventista es el último pedido SUYO (montos propios, mig 296).
    const de = r.montos === "propios" ? "Tu último pedido" : "Último pedido";
    plata.push(`${de}: ${formatFechaCorta(r.ultimo_pedido.fecha)}, ${
      formatCurrency(r.ultimo_pedido.total)
    }`);
  }
  if (plata.length > 0) lineas.push("", e(plata.join(" · ")));

  return lineas.join("\n");
}
