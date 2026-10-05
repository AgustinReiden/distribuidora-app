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
// LA SEÑAL. La factura declara el II abierto por alícuota. Por alícuota:
//
//   ΔII = declarado − calculado           (calculado: el del motor, sin ajuste,
//                                           con los cargos tal como están)
//   base implícita = ΔII / (tasa / 100)   (cuánto neto MÁS liquidó el proveedor)
//
// Una ΔII positiva y por encima de la tolerancia del solver dice que el
// proveedor liquidó II sobre más neto del que suman las líneas: es la huella de
// una bonificación que no bajó la base. Una ΔII negativa es otra cosa (un
// descuento que SÍ bajó la base, o una alícuota mal cargada) y acá no se
// sugiere nada.
//
// LO QUE YA ESTÁ EXPLICADO NO SE VUELVE A SUGERIR. Una bonificación ya cargada
// —cargo gravado, negativo, que no baja la base del II— explica la parte que le
// toca a las líneas de esa alícuota. Sólo lo que falta después de restarla es
// candidato. Por eso, una vez aceptada la sugerencia, desaparece sola.
//
// EL MONTO. Si quien carga tipeó el neto gravado impreso (o, en su defecto, el
// total), la brecha contra lo calculado es el monto: es un número que el papel
// trae al centavo, mientras que el que se deduce del II arrastra el redondeo
// del proveedor dividido por la tasa (un centavo de II son 11,5 centavos de
// base al 8,6957%). Las dos señales tienen que coincidir dentro de la
// tolerancia: si el papel contradice al II —por ejemplo porque las líneas ya se
// cargaron con la bonificación adentro— no se sugiere nada, porque agregarla
// la descontaría dos veces. Sin totales tipeados, el monto es la base implícita.
//
// EL ALCANCE. Las líneas gravadas de esa alícuota y NUNCA otra: una línea al 0%
// (soda) o exenta (Pindapoy) no puede explicar una diferencia de II, así que
// meterla en el reparto sería inventar. Si la compra anterior del proveedor
// tenía una bonificación, se prefiere su alcance (por producto) cortado con las
// líneas de esta alícuota.
//
// Es una SUGERENCIA. Esta función no toca nada: quien la llama decide si la
// muestra, y el usuario si la acepta.
// =============================================================================

/**
 * Tolerancia de coincidencia entre la bonificación que deduce el II y la que
 * dice el papel, medida en PESOS DE IMPUESTO INTERNO de la alícuota:
 *
 *   max(PISO, base de la alícuota × RELATIVA) + POR_LINEA × líneas de la alícuota
 *
 *  - PISO, $2: abajo de eso el resto del sistema ya no afirma nada (el ✓ del
 *    control contra factura y el solver usan $1; acá hay dos números
 *    redondeados en juego en vez de uno).
 *  - RELATIVA, 1e-6 de la base: la tasa se guarda a 4 decimales (8,6957 por
 *    8,695652…), y ese truncado mueve el II hasta 5e-7 de la base. El doble de
 *    margen.
 *  - POR_LINEA, $0,01: el proveedor redondea el II de cada renglón al centavo.
 *
 * Se mide en pesos de II y no de base porque es ahí donde está el error: pasado
 * a base se divide por la tasa (un centavo de II al 4,1667% son 24 centavos de
 * base). Un parámetro que el negocio quiera mover iría a `politicas_comerciales`;
 * hoy no lo es.
 */
export const TOLERANCIA_BONIF_PISO = 2
export const TOLERANCIA_BONIF_RELATIVA = 1e-6
export const TOLERANCIA_BONIF_POR_LINEA = 0.01

/** Tolerancia de coincidencia, en pesos de II. Ver las constantes. */
export function toleranciaCoincidenciaBonif(baseAlicuota: number, lineas: number): number {
  return Math.max(TOLERANCIA_BONIF_PISO, Math.abs(baseAlicuota) * TOLERANCIA_BONIF_RELATIVA)
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
  /** La alícuota de II, normalizada a 4 decimales. */
  tasa: number
  /** declarado − calculado, en pesos de II. */
  diferenciaII: number
  /** Lo que falta explicar, en pesos de base: ΔII / tasa menos lo ya cargado. */
  baseImplicita: number
  /** El importe de la bonificación, POSITIVO. El cargo va con −monto. */
  monto: number
  /** De dónde sale el monto. */
  origenMonto: 'gravado' | 'total' | 'impuesto_interno'
  /** Las líneas sobre las que se reparte. Todas de esta alícuota. */
  lineaIds: number[]
  /** Si el alcance salió de la compra anterior o es la alícuota entera. */
  alcance: 'compra_anterior' | 'alicuota'
}

const tasaII = (t: number) => redondearSQL(t || 0, 4)

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

interface Candidata {
  tasa: number
  diferenciaII: number
  baseImplicita: number
  baseAlicuota: number
  lineasAlicuota: number
  lineaIds: number[]
  alcance: SugerenciaBonificacion['alcance']
  ivaAlcance: number
}

/**
 * Las bonificaciones que la factura sugiere que faltan, una por alícuota.
 * Función pura; ver el encabezado del archivo para el razonamiento.
 */
export function detectarBonificacionNoDescontada(entrada: EntradaBonificacion): SugerenciaBonificacion[] {
  const { lineas, cargos, iiDeclarado, control, alcanceAnterior } = entrada

  const declarado = new Map<number, number>()
  for (const [clave, monto] of Object.entries(iiDeclarado)) {
    if (Number.isFinite(monto) && monto > 0) declarado.set(tasaII(Number(clave)), monto)
  }
  if (declarado.size === 0) return []

  // El calculado sale del motor SIN apertura declarada, como en el cuadre y en
  // el solver: con la apertura puesta el factor de ajuste lo forzaría al
  // declarado y la diferencia daría siempre 0. Un peso corrupto no es asunto de
  // esta función: lo grita la vista previa de costos.
  let costos
  let repartos: Map<number, Record<number, number>>
  try {
    costos = calcularCostosCompra(lineas, cargos, {})
    repartos = new Map(cargos.map(c => [c.id, prorratearCargo(c.monto, c.pesos)]))
  } catch {
    return []
  }

  // Bonificaciones ya cargadas que NO bajan la base: cada una explica la parte
  // que le toca a las líneas de cada alícuota.
  const explicativas = cargos.filter(c => c.condicionIva === 'gravado' && c.monto < 0 && !c.afectaBaseII)
  const alcancePrevio = alcanceAnterior && alcanceAnterior.length > 0 ? new Set(alcanceAnterior.map(String)) : null

  const candidatas: Candidata[] = []
  for (const [tasa, montoDeclarado] of [...declarado.entries()].sort((a, b) => a[0] - b[0])) {
    const deLaTasa = lineas
      .map((l, i) => ({ l, costos: costos.lineas[i] }))
      .filter(({ l }) => l.cantidad > 0 && tasaII(l.impuestosInternos) === tasa)
    if (deLaTasa.length === 0) continue

    const calculado = deLaTasa.reduce((acc, x) => acc + (x.costos?.iiUnitario ?? 0) * x.l.cantidad, 0)
    const diferenciaII = montoDeclarado - calculado
    // Abajo de la tolerancia del solver la alícuota CIERRA: es la misma vara del
    // ✓ del cuadre. Y negativa no es este caso.
    if (diferenciaII <= toleranciaII(montoDeclarado)) continue

    const ids = new Set(deLaTasa.map(x => x.l.id))
    const explicada = -explicativas.reduce((acc, c) => {
      const reparto = repartos.get(c.id) ?? {}
      return acc + Object.entries(reparto).reduce((s, [id, parte]) => s + (ids.has(Number(id)) ? parte : 0), 0)
    }, 0)
    const baseImplicita = diferenciaII / (tasa / 100) - explicada
    if (baseImplicita * (tasa / 100) <= toleranciaII(montoDeclarado)) continue

    // Alcance: sólo líneas GRAVADAS de esta alícuota. El cargo es gravado y una
    // línea exenta con II no tiene base de IVA donde caer.
    const gravadas = deLaTasa.filter(x => x.l.condicionIva === 'gravado').map(x => x.l)
    if (gravadas.length === 0) continue
    const delAnterior = alcancePrevio ? gravadas.filter(l => alcancePrevio.has(String(l.productoId))) : []
    const alcanceLineas = delAnterior.length > 0 ? delAnterior : gravadas
    const neto = (l: LineaCompra) => l.cantidad * l.costoUnitario * (1 - (l.bonificacion || 0) / 100)
    const netoAlcance = alcanceLineas.reduce((acc, l) => acc + neto(l), 0)
    const ivaAlcance = netoAlcance > 0
      ? alcanceLineas.reduce((acc, l) => acc + neto(l) * l.porcentajeIva, 0) / netoAlcance / 100
      : 0

    candidatas.push({
      tasa,
      diferenciaII,
      baseImplicita,
      baseAlicuota: deLaTasa.reduce((acc, x) => acc + neto(x.l), 0),
      lineasAlicuota: deLaTasa.length,
      lineaIds: alcanceLineas.map(l => l.id),
      alcance: delAnterior.length > 0 ? 'compra_anterior' : 'alicuota',
      ivaAlcance,
    })
  }
  if (candidatas.length === 0) return []

  // La brecha contra el papel, pasada a pesos de NETO. Con el gravado impreso es
  // directa. Con sólo el total, una bonificación gravada que no toca el II baja
  // el total en su neto más su IVA, así que se divide por (1 + IVA del alcance).
  // Sin ninguno de los dos, no hay papel que consultar.
  const sumaBases = candidatas.reduce((acc, c) => acc + c.baseImplicita, 0)
  let brecha: number | null = null
  let origen: SugerenciaBonificacion['origenMonto'] = 'impuesto_interno'
  if (control && control.gravadoImpreso > 0) {
    brecha = control.gravadoCalculado - control.gravadoImpreso
    origen = 'gravado'
  } else if (control && control.totalImpreso > 0) {
    const ivaPonderado = candidatas.reduce((acc, c) => acc + c.ivaAlcance * c.baseImplicita, 0) / sumaBases
    brecha = (control.totalCalculado - control.totalImpreso) / (1 + ivaPonderado)
    origen = 'total'
  }

  if (brecha !== null) {
    // El papel tiene que contar la MISMA historia que el II. La tolerancia de
    // cada alícuota está en pesos de II: pasada a base, se suma.
    const tolerancia = candidatas.reduce(
      (acc, c) => acc + toleranciaCoincidenciaBonif(c.baseAlicuota, c.lineasAlicuota) / (c.tasa / 100), 0)
    if (Math.abs(brecha - sumaBases) > tolerancia) return []
  }

  // Con papel, el monto es la brecha, repartida entre alícuotas en proporción a
  // lo que dedujo cada una (con una sola alícuota, la brecha entera). Así el
  // cuadre contra el papel cierra al centavo después de aceptar.
  return candidatas.map(c => ({
    tasa: c.tasa,
    diferenciaII: redondearSQL(c.diferenciaII, 2),
    baseImplicita: redondearSQL(c.baseImplicita, 2),
    monto: redondearSQL(brecha !== null ? brecha * c.baseImplicita / sumaBases : c.baseImplicita, 2),
    origenMonto: origen,
    lineaIds: c.lineaIds,
    alcance: c.alcance,
  }))
}
