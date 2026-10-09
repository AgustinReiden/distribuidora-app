// Cuerpo del resumen diario del ADMIN, armado con plantilla (#1041).
//
// Hasta acá lo redactaba Gemini 2.5 Flash a partir del JSON de
// `bot_metricas_admin_dia`, y Google está retirando ese modelo. Los números ya
// vienen calculados por la RPC: un modelo sólo los reescribía, y podía
// reescribirlos mal (#690: "$1.250" por "$1.250.130"). Igual que el del
// preventista (preventista.ts), ahora es una plantilla: cuesta cero y no puede
// inventar ni cortar un número.
//
// Recibe el JSON YA FILTRADO por las secciones del admin (`filtrarMetricas`):
// una clave ausente es una sección apagada y no se nombra. Una sección con
// todo en cero tampoco se muestra — salvo las ventas, donde "no hubo pedidos"
// es en sí el dato.

import { formatCurrency } from "../_shared/format.ts";

type Fila = Record<string, unknown>;

const num = (x: unknown): number => {
  const n = Number(x ?? 0);
  return Number.isFinite(n) ? n : 0;
};
const obj = (x: unknown): Fila | null =>
  x !== null && typeof x === "object" && !Array.isArray(x) ? x as Fila : null;
const lista = (x: unknown): Fila[] => (Array.isArray(x) ? x.filter((f) => obj(f) !== null) as Fila[] : []);
const plural = (n: number, uno: string, varios: string) => `${n} ${n === 1 ? uno : varios}`;
// Los nombres vienen con espacios de más ("Instituto técnico "): sin el trim
// queda "técnico  — $".
const nombre = (x: unknown, siFalta = "(sin nombre)"): string => String(x ?? "").trim() || siFalta;

/** Cuántos renglones de cada top. El JSON trae hasta 5. */
const TOP = 3;

export function formatMetricasAdmin(metricas: unknown): string {
  const m = obj(metricas);
  if (!m) return "";
  const bloques = [
    bloqueVentas(m),
    bloqueTopClientes(m),
    bloqueTopProductos(m),
    bloqueStock(m),
    bloqueDeuda(m),
    bloquePendientesEntrega(m),
    bloquePendientesPago(m),
    bloqueRecorridos(m),
    bloqueRendiciones(m),
  ].filter((b): b is string => b !== null);
  return bloques.join("\n\n");
}

function bloqueVentas(m: Fila): string | null {
  if (!("ventas_dia" in m) && !("entregado_dia" in m)) return null;
  const tomados = obj(m.ventas_dia);
  const entregado = obj(m.entregado_dia);
  const promedio = obj(m.promedio_7d);
  const pedidosTomados = num(tomados?.pedidos);
  const pedidosEntregados = num(entregado?.pedidos);

  if (pedidosTomados === 0 && pedidosEntregados === 0) {
    return "📊 Ayer no hubo pedidos.";
  }

  const renglones: string[] = [];
  // ventas_dia son los pedidos TOMADOS (cargados, entregados o no); la venta
  // es lo ENTREGADO (mig 241). Nunca se llama "ventas" a lo tomado.
  if (pedidosTomados > 0) {
    let comparacion = "";
    const prom = num(promedio?.total_dia_avg);
    if (prom > 0) {
      const delta = m.delta_pct == null ? null : Math.round(num(m.delta_pct));
      const signo = delta == null ? "" : delta > 0 ? `, +${delta}%` : delta < 0 ? `, −${Math.abs(delta)}%` : ", igual";
      comparacion = ` (promedio 7 días: ${formatCurrency(prom)}${signo})`;
    }
    renglones.push(
      `• Tomados: ${formatCurrency(tomados?.total as number)} en ${plural(pedidosTomados, "pedido", "pedidos")}${comparacion}`,
    );
  } else {
    renglones.push("• No se tomaron pedidos.");
  }
  if (entregado) {
    renglones.push(
      pedidosEntregados > 0
        ? `• Entregado (venta): ${formatCurrency(entregado.total as number)} en ${
          plural(pedidosEntregados, "pedido", "pedidos")
        }`
        : "• Entregado: nada.",
    );
  }
  return `📊 Pedidos de ayer\n${renglones.join("\n")}`;
}

function bloqueTopClientes(m: Fila): string | null {
  const filas = lista(m.top_clientes).slice(0, TOP);
  if (filas.length === 0) return null;
  const renglones = filas.map((c) => {
    // Un comodín agrupa ventas sueltas de mostrador: no es un comercio.
    const n = c.es_comodin ? `${nombre(c.nombre, "Cliente extra")} (mostrador)` : nombre(c.nombre);
    const pedidos = num(c.pedidos);
    return `• ${n} — ${formatCurrency(c.total as number)}${pedidos > 1 ? ` en ${pedidos} pedidos` : ""}`;
  });
  return `🏪 Mejores clientes de ayer\n${renglones.join("\n")}`;
}

function bloqueTopProductos(m: Fila): string | null {
  const filas = lista(m.top_productos).slice(0, TOP);
  if (filas.length === 0) return null;
  const renglones = filas.map((p) => `• ${nombre(p.nombre)} — ${num(p.cantidad)} u.`);
  return `📦 Lo más pedido ayer\n${renglones.join("\n")}`;
}

function bloqueStock(m: Fila): string | null {
  const s = obj(m.stock_critico);
  const total = num(s?.count);
  if (!s || total === 0) return null;
  const top = lista(s.top);
  const renglones = top.map((p) =>
    `• ${nombre(p.nombre)}: quedan ${num(p.stock)} (mínimo ${num(p.stock_minimo)})`
  );
  const mas = total > top.length ? `\n…y ${total - top.length} más.` : "";
  return `⚠️ Stock bajo mínimo: ${plural(total, "producto", "productos")}\n${renglones.join("\n")}${mas}`;
}

function bloqueDeuda(m: Fila): string | null {
  // Los dos números salen de Cuentas por cobrar (mig 324, #983): son los de
  // la pantalla.
  const cxc = obj(m.cuentas_por_cobrar);
  const vencido = obj(m.cxc_vencido);
  const deuda = num(cxc?.deuda_total);
  const montoVencido = num(vencido?.monto_vencido);
  if (deuda <= 0 && montoVencido <= 0) return null;
  const renglones: string[] = [];
  if (deuda > 0) {
    renglones.push(
      `• Por cobrar: ${formatCurrency(deuda)} de ${plural(num(cxc?.clientes_con_saldo), "cliente", "clientes")}`,
    );
  }
  if (montoVencido > 0) {
    renglones.push(
      `• Vencido: ${formatCurrency(montoVencido)} de ${
        plural(num(vencido?.clientes_vencidos), "cliente", "clientes")
      }`,
    );
  }
  return `💰 Cuentas por cobrar\n${renglones.join("\n")}`;
}

function bloquePendientesEntrega(m: Fila): string | null {
  const p = obj(m.pendientes_entrega);
  const n = num(p?.count);
  if (n === 0) return null;
  return `🚚 Sin entregar (últimos 14 días): ${plural(n, "pedido", "pedidos")} por ${formatCurrency(p?.monto as number)}`;
}

function bloquePendientesPago(m: Fila): string | null {
  const p = obj(m.pendientes_pago);
  const n = num(p?.count);
  if (n === 0) return null;
  return `🧾 Pedidos con saldo sin pagar: ${n}, por ${formatCurrency(p?.saldo as number)}`;
}

function bloqueRecorridos(m: Fila): string | null {
  // recorridos_hoy es de HOY (CURRENT_DATE en la RPC), no de ayer.
  const r = obj(m.recorridos_hoy);
  const n = num(r?.count);
  if (n === 0) return null;
  const enCurso = num(r?.en_curso);
  return `🗺️ Recorridos de hoy: ${n}${enCurso > 0 ? ` (${enCurso} en curso)` : ""}, ${
    plural(num(r?.total_paradas), "parada", "paradas")
  }`;
}

function bloqueRendiciones(m: Fila): string | null {
  const r = obj(m.rendiciones_pendientes);
  const n = num(r?.count);
  if (n === 0) return null;
  return `📋 Rendiciones sin controlar: ${n}. La más vieja es de hace ${plural(num(r?.dias_mas_vieja), "día", "días")}.`;
}
