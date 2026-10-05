import { redondearSQL } from './calculations'
import { calcularCostosCompra, prorratearCargo, toleranciaII } from './prorrateoCompra'
import type { CargoCompra, LineaCompra } from './prorrateoCompra'
import { normalizarNombreConcepto } from './medidasCargo'
import type { CargoPlantillaCompra } from '../types'

// =============================================================================
// LA BONIFICACIÓN QUE EL PROVEEDOR NO DESCONTÓ DE LA BASE DEL II (#908)
// =============================================================================
//
// EL CASO. Algunos proveedores (el de referencia es Refres Now / Manaos) liquidan
// el impuesto interno sobre el neto de la línea ANTES de una bonificación de
// promoción, y la bonificación aparece en la factura como un descuento aparte
// que NO se resta de la base del II. Si quien carga no agrega ese descuento como
// cargo, el costo queda inflado y nada lo avisa.
//
// Hay DOS huellas posibles, según cómo se cargaron las líneas:
//
// CASO A · la del II. Por alícuota declarada:
//
//   ΔII = declarado − calculado           (calculado: el del motor, sin ajuste,
//                                           con los cargos tal como están)
//   base implícita = ΔII / (tasa / 100)   (cuánto neto MÁS liquidó el proveedor)
//
//   Una ΔII positiva y por encima de la tolerancia del solver dice que el
//   proveedor liquidó II sobre más neto del que suman las líneas. Se le resta lo
//   que ya explican las bonificaciones cargadas que no bajan la base (por eso,
//   aceptada, la sugerencia desaparece). Una ΔII negativa es otra cosa (un
//   descuento que SÍ bajó la base, o una alícuota mal cargada): nada.
//   Si se tipeó el gravado (o el total) del papel, la brecha tiene que coincidir
//   dentro de la tolerancia y da el monto al centavo; si lo contradice —las
//   líneas ya traían la bonificación adentro— no se sugiere nada, porque
//   agregarla la descontaría dos veces. Sin papel, el monto es la base implícita.
//
// CASO B · la del papel. Es la forma común de la factura Manaos: líneas a precio
//   lleno y un renglón "Bonif. promo" aparte que no baja la base del II. Si quien
//   carga se olvida ese renglón, el II declarado CIERRA (la bonificación no lo
//   toca) pero el gravado impreso queda Y por DEBAJO del calculado. Las dos
//   condiciones juntas son la huella: un descuento gravado que no movió el II.
//   La bonificación va con `afectaBaseII = false` fijado a mano: el II ya cierra
//   sin ella, y prenderlo lo descuadraría.
//   El II no dice en qué alícuota cae el descuento (con afectaBaseII en false no
//   mueve ninguna), así que el alcance sale de: la compra anterior si tenía una
//   bonificación; si no, la única alícuota con tasa > 0; y si hay más de una,
//   ninguno: se ofrece igual y el usuario elige las líneas en el reparto.
//
// A y B no se pisan: B sólo corre si NINGUNA alícuota tiene una ΔII sin
// explicar. Si A dispara, la brecha del papel ya es la suya.
//
// EL ALCANCE NUNCA incluye una línea al 0% (soda) ni exenta (Pindapoy): no tienen
// II con el que el proveedor pudiera haber liquidado de más, y el cargo es
// gravado.
//
// Es una SUGERENCIA. Esta función no toca nada: quien la llama decide si la
// muestra, y el usuario si la acepta.
// =============================================================================

/**
 * Tolerancia de coincidencia:
 *
 *   max(PISO, base × RELATIVA) + POR_LINEA × líneas
 *
 * En el caso A se mide en PESOS DE IMPUESTO INTERNO de la alícuota (es ahí donde
 * está el error: un centavo de II al 4,1667% son 24 centavos de base):
 *  - PISO, $2: abajo de eso el resto del sistema ya no afirma nada (el ✓ del
 *    control contra factura y el solver usan $1; acá hay dos números
 *    redondeados en juego en vez de uno).
 *  - RELATIVA, 1e-6 de la base: la tasa se guarda a 4 decimales (8,6957 por
 *    8,695652…), y ese truncado mueve el II hasta 5e-7 de la base. El doble de
 *    margen.
 *  - POR_LINEA, $0,01: el proveedor redondea el II de cada renglón al centavo.
 *
 * En el caso B se aplica la misma fórmula en pesos de NETO al gravado: es el
 * umbral a partir del cual la brecha contra el papel deja de ser redondeo de
 * renglones. Un parámetro que el negocio quiera mover iría a
 * `politicas_comerciales`; hoy no lo es.
 */
export const TOLERANCIA_BONIF_PISO = 2
export const TOLERANCIA_BONIF_RELATIVA = 1e-6
export const TOLERANCIA_BONIF_POR_LINEA = 0.01

/** La tolerancia de arriba. La unidad la pone quien la usa (ver las constantes). */
export function toleranciaCoincidenciaBonif(base: number, lineas: number): number {
  return Math.max(TOLERANCIA_BONIF_PISO, Math.abs(base) * TOLERANCIA_BONIF_RELATIVA)
    + TOLERANCIA_BONIF_POR_LINEA * lineas
}

/** Una línea tal como la ve el motor, más el producto (para el alcance). */
export interface LineaBonificable extends LineaCompra {
  productoId: string
}

/**
 * Totales del papel que tipeó quien carga (0 = no cargado) y los que calcula
 * hoy el modal con los cargos actuales.
 */
export interface ControlBonificacion {
  gravadoImpreso: number
  gravadoCalculado: number
  totalImpreso: number
  totalCalculado: number
}

export interface EntradaBonificacion {
  /** Las líneas ya pasadas por `lineaParaMotor` (en ZZ la tasa de II llega en 0). */
  lineas: LineaBonificable[]
  cargos: CargoCompra[]
  /** tasa → II declarado en la factura. */
  iiDeclarado: Record<number, number>
  control?: ControlBonificacion | null
  /** Productos que tocaba la bonificación de la compra anterior del proveedor. */
  alcanceAnterior?: readonly string[] | null
}

export interface SugerenciaBonificacion {
  /**
   * Clave estable para descartarla: `ii:<tasa>` (caso A) o `papel` (caso B).
   */
  clave: string
  /** 'impuesto_interno' = caso A (ΔII > 0); 'papel' = caso B (II cierra, el gravado no). */
  caso: 'impuesto_interno' | 'papel'
  /** La alícuota de II, normalizada. null en B cuando el alcance no es de una sola. */
  tasa: number | null
  /** declarado − calculado, en pesos de II. 0 en el caso B. */
  diferenciaII: number
  /** Caso A: lo que falta explicar, en pesos de base (ΔII / tasa menos lo cargado). Caso B: el monto. */
  baseImplicita: number
  /** El importe de la bonificación, POSITIVO. El cargo va con −monto. */
  monto: number
  /** De dónde sale el monto. */
  origenMonto: 'gravado' | 'total' | 'impuesto_interno'
  /** Las líneas sobre las que se reparte. Vacío = sin alcance: lo elige el usuario. */
  lineaIds: number[]
  alcance: 'compra_anterior' | 'alicuota' | 'sin_alcance'
}

const tasaII = (t: number) => redondearSQL(t || 0, 4)
const neto = (l: LineaCompra) => l.cantidad * l.costoUnitario * (1 - (l.bonificacion || 0) / 100)

/** ¿Este concepto es una bonificación? "Bonificación", "Bonif. promo 3L"… */
export function esConceptoBonificacion(concepto: string | null | undefined): boolean {
  return normalizarNombreConcepto(concepto).startsWith('bonif')
}

/**
 * Los productos que tocaba la bonificación de la compra anterior del proveedor
 * (la plantilla de `useCargosPlantillaProveedorQuery`).
 *
 * Se prefieren las que NO bajaban la base del II —son las de este caso— y si no
 * hay ninguna, cualquier bonificación gravada. null = no había.
 */
export function alcanceBonificacionAnterior(
  plantilla: readonly CargoPlantillaCompra[] | null | undefined,
): string[] | null {
  const bonifs = (plantilla ?? []).filter(c => c.condicionIva === 'gravado' && esConceptoBonificacion(c.concepto))
  const preferidas = bonifs.some(c => !c.afectaBaseII) ? bonifs.filter(c => !c.afectaBaseII) : bonifs
  const productos = new Set<string>()
  for (const c of preferidas) {
    for (const [producto, peso] of Object.entries(c.pesosPorProducto)) {
      if (peso > 0) productos.add(String(producto))
    }
  }
  return productos.size > 0 ? [...productos] : null
}

// -----------------------------------------------------------------------------
// El análisis por alícuota (compartido con el resumen del modal)
// -----------------------------------------------------------------------------

export interface AnalisisAlicuotaII {
  tasa: number
  declarado: number
  calculado: number
  /** declarado − calculado, en pesos de II. */
  diferenciaII: number
  /** Base que explican las bonificaciones cargadas que no bajan la base. */
  explicada: number
  /** ΔII / tasa − explicada, en pesos de base. */
  faltante: number
  /**
   * 'cierra': |ΔII| dentro de la tolerancia del solver.
   * 'negativa': declarado < calculado, fuera de tolerancia.
   * 'explicada': ΔII > 0 y la cubren bonificaciones cargadas que no bajan la base.
   * 'falta': ΔII > 0 y queda base sin explicar (caso A).
   */
  estado: 'cierra' | 'negativa' | 'explicada' | 'falta'
  /** Líneas con cantidad > 0 de esta alícuota (todas las condiciones). */
  lineas: LineaBonificable[]
}

/**
 * El cuadre del II alícuota por alícuota, leído en clave de bonificación no
 * descontada. Sólo las alícuotas declaradas que tienen líneas. null si el motor
 * no pudo calcular (un peso corrupto: lo grita la vista previa de costos).
 *
 * El calculado sale del motor SIN apertura declarada, como en el cuadre y en el
 * solver: con la apertura puesta el factor de ajuste lo forzaría al declarado y
 * la diferencia daría siempre 0.
 */
export function analizarAlicuotasII(
  lineas: LineaBonificable[],
  cargos: CargoCompra[],
  iiDeclarado: Record<number, number>,
): AnalisisAlicuotaII[] | null {
  const declarado = new Map<number, number>()
  for (const [clave, monto] of Object.entries(iiDeclarado)) {
    if (Number.isFinite(monto) && monto > 0) declarado.set(tasaII(Number(clave)), monto)
  }
  if (declarado.size === 0) return []

  let costos
  let repartos: Map<number, Record<number, number>>
  try {
    costos = calcularCostosCompra(lineas, cargos, {})
    repartos = new Map(cargos.map(c => [c.id, prorratearCargo(c.monto, c.pesos)]))
  } catch {
    return null
  }
  const explicativas = cargos.filter(c => c.condicionIva === 'gravado' && c.monto < 0 && !c.afectaBaseII)

  const salida: AnalisisAlicuotaII[] = []
  for (const [tasa, montoDeclarado] of [...declarado.entries()].sort((a, b) => a[0] - b[0])) {
    const deLaTasa = lineas
      .map((l, i) => ({ l, costos: costos.lineas[i] }))
      .filter(({ l }) => l.cantidad > 0 && tasaII(l.impuestosInternos) === tasa)
    if (deLaTasa.length === 0) continue

    const calculado = deLaTasa.reduce((acc, x) => acc + (x.costos?.iiUnitario ?? 0) * x.l.cantidad, 0)
    const diferenciaII = montoDeclarado - calculado
    const ids = new Set(deLaTasa.map(x => x.l.id))
    const explicada = -explicativas.reduce((acc, c) => {
      const reparto = repartos.get(c.id) ?? {}
      return acc + Object.entries(reparto).reduce((s, [id, parte]) => s + (ids.has(Number(id)) ? parte : 0), 0)
    }, 0)
    const faltante = diferenciaII / (tasa / 100) - explicada
    const tolerancia = toleranciaII(montoDeclarado)
    const estado: AnalisisAlicuotaII['estado'] =
      Math.abs(diferenciaII) <= tolerancia ? 'cierra'
        : diferenciaII < 0 ? 'negativa'
          : faltante * (tasa / 100) <= tolerancia ? 'explicada'
            : 'falta'
    salida.push({
      tasa, declarado: montoDeclarado, calculado, diferenciaII, explicada, faltante, estado,
      lineas: deLaTasa.map(x => x.l),
    })
  }
  return salida
}

/** IVA medio (fracción) de unas líneas, ponderado por neto. */
function ivaPonderado(lineas: LineaCompra[]): number {
  const total = lineas.reduce((acc, l) => acc + neto(l), 0)
  return total > 0 ? lineas.reduce((acc, l) => acc + neto(l) * l.porcentajeIva, 0) / total / 100 : 0
}

/** Las líneas que puede tocar una bonificación: gravadas, con cantidad y con II. */
const bonificables = (lineas: LineaBonificable[]) =>
  lineas.filter(l => l.cantidad > 0 && l.condicionIva === 'gravado' && tasaII(l.impuestosInternos) > 0)

/**
 * La brecha contra el papel en pesos de NETO: con el gravado impreso, directa;
 * con sólo el total, una bonificación gravada que no toca el II baja el total en
 * su neto más su IVA, así que se divide por (1 + IVA del alcance). null = no se
 * tipeó nada del papel.
 */
function brechaPapel(
  control: ControlBonificacion | null | undefined,
  iva: number,
): { brecha: number; origen: 'gravado' | 'total' } | null {
  if (control && control.gravadoImpreso > 0) {
    return { brecha: control.gravadoCalculado - control.gravadoImpreso, origen: 'gravado' }
  }
  if (control && control.totalImpreso > 0) {
    return { brecha: (control.totalCalculado - control.totalImpreso) / (1 + iva), origen: 'total' }
  }
  return null
}

/**
 * Las bonificaciones que la factura sugiere que faltan. Función pura; ver el
 * encabezado del archivo para el razonamiento de los dos casos.
 */
export function detectarBonificacionNoDescontada(entrada: EntradaBonificacion): SugerenciaBonificacion[] {
  const { lineas, cargos, iiDeclarado, control, alcanceAnterior } = entrada
  const analisis = analizarAlicuotasII(lineas, cargos, iiDeclarado)
  if (!analisis || analisis.length === 0) return []
  const alcancePrevio = alcanceAnterior && alcanceAnterior.length > 0 ? new Set(alcanceAnterior.map(String)) : null

  const faltantes = analisis.filter(a => a.estado === 'falta')
  if (faltantes.length > 0) return casoImpuestoInterno(faltantes, alcancePrevio, control)

  // Caso B: TODAS las alícuotas declaradas cierran (o quedan explicadas por lo
  // ya cargado). Una negativa es un descuento que sí bajó la base: no es esto.
  if (analisis.some(a => a.estado === 'negativa')) return []
  return casoPapel(lineas, alcancePrevio, control)
}

function casoImpuestoInterno(
  faltantes: AnalisisAlicuotaII[],
  alcancePrevio: Set<string> | null,
  control: ControlBonificacion | null | undefined,
): SugerenciaBonificacion[] {
  const candidatas = faltantes.flatMap(a => {
    const gravadas = bonificables(a.lineas)
    if (gravadas.length === 0) return []
    const delAnterior = alcancePrevio ? gravadas.filter(l => alcancePrevio.has(String(l.productoId))) : []
    const alcanceLineas = delAnterior.length > 0 ? delAnterior : gravadas
    return [{
      a,
      lineaIds: alcanceLineas.map(l => l.id),
      alcance: (delAnterior.length > 0 ? 'compra_anterior' : 'alicuota') as SugerenciaBonificacion['alcance'],
      iva: ivaPonderado(alcanceLineas),
      base: a.lineas.reduce((acc, l) => acc + neto(l), 0),
    }]
  })
  if (candidatas.length === 0) return []

  const sumaBases = candidatas.reduce((acc, c) => acc + c.a.faltante, 0)
  const iva = candidatas.reduce((acc, c) => acc + c.iva * c.a.faltante, 0) / sumaBases
  const papel = brechaPapel(control, iva)
  if (papel) {
    // El papel tiene que contar la MISMA historia que el II. La tolerancia de
    // cada alícuota está en pesos de II: pasada a base, se suma.
    const tolerancia = candidatas.reduce(
      (acc, c) => acc + toleranciaCoincidenciaBonif(c.base, c.a.lineas.length) / (c.a.tasa / 100), 0)
    if (Math.abs(papel.brecha - sumaBases) > tolerancia) return []
  }

  // Con papel, el monto es la brecha, repartida entre alícuotas en proporción a
  // lo que dedujo cada una (con una sola alícuota, la brecha entera). Así el
  // cuadre contra el papel cierra al centavo después de aceptar.
  return candidatas.map(c => ({
    clave: `ii:${c.a.tasa}`,
    caso: 'impuesto_interno' as const,
    tasa: c.a.tasa,
    diferenciaII: redondearSQL(c.a.diferenciaII, 2),
    baseImplicita: redondearSQL(c.a.faltante, 2),
    monto: redondearSQL(papel ? papel.brecha * c.a.faltante / sumaBases : c.a.faltante, 2),
    origenMonto: papel ? papel.origen : 'impuesto_interno',
    lineaIds: c.lineaIds,
    alcance: c.alcance,
  }))
}

function casoPapel(
  lineas: LineaBonificable[],
  alcancePrevio: Set<string> | null,
  control: ControlBonificacion | null | undefined,
): SugerenciaBonificacion[] {
  const candidatas = bonificables(lineas)
  if (candidatas.length === 0) return []

  // El alcance, en el orden que fijó el dueño: la compra anterior; si no, la
  // única alícuota con tasa > 0; si hay varias, ninguno (lo elige el usuario).
  const delAnterior = alcancePrevio ? candidatas.filter(l => alcancePrevio.has(String(l.productoId))) : []
  const tasas = [...new Set(candidatas.map(l => tasaII(l.impuestosInternos)))]
  let alcance: SugerenciaBonificacion['alcance']
  let alcanceLineas: LineaBonificable[]
  if (delAnterior.length > 0) {
    alcance = 'compra_anterior'
    alcanceLineas = delAnterior
  } else if (tasas.length === 1) {
    alcance = 'alicuota'
    alcanceLineas = candidatas
  } else {
    alcance = 'sin_alcance'
    alcanceLineas = []
  }

  const papel = brechaPapel(control, ivaPonderado(alcanceLineas.length > 0 ? alcanceLineas : candidatas))
  if (!papel) return []
  const tolerancia = toleranciaCoincidenciaBonif(control?.gravadoCalculado ?? 0, lineas.length)
  if (papel.brecha <= tolerancia) return []

  const tasasAlcance = [...new Set(alcanceLineas.map(l => tasaII(l.impuestosInternos)))]
  return [{
    clave: 'papel',
    caso: 'papel',
    tasa: tasasAlcance.length === 1 ? tasasAlcance[0] : null,
    diferenciaII: 0,
    baseImplicita: redondearSQL(papel.brecha, 2),
    monto: redondearSQL(papel.brecha, 2),
    origenMonto: papel.origen,
    lineaIds: alcanceLineas.map(l => l.id),
    alcance,
  }]
}
