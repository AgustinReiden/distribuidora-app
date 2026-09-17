// Catálogo de secciones del digest y el filtrado de métricas que las aplica.
//
// El mecanismo es deliberadamente tonto: en vez de explicarle a Gemini qué
// secciones omitir, le sacamos los datos del JSON. El prompt ya tiene la regla
// "si un campo está en 0 o vacío, no lo menciones", así que una clave ausente
// desaparece del mensaje sola. Explicarlo en el prompt sería pedirle al modelo
// que obedezca; sacarlo del input no le deja alternativa.
//
// ESTA LISTA TIENE TRES PUNTAS Y HAY QUE MOVERLAS JUNTAS:
//   1. el CHECK `bot_digest_config_secciones_ck` (migración de bot_digest_config)
//      — es el gate: rechaza una clave que no exista;
//   2. `SECCIONES` de acá — dice qué datos entran al mensaje;
//   3. `SECCIONES_DIGEST` en `src/hooks/queries/useBotDigestConfig.ts` — las
//      etiquetas del panel.
// Si agregás una sección al CHECK y no acá, se guarda y no se muestra nunca.
// El test `secciones.test.ts` verifica que 2 y 3 coincidan con la lista literal.

/** Clave de sección, tal como se guarda en `bot_digest_config.secciones`. */
export type SeccionDigest =
  | "ventas"
  | "top_clientes"
  | "top_productos"
  | "stock_critico"
  | "deuda"
  | "pendientes_entrega"
  | "pendientes_pago"
  | "recorridos"
  | "rendiciones"
  | "vencimientos";

/**
 * Qué claves del JSON de `bot_metricas_admin_dia` habilita cada sección.
 *
 * `vencimientos` va con lista vacía porque no sale de esa RPC: es una lectura
 * aparte (`fetchLotesCriticos`) que se pega al final del mensaje sin pasar por
 * Gemini. Igual vive en este catálogo porque para el admin que la prende o
 * apaga en el panel es una sección más.
 */
export const SECCIONES: Record<SeccionDigest, readonly string[]> = {
  ventas: ["ventas_dia", "promedio_7d", "delta_pct"],
  top_clientes: ["top_clientes"],
  top_productos: ["top_productos"],
  stock_critico: ["stock_critico"],
  deuda: ["cxc_vencido", "cuentas_por_cobrar"],
  pendientes_entrega: ["pendientes_entrega"],
  pendientes_pago: ["pendientes_pago"],
  recorridos: ["recorridos_hoy"],
  rendiciones: ["rendiciones_pendientes"],
  vencimientos: [],
};

/**
 * Claves que van SIEMPRE, sin importar la configuración: son el contexto que
 * necesita el modelo para no inventar el día ni la sucursal.
 */
const CLAVES_SIEMPRE = ["fecha", "sucursal_id"] as const;

/**
 * Deja en el JSON de métricas sólo las claves de las secciones pedidas.
 *
 * Una clave desconocida en `secciones` se ignora en silencio a propósito: la
 * fuente de esa lista es la base, y una fila vieja con una sección que después
 * se sacó del catálogo no tiene que voltear el digest de esa persona.
 */
export function filtrarMetricas(
  metricas: unknown,
  secciones: readonly string[],
): unknown {
  if (metricas === null || typeof metricas !== "object") return metricas;

  const origen = metricas as Record<string, unknown>;
  const permitidas = new Set<string>(CLAVES_SIEMPRE);
  for (const s of secciones) {
    const claves = SECCIONES[s as SeccionDigest];
    if (claves) { for (const c of claves) permitidas.add(c); }
  }

  const salida: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(origen)) {
    if (permitidas.has(k)) salida[k] = v;
  }
  return salida;
}

/** ¿La configuración pide la sección de lotes por vencer? */
export function incluyeVencimientos(secciones: readonly string[]): boolean {
  return secciones.includes("vencimientos");
}

/**
 * ¿Queda algo que contar además del contexto fijo?
 *
 * Un digest cuya única sección es `vencimientos` no tiene nada que pedirle a
 * Gemini: el bloque de lotes se arma con `formatVencimientosTexto`, sin modelo.
 */
export function tieneSeccionesDeMetricas(secciones: readonly string[]): boolean {
  return secciones.some((s) => (SECCIONES[s as SeccionDigest]?.length ?? 0) > 0);
}
