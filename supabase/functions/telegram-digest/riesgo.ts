// Sección "plata en riesgo por preventista" del resumen del admin (mig 311).
//
// Va SIN modelo, como la de vencimientos: son números y la RPC ya los trae
// calculados (`bot_riesgo_por_preventista`, que consume `clientes_ritmo_compra`,
// la única definición de "atrasado"). Narrarlos con Gemini sólo agregaría la
// chance de que un monto salga mal.
//
// Texto plano: el resumen del admin se manda sin parse_mode (ver digest.ts).

import type { SupabaseClient } from "@supabase/supabase-js";
import { formatCurrency } from "../_shared/format.ts";

export interface RiesgoPreventista {
  perfil_id: string;
  nombre: string;
  atrasados: number;
  monto_mensual_en_riesgo: number;
  clientes_en_cartera: number;
}

export interface RiesgoSucursal {
  total_atrasados: number;
  total_monto_mensual: number;
  sin_asignar_atrasados: number;
  sin_asignar_monto_mensual: number;
  /** Reservados a administración (mig 214): no son de ninguna cartera a propósito. */
  reservados_atrasados: number;
  reservados_monto_mensual: number;
  preventistas: RiesgoPreventista[];
}

export async function fetchRiesgoPorPreventista(
  sb: SupabaseClient,
  sucursal_id: number,
): Promise<RiesgoSucursal> {
  const { data, error } = await sb.rpc("bot_riesgo_por_preventista", {
    p_sucursal_id: sucursal_id,
  });
  if (error) throw new Error(`bot_riesgo_por_preventista failed: ${error.message}`);
  const r = (data ?? {}) as Record<string, unknown>;
  const filas = (Array.isArray(r.preventistas) ? r.preventistas : []) as Array<Record<string, unknown>>;
  return {
    total_atrasados: Number(r.total_atrasados ?? 0),
    total_monto_mensual: Number(r.total_monto_mensual ?? 0),
    sin_asignar_atrasados: Number(r.sin_asignar_atrasados ?? 0),
    sin_asignar_monto_mensual: Number(r.sin_asignar_monto_mensual ?? 0),
    reservados_atrasados: Number(r.reservados_atrasados ?? 0),
    reservados_monto_mensual: Number(r.reservados_monto_mensual ?? 0),
    preventistas: filas.map((f) => ({
      perfil_id: String(f.perfil_id),
      nombre: String(f.nombre ?? "(sin nombre)"),
      atrasados: Number(f.atrasados ?? 0),
      monto_mensual_en_riesgo: Number(f.monto_mensual_en_riesgo ?? 0),
      clientes_en_cartera: Number(f.clientes_en_cartera ?? 0),
    })),
  };
}

/**
 * El bloque para pegar al final del resumen, o null si no hay ningún cliente
 * atrasado (no hay nada que avisar, igual que vencimientos sin lotes).
 */
export function formatRiesgoTexto(r: RiesgoSucursal): string | null {
  if (r.total_atrasados === 0) return null;

  const lineas = r.preventistas
    .filter((p) => p.atrasados > 0)
    .map((p) =>
      `• ${p.nombre}: ${p.atrasados} ${p.atrasados === 1 ? "cliente" : "clientes"} — ${
        formatCurrency(p.monto_mensual_en_riesgo)
      }/mes`
    );
  if (r.sin_asignar_atrasados > 0) {
    lineas.push(
      `• En ninguna cartera: ${r.sin_asignar_atrasados} — ${
        formatCurrency(r.sin_asignar_monto_mensual)
      }/mes`,
    );
  }
  if (r.reservados_atrasados > 0) {
    lineas.push(
      `• Reservados a administración: ${r.reservados_atrasados} — ${
        formatCurrency(r.reservados_monto_mensual)
      }/mes`,
    );
  }

  return `🔴 Clientes atrasados: ${r.total_atrasados} — compran ${
    formatCurrency(r.total_monto_mensual)
  } por mes\n━━━━━━━━━━━━━━\n\n${lineas.join("\n")}\n\n` +
    // Un cliente puede estar en dos carteras: las filas no suman el total, y
    // dicho así nadie sale a buscar la diferencia.
    "Atrasado = lleva el doble de lo que suele tardar entre compras. " +
    "Un cliente compartido cuenta en las dos carteras. Detalle: /atrasados.";
}
