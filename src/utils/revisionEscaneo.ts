/**
 * Escáner de facturas, Entrega C: la pantalla de revisión rápida.
 *
 * Lógica pura de la tabla de revisión: qué líneas bloquean el guardado, cuál es
 * la próxima a resolver, qué líneas se van a sumar en un mismo producto, la
 * conversión bulto → unidad que se muestra, y las reglas para pre-llenar el pie
 * de la factura sin pisar lo que la persona tipeó.
 *
 * No sabe de React ni del reducer: el reducer (ModalCompra.reducer.ts) guarda
 * una `RevisionEscaneo` y la tabla (ModalCompra.revision.tsx) la dibuja.
 */
import type { EstadoMatch } from './matchEscaneo'
import { normalizarDescripcion } from './matchEscaneo'
import { redondearSQL } from './calculations'

// =============================================================================
// Tipos
// =============================================================================

/** Lo que la factura imprime en el renglón (lo mapeado por `mapearFacturaV2`). */
export interface LineaImpresa {
  codigo: string | null;
  descripcion: string;
  cantidad: number;
  /** Precio unitario neto, antes de la bonificación. */
  costoUnitario: number;
  /** % de la línea. */
  bonificacion: number;
  /** null = la factura no discrimina la alícuota. */
  iva: number | null;
  /** 'bulto' si la cantidad está en cajas/packs/fardos; null = no se sabe. */
  unidad?: 'bulto' | 'unidad' | null;
  /** Lo que la factura dice que trae el bulto ("x12"). Se OFRECE, no se aplica solo. */
  unidadesPorBulto?: number | null;
  importeNeto?: number | null;
  legible?: boolean;
}

/** Qué decidió la persona (o el matcher, si vinculó solo) para la línea. */
export type ResolucionLinea =
  | { tipo: 'pendiente' }
  | {
      tipo: 'producto';
      productoId: string;
      productoNombre: string;
      /** equivalencia/código (solo) · sugerencia aceptada · elegido a mano · creado acá. */
      via: 'automatico' | 'sugerencia' | 'manual' | 'creado';
      /** Unidades nuestras por unidad facturada. null = 1:1. */
      unidadesPorBulto: number | null;
      /** La persona tocó la conversión en la tabla: se manda a la equivalencia. */
      conversionConfirmada: boolean;
    }
  | { tipo: 'omitida' }

export interface LineaRevision {
  impresa: LineaImpresa;
  /** Lo que propuso el matcher, tal cual (para el chip y para "Enter acepta"). */
  match: {
    estado: EstadoMatch;
    productoId?: string;
    confianza: number;
    motivo: string;
    /** Ids de las alternativas, en orden. */
    alternativas: string[];
    /** Conversión de la equivalencia aprendida. */
    unidadesPorBulto?: number;
  };
  resolucion: ResolucionLinea;
  /** Advertencias de la extracción que apuntan a esta línea. */
  advertencias: string[];
}

export interface RevisionEscaneo {
  lineas: LineaRevision[];
  /** Objeto del bucket `facturas` (para ver la factura al lado). null = no hay. */
  rutaArchivo: string | null;
  /** Advertencias de la factura entera (sin línea). */
  advertenciasGenerales: string[];
  /** El renglón de bonificación del pie, si la factura lo trae (#908). */
  bonificacionPie: { descripcion: string; monto: number } | null;
}

/** El umbral del botón "Aceptar todas las sugeridas ≥ 85%". */
export const UMBRAL_ACEPTAR_TODAS = 0.85

// =============================================================================
// Armado y estado
// =============================================================================

/** Lo mínimo del resultado del matcher que necesita la revisión. */
export interface MatchParaRevision {
  estado: EstadoMatch;
  productoId?: string;
  confianza: number;
  motivo: string;
  alternativas: Array<{ productoId: string }>;
  unidadesPorBulto?: number;
}

/**
 * Las líneas de la revisión, recién salidas del matcher. Sólo `vinculado`
 * (equivalencia aprendida o nuestro código, único) nace resuelta; lo sugerido
 * y lo que no se encontró esperan a la persona. `nombreDe` da el nombre del
 * producto vinculado (si no está en el catálogo, la línea queda pendiente).
 */
export function construirLineasRevision(
  impresas: LineaImpresa[],
  matches: MatchParaRevision[],
  advertencias: Array<{ mensaje: string; linea?: number }>,
  nombreDe: (productoId: string) => string | undefined,
): LineaRevision[] {
  return impresas.map((impresa, i) => {
    const m = matches[i]
    const nombre = m?.productoId ? nombreDe(m.productoId) : undefined
    const resolucion: ResolucionLinea = m?.estado === 'vinculado' && m.productoId && nombre !== undefined
      ? {
          tipo: 'producto', productoId: m.productoId, productoNombre: nombre, via: 'automatico',
          unidadesPorBulto: m.unidadesPorBulto && m.unidadesPorBulto > 0 ? m.unidadesPorBulto : null,
          conversionConfirmada: false,
        }
      : { tipo: 'pendiente' }
    return {
      impresa,
      match: {
        estado: m?.estado ?? 'sin_match',
        productoId: m?.productoId,
        confianza: m?.confianza ?? 0,
        motivo: m?.motivo ?? '',
        alternativas: (m?.alternativas ?? []).map(a => a.productoId),
        ...(m?.unidadesPorBulto ? { unidadesPorBulto: m.unidadesPorBulto } : {}),
      },
      resolucion,
      advertencias: advertencias.filter(a => a.linea === i + 1).map(a => a.mensaje),
    }
  })
}

export interface EstadoDeRevision {
  /** Índices de las líneas que bloquean el guardado. */
  pendientes: number[];
  resueltas: number;
  omitidas: number;
  /** Pendientes con sugerencia de confianza ≥ 85%: lo que acepta el botón. */
  aceptablesEnLote: number[];
  bloqueaGuardado: boolean;
}

/** Una línea pendiente con un producto sugerido para aceptar con Enter. */
export function tieneSugerencia(linea: LineaRevision): boolean {
  return linea.resolucion.tipo === 'pendiente' && !!linea.match.productoId
}

/** Qué líneas bloquean el guardado. "Omitir" cuenta como resuelta. */
export function estadoDeRevision(lineas: LineaRevision[], umbral = UMBRAL_ACEPTAR_TODAS): EstadoDeRevision {
  const pendientes: number[] = []
  const aceptablesEnLote: number[] = []
  let resueltas = 0, omitidas = 0
  lineas.forEach((l, i) => {
    if (l.resolucion.tipo === 'producto') resueltas++
    else if (l.resolucion.tipo === 'omitida') omitidas++
    else {
      pendientes.push(i)
      if (tieneSugerencia(l) && l.match.estado === 'sugerido' && l.match.confianza >= umbral) aceptablesEnLote.push(i)
    }
  })
  return { pendientes, resueltas, omitidas, aceptablesEnLote, bloqueaGuardado: pendientes.length > 0 }
}

/**
 * La próxima línea pendiente DESPUÉS de `desde` en el orden de la tabla, dando
 * la vuelta. null = no queda ninguna (excluyendo `desde`).
 */
export function siguientePendiente(lineas: LineaRevision[], orden: number[], desde: number): number | null {
  const pos = orden.indexOf(desde)
  for (let k = 1; k <= orden.length; k++) {
    const i = orden[(pos + k + orden.length) % orden.length]
    if (i !== desde && lineas[i]?.resolucion.tipo === 'pendiente') return i
  }
  return null
}

// =============================================================================
// Duplicados: dos renglones que terminan en el mismo producto se suman
// =============================================================================

/** productoId → líneas (en orden de la factura) que resolvieron a él, si son 2 o más. */
export function duplicadosPorProducto(lineas: LineaRevision[]): Map<string, number[]> {
  const porProducto = new Map<string, number[]>()
  lineas.forEach((l, i) => {
    if (l.resolucion.tipo !== 'producto') return
    porProducto.set(l.resolucion.productoId, [...(porProducto.get(l.resolucion.productoId) ?? []), i])
  })
  return new Map([...porProducto].filter(([, idx]) => idx.length > 1))
}

/**
 * El orden en que se muestran las líneas: el de la factura, salvo que las que
 * se van a sumar en un mismo producto van juntas, debajo de la primera.
 */
export function ordenRevision(lineas: LineaRevision[]): number[] {
  const duplicados = duplicadosPorProducto(lineas)
  const grupoDe = new Map<number, number[]>()
  for (const idx of duplicados.values()) for (const i of idx) grupoDe.set(i, idx)
  const orden: number[] = []
  const puestos = new Set<number>()
  lineas.forEach((_, i) => {
    if (puestos.has(i)) return
    for (const j of grupoDe.get(i) ?? [i]) {
      orden.push(j)
      puestos.add(j)
    }
  })
  return orden
}

// =============================================================================
// Conversión bulto → unidad
// =============================================================================

/** Unidades nuestras por unidad facturada de la línea resuelta (1 = 1:1). */
export function factorDeLinea(linea: LineaRevision): number {
  return linea.resolucion.tipo === 'producto' && linea.resolucion.unidadesPorBulto && linea.resolucion.unidadesPorBulto > 0
    ? linea.resolucion.unidadesPorBulto
    : 1
}

const numero = (n: number) => n.toLocaleString('es-AR', { maximumFractionDigits: 3 })

/**
 * "2 bultos × 12 = 24 u" si hay conversión; si no, la cantidad con la unidad
 * impresa ("10 bultos", "3 u"; sin unidad, el número solo).
 */
export function textoCantidad(linea: LineaRevision): string {
  const { cantidad, unidad } = linea.impresa
  const factor = factorDeLinea(linea)
  const bultos = `${numero(cantidad)} ${cantidad === 1 ? 'bulto' : 'bultos'}`
  if (factor !== 1) return `${bultos} × ${numero(factor)} = ${numero(redondearSQL(cantidad * factor, 3))} u`
  if (unidad === 'bulto') return bultos
  if (unidad === 'unidad') return `${numero(cantidad)} u`
  return numero(cantidad)
}

/**
 * La conversión que la factura SUGIERE y no está aplicada: la cantidad viene en
 * bultos, dice cuántas unidades trae, y la línea está 1:1. Se ofrece con un
 * clic porque en este catálogo el producto suele SER el bulto (mig 292).
 */
export function conversionOfrecida(linea: LineaRevision): number | null {
  if (linea.resolucion.tipo !== 'producto' || factorDeLinea(linea) !== 1) return null
  const n = linea.impresa.unidadesPorBulto
  return linea.impresa.unidad === 'bulto' && n && n > 1 ? n : null
}

// =============================================================================
// Pre-llenado desde el pie de la factura
// =============================================================================

/**
 * Pre-llena campos numéricos con lo que la factura leyó SIN pisar lo tipeado.
 *
 * Un campo se pisa sólo si está vacío (0) o si lo había escrito un escaneo
 * anterior (`delEscaneo`, la lista que guarda el estado y que se vacía campo
 * por campo cuando la persona lo toca). Lo que la factura no leyó (null o
 * ausente) no se toca nunca. Devuelve los valores nuevos y la lista nueva.
 */
export function prellenarCampos(
  actual: Record<string, number>,
  leido: Record<string, number | null | undefined>,
  delEscaneo: readonly string[],
): { valores: Record<string, number>; delEscaneo: string[] } {
  const valores = { ...actual }
  const marcas = new Set(delEscaneo)
  for (const [clave, valor] of Object.entries(leido)) {
    if (valor === null || valor === undefined || !Number.isFinite(valor)) continue
    const vacio = !valores[clave]
    if (vacio || marcas.has(clave)) {
      valores[clave] = valor
      marcas.add(clave)
    }
  }
  return { valores, delEscaneo: [...marcas] }
}

/** Saca de la lista de "escrito por el escaneo" los campos que la persona tocó. */
export function soltarDelEscaneo(delEscaneo: readonly string[] | undefined, claves: string[]): string[] {
  const lista = delEscaneo ?? []
  return lista.some(c => claves.includes(c)) ? lista.filter(c => !claves.includes(c)) : (lista as string[])
}

const tasaII = (t: number) => redondearSQL(t, 4)

/**
 * El impuesto interno del pie, alícuota por alícuota, contra las tasas que
 * tienen las líneas (la clave de `iiDeclarado`). La factura imprime la tasa
 * redondeada ("8,70") y la ficha la guarda con cuatro decimales (8,6957): se
 * asigna a la tasa de línea más cercana dentro de 0,05 puntos. Sin tasa
 * impresa, sólo si hay una única tasa con II en las líneas y un único renglón.
 * Lo que no se puede asignar se deja afuera: queda en el total de control.
 */
export function iiDelPiePorTasa(
  pie: Array<{ tasa: number | null; monto: number }>,
  tasasDeLineas: number[],
): Record<number, number> {
  const tasas = [...new Set(tasasDeLineas.filter(t => t > 0).map(tasaII))]
  const salida: Record<number, number> = {}
  for (const renglon of pie) {
    if (!(renglon.monto > 0)) continue
    let tasa: number | undefined
    if (renglon.tasa != null) {
      const cercanas = tasas
        .map(t => ({ t, d: Math.abs(t - renglon.tasa!) }))
        .filter(x => x.d <= 0.05)
        .sort((a, b) => a.d - b.d)
      tasa = cercanas[0]?.t
    } else if (tasas.length === 1 && pie.length === 1) {
      tasa = tasas[0]
    }
    if (tasa === undefined) continue
    salida[tasa] = redondearSQL((salida[tasa] ?? 0) + renglon.monto, 2)
  }
  return salida
}

/**
 * El renglón del pie que es una bonificación de promoción ("Bonif. promo",
 * "Dto. promoción"): la suma de los que lo parecen, o null. Un descuento
 * genérico sin esas palabras no se toma: podría ser un pronto pago que ya
 * bajó la base.
 */
export function bonificacionDelPie(
  descuentos: Array<{ descripcion: string; monto: number }> | null | undefined,
): { descripcion: string; monto: number } | null {
  const promo = (descuentos ?? []).filter(d => /\b(bonif|promo|dto|descuento)/.test(normalizarDescripcion(d.descripcion)) && d.monto !== 0)
  if (promo.length === 0) return null
  return {
    descripcion: promo.map(d => d.descripcion.trim()).join(' + '),
    monto: redondearSQL(promo.reduce((acc, d) => acc + Math.abs(d.monto), 0), 2),
  }
}

/**
 * El control que alimenta la detección de #908 cuando la factura trae una
 * bonificación en el pie pero NO se leyó ni el gravado ni el total: el gravado
 * del papel es lo de las líneas menos esa bonificación. Con gravado o total
 * del papel, el control queda como estaba (manda el papel). Sin bonificación
 * en el pie, también.
 *
 * `netoLineas` es el neto gravado de las LÍNEAS solas, sin cargos: así, una vez
 * aceptada la bonificación (un cargo de −monto), el calculado baja lo mismo y
 * la sugerencia se apaga sola.
 */
export function controlConBonificacionDelPie<C extends { gravadoImpreso: number; totalImpreso: number }>(
  control: C,
  bonificacion: { monto: number } | null,
  netoLineas: number,
): C {
  if (!bonificacion || control.gravadoImpreso > 0 || control.totalImpreso > 0 || !(netoLineas > 0)) return control
  return { ...control, gravadoImpreso: redondearSQL(netoLineas - bonificacion.monto, 2) }
}

/** ¿La sugerencia de #908 es el renglón de bonificación del pie? (mismo monto, al peso) */
export function sugerenciaEsLaDelPie(monto: number, bonificacion: { monto: number } | null): boolean {
  return !!bonificacion && Math.abs(monto - bonificacion.monto) <= Math.max(1, bonificacion.monto * 0.001)
}
