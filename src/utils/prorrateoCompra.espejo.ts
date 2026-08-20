import {
  prorratearCargo,
  calcularCostosCompra,
  type CargoCompra,
  type CostosCompra,
  type LineaCompra,
  type PesosCargo,
} from './prorrateoCompra'
import { redondearSQL, type CondicionIva } from './calculations'

// =============================================================================
// EL ESPEJO ENTRE LAS DOS IMPLEMENTACIONES DEL MOTOR DE COMPRAS
// =============================================================================
//
// Hay dos motores que tienen que dar el MISMO número al centavo:
//
//   · TypeScript — `src/utils/prorrateoCompra.ts`. Alimenta la vista previa del
//     modal, que anticipa el costo sin ir a la base.
//   · SQL — `prorratear_cargo` y `calcular_costos_compra` (mig 193). Es la
//     implementación CANÓNICA: lo que se persiste sale de ahí.
//
// Existen las dos porque el número se calcula y se guarda en la base pero el
// modal tiene que mostrarlo antes de guardar. Los dos archivos dicen "si cambiás
// una, cambiá la otra" desde el día uno, y hasta ahora eso era una frase.
//
// Este módulo es el material compartido de las dos capas que lo verifican:
//
//   1 · `prorrateoCompra.espejo.test.ts` — vitest, sin red. Corre el TS contra
//       un fixture con la salida del SQL. Rápido, siempre, pero SÓLO ve el lado
//       TS: el fixture es una foto, no la base.
//   2 · `scripts/espejo-motor-compras.mjs` — corre LAS DOS sobre los mismos
//       casos y las compara adentro de Postgres. Es el que ve los dos lados, y
//       el único que puede detectar que se movió el SQL. Vive en el gate de
//       integridad, que es el que tiene credenciales.
//
// NADA DE ACÁ ENTRA AL BUNDLE: ningún módulo de la app lo importa. Vive en
// `src/utils` y no en `scripts/` porque el test de vitest sólo levanta
// `src/**/*.test.ts`, y porque el dato de la factura testigo que exporta es el
// mismo que consume el golden.
//
// EL CONTRATO DE COMPARACIÓN, que es lo que hace que esto signifique algo:
//
//   · Las entradas se escriben UNA vez, en forma de cable (el JSON snake_case
//     que viajaría a la RPC), y el MISMO texto va a los dos motores. Si cada
//     lado armara su propia entrada, el espejo compararía dos cosas distintas.
//   · La comparación numérica la hace Postgres con `IS DISTINCT FROM` sobre
//     `numeric`, no JS: así `500` contra `500.00` no cuenta —numeric ignora la
//     escala— y un centavo sí.
//   · Se compara a `DECIMALES_ESPEJO` decimales y no bit a bit, porque el TS
//     acumula en `double` y el SQL en `numeric` (decimal exacto). Esa diferencia
//     es de orden 1e-9 sobre los montos de esta factura; el redondeo que este
//     espejo tiene que cazar es de 1e-2. Ver la constante.
//
// =============================================================================

/**
 * Decimales a los que se comparan las dos implementaciones.
 *
 * No es una tolerancia elegida a ojo. El TS suma en `double` y el SQL en
 * `numeric`, que es decimal exacto: sobre la factura testigo (13,3 M repartidos
 * en 21 líneas) el error relativo del double, 2^-52, deja una discrepancia del
 * orden de 1e-9. Comparar bit a bit haría fallar el espejo por eso y no por un
 * bug. Comparar al centavo dejaría pasar un cambio de redondeo de 3 decimales.
 *
 * 6 decimales están tres órdenes de magnitud arriba del ruido del double y
 * cuatro por debajo del centavo: caza cualquier divergencia real y no inventa
 * ninguna. Si alguna vez hay que moverlo, que sea con la cuenta hecha.
 */
export const DECIMALES_ESPEJO = 6

export type MotorEspejo = 'prorratear_cargo' | 'calcular_costos_compra'

/** Un caso: un nombre, qué motor lo corre y la entrada en forma de cable. */
export interface CasoEspejo {
  caso: string
  motor: MotorEspejo
  /** El JSON tal cual viaja: claves snake_case, como las de la mig 192. */
  entrada: Record<string, unknown>
  /** De dónde salió. Va al reporte, para que ningún caso quede sin dueño. */
  origen: string
}

// -----------------------------------------------------------------------------
// Traducción entre la forma de cable (snake_case, la de la mig 192) y la del TS
//
// Es mecánica y va en un solo lugar a propósito: es la única diferencia legítima
// entre los dos motores —el TS usa camelCase y el jsonb de la RPC snake_case— y
// dos copias de esta tabla se desincronizan igual que los motores.
//
// Las funciones `deWire` NO validan ni completan: el casteo es a ciegas para que
// un caso de contrato —una condición inventada, una cantidad nula— llegue al
// motor exactamente como llegaría desde la red. Validar acá taparía justo lo que
// se quiere medir. `espejoRoundTrip` en el test fija que la traducción de ida y
// vuelta sea la identidad, así el golden no se compara contra una entrada
// mutilada sin que nadie se entere.
// -----------------------------------------------------------------------------

export function lineaAWire(l: LineaCompra): Record<string, unknown> {
  return {
    id: l.id,
    cantidad: l.cantidad,
    costo_unitario: l.costoUnitario,
    bonificacion: l.bonificacion,
    impuestos_internos: l.impuestosInternos,
    porcentaje_iva: l.porcentajeIva,
    condicion_iva: l.condicionIva,
  }
}

export function lineaDeWire(e: Record<string, unknown>): LineaCompra {
  return {
    id: e.id as number,
    cantidad: e.cantidad as number,
    costoUnitario: e.costo_unitario as number,
    bonificacion: e.bonificacion as number,
    impuestosInternos: e.impuestos_internos as number,
    porcentajeIva: e.porcentaje_iva as number,
    condicionIva: e.condicion_iva as CondicionIva,
  }
}

export function cargoAWire(c: CargoCompra): Record<string, unknown> {
  return {
    id: c.id,
    concepto: c.concepto,
    monto: c.monto,
    condicion_iva: c.condicionIva,
    en_factura: c.enFactura,
    prorratea_al_costo: c.prorrateaAlCosto,
    afecta_base_ii: c.afectaBaseII,
    pesos: c.pesos,
  }
}

export function cargoDeWire(e: Record<string, unknown>): CargoCompra {
  return {
    id: e.id as number,
    concepto: e.concepto as string,
    monto: e.monto as number,
    condicionIva: e.condicion_iva as CondicionIva,
    enFactura: e.en_factura as boolean,
    prorrateaAlCosto: e.prorratea_al_costo as boolean,
    afectaBaseII: e.afecta_base_ii as boolean,
    pesos: e.pesos as PesosCargo,
  }
}

/**
 * La salida del motor de TS, escrita con los nombres del jsonb de la mig 193.
 *
 * Las líneas van ORDENADAS POR ID porque el SQL las emite con `ORDER BY f.id` y
 * el TS en el orden de entrada: sin esto la comparación cotejaría `lineas[0]` de
 * uno contra `lineas[0]` del otro y en una factura con los ids desordenados
 * marcaría 126 divergencias que no existen.
 */
export function costosAWire(r: CostosCompra): Record<string, unknown> {
  return {
    lineas: [...r.lineas]
      .sort((a, b) => a.id - b.id)
      .map(l => ({
        id: l.id,
        base_iva: l.baseIvaUnitaria,
        ii: l.iiUnitario,
        cargos: l.cargosUnitarios,
        iva: l.ivaUnitario,
        costo_neto: l.costoNetoUnitario,
        costo_real: l.costoRealUnitario,
      })),
    totales: {
      neto_gravado: r.totales.netoGravado,
      neto_exento: r.totales.netoExento,
      neto_no_gravado: r.totales.netoNoGravado,
      iva: r.totales.iva,
      impuestos_internos: r.totales.impuestosInternos,
      no_gravado: r.totales.noGravado,
      cargos_al_costo: r.totales.cargosAlCosto,
    },
    factor_ajuste: r.factorAjuste,
  }
}

/** Lo que devuelve correr el motor de TS sobre un caso: un valor o una excepción. */
export interface SalidaTS {
  ts: Record<string, unknown> | null
  ts_error: string | null
}

/**
 * Corre el motor de TypeScript sobre la entrada de cable de un caso.
 *
 * Atrapa la excepción y la devuelve como dato en vez de dejarla propagar: que
 * una implementación LANCE es parte del resultado que hay que comparar, no un
 * accidente. Un caso de contrato pasa sólo si las dos lanzan.
 */
export function correrMotorTS(caso: CasoEspejo): SalidaTS {
  try {
    if (caso.motor === 'prorratear_cargo') {
      const e = caso.entrada as { monto: number; pesos: PesosCargo }
      return { ts: prorratearCargo(e.monto, e.pesos) as Record<string, unknown>, ts_error: null }
    }
    const e = caso.entrada as {
      items: Record<string, unknown>[]
      cargos: Record<string, unknown>[]
      ii_declarado: Record<number, number>
    }
    // `ii_declarado` va SIN traducir: las claves de un objeto de JS ya son texto,
    // así que el objeto del cable ES el que espera el motor. Traducirlo con
    // Number() colapsaría "10" y "10.0" en una sola clave y taparía el caso de
    // los buckets que se pisan.
    const costos = calcularCostosCompra(
      e.items.map(lineaDeWire),
      e.cargos.map(cargoDeWire),
      e.ii_declarado
    )
    return { ts: costosAWire(costos), ts_error: null }
  } catch (err) {
    return { ts: null, ts_error: err instanceof Error ? err.message : String(err) }
  }
}

// -----------------------------------------------------------------------------
// Comparación (la del lado JS, para la capa 1)
//
// La capa 2 compara adentro de Postgres, que es la que vale. Esta reproduce el
// mismo criterio sobre el fixture: mismo camino de aplanado —así los nombres de
// campo de los dos reportes son los mismos— y mismo redondeo.
// -----------------------------------------------------------------------------

/**
 * La misma estructura con cada número redondeado a `decimales`.
 *
 * Es lo que se congela en el fixture. El SQL devuelve `numeric` con veinte
 * decimales de relleno (`100.00000000000000000000`) o con la cola entera de una
 * división (`198.5433333333333333`), y ninguna de las dos cosas se puede
 * preservar: JSON.parse ya las bajó a `double`. Guardar `198.54333333333332`
 * sería un número que no es ni el del SQL ni el de nadie; guardar `198.543333`
 * es exactamente lo que el espejo compara, y además se lee en un diff.
 */
export function redondearSalida(valor: unknown, decimales: number = DECIMALES_ESPEJO): unknown {
  if (typeof valor === 'number') return redondearSQL(valor, decimales)
  if (Array.isArray(valor)) return valor.map(v => redondearSalida(v, decimales))
  if (valor !== null && typeof valor === 'object') {
    return Object.fromEntries(
      Object.entries(valor).map(([k, v]) => [k, redondearSalida(v, decimales)])
    )
  }
  return valor
}

export interface DivergenciaEspejo {
  campo: string
  ts: unknown
  sql: unknown
  motivo: string
}

/** Aplana un JSON a `{ '.lineas[0].base_iva': 4764.85, … }`. Mismo path que el SQL. */
function hojas(valor: unknown, path = '', acc = new Map<string, unknown>()): Map<string, unknown> {
  if (Array.isArray(valor)) {
    valor.forEach((v, i) => hojas(v, `${path}[${i}]`, acc))
    return acc
  }
  if (valor !== null && typeof valor === 'object') {
    for (const [k, v] of Object.entries(valor)) hojas(v, `${path}.${k}`, acc)
    return acc
  }
  acc.set(path, valor)
  return acc
}

/**
 * Las celdas en las que dos salidas del motor no dicen lo mismo.
 *
 * Devuelve también cuántas celdas se compararon: un caso que compara 0 celdas
 * (las dos salidas vacías) pasa, y el reporte tiene que dejarlo ver en vez de
 * contarlo como una victoria.
 */
export function diferencias(
  ts: unknown,
  sql: unknown,
  decimales: number = DECIMALES_ESPEJO
): { celdas: number; divergencias: DivergenciaEspejo[] } {
  const a = hojas(ts)
  const b = hojas(sql)
  const campos = [...new Set([...a.keys(), ...b.keys()])].sort()
  const divergencias: DivergenciaEspejo[] = []

  for (const campo of campos) {
    const enTS = a.has(campo)
    const enSQL = b.has(campo)
    const vTS = a.get(campo)
    const vSQL = b.get(campo)
    if (!enTS || !enSQL) {
      divergencias.push({
        campo,
        ts: vTS ?? null,
        sql: vSQL ?? null,
        motivo: enTS ? 'falta en el SQL' : 'falta en el TS',
      })
      continue
    }
    if (typeof vTS === 'number' && typeof vSQL === 'number') {
      if (redondearSQL(vTS, decimales) !== redondearSQL(vSQL, decimales)) {
        divergencias.push({ campo, ts: vTS, sql: vSQL, motivo: 'difiere' })
      }
      continue
    }
    if (vTS !== vSQL) divergencias.push({ campo, ts: vTS, sql: vSQL, motivo: 'difiere' })
  }

  return { celdas: campos.length, divergencias }
}

// =============================================================================
// LA FACTURA TESTIGO
// =============================================================================

/**
 * Factura A0005-00461415 de Manaos: 21 renglones, 13,3 M. Es el caso que motivó
 * el rediseño de cargos y el único con la respuesta conocida de antemano (el
 * Excel del gerente).
 *
 * Vive acá y no adentro del golden porque ahora tiene DOS consumidores —el
 * golden, que fija los números contra el Excel, y el espejo, que la manda a los
 * dos motores— y dos copias de 21 líneas se desincronizan sin que nada avise.
 */
export const ITEMS_TESTIGO: LineaCompra[] = [
  { id: 1,  cantidad: 60,  costoUnitario: 4793.61, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 2,  cantidad: 60,  costoUnitario: 4793.61, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 3,  cantidad: 120, costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 4,  cantidad: 75,  costoUnitario: 3994.67, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 5,  cantidad: 75,  costoUnitario: 3994.67, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 6,  cantidad: 120, costoUnitario: 2972.04, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 7,  cantidad: 80,  costoUnitario: 2316.91, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 8,  cantidad: 280, costoUnitario: 2197.07, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 9,  cantidad: 120, costoUnitario: 4626.22, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 10, cantidad: 150, costoUnitario: 5123.97, bonificacion: 0.6, impuestosInternos: 0,      porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 11, cantidad: 240, costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 12, cantidad: 60,  costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 13, cantidad: 60,  costoUnitario: 5992.01, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 14, cantidad: 120, costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 15, cantidad: 60,  costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 16, cantidad: 115, costoUnitario: 8347.11, bonificacion: 0.6, impuestosInternos: 0,      porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 17, cantidad: 140, costoUnitario: 3822.90, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 18, cantidad: 140, costoUnitario: 3822.90, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 19, cantidad: 140, costoUnitario: 3822.90, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 20, cantidad: 120, costoUnitario: 2796.27, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 21, cantidad: 168, costoUnitario: 1030.63, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
]

const neto = (id: number) => {
  const l = ITEMS_TESTIGO.find(x => x.id === id)!
  return l.cantidad * l.costoUnitario * (1 - l.bonificacion / 100)
}
const pesosPorMonto = (ids: number[]) => Object.fromEntries(ids.map(id => [id, neto(id)]))

// Pallets segun la factura. El flete reparte sobre 26 (los Placer 500cc entran
// medio pallet); los pallets valorizados se cobran sobre 27 (esos dos van enteros).
const PALLETS_FLETE: Record<number, number> = { 1: .5, 2: .5, 3: 2, 4: .5, 5: .5, 6: 1, 7: 1, 8: 2, 9: 1, 10: 2, 11: 4, 12: 1, 13: 1, 14: 2, 15: 1, 16: 1, 17: 1, 18: 1, 19: 1, 20: 1, 21: 1 }
const PALLETS:       Record<number, number> = { ...PALLETS_FLETE, 4: 1, 5: 1 }

export const CARGOS_TESTIGO: CargoCompra[] = [
  { id: 1, concepto: 'Flete y descarga', monto: 1_900_000, condicionIva: 'no_gravado',
    enFactura: false, prorrateaAlCosto: true, afectaBaseII: false, pesos: PALLETS_FLETE },
  { id: 2, concepto: 'Pallets x 9 tacos', monto: 162_000, condicionIva: 'no_gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: PALLETS },
  { id: 3, concepto: 'Separadores bidon', monto: 8_800, condicionIva: 'no_gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: { 21: 1 } },
  // Descuento de precio: SI baja la base del impuesto interno
  { id: 4, concepto: 'Bonif. promo COLA 3.00', monto: -103_465.32, condicionIva: 'gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: true, pesos: pesosPorMonto([3, 11]) },
  // Bonificacion comercial: NO baja la base del impuesto interno. Este flag es
  // TODO el descubrimiento: sin el, el II no cuadra por casi 5%.
  { id: 5, concepto: 'Bonif. promo 3000cc', monto: -203_318.28, condicionIva: 'gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: pesosPorMonto([3, 11, 12, 13, 14, 15]) },
  { id: 6, concepto: 'Redondeo', monto: -0.49, condicionIva: 'gravado',
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: true, pesos: pesosPorMonto(ITEMS_TESTIGO.map(i => i.id)) },
]

export const II_DECLARADO_TESTIGO: Record<number, number> = { 8.6956: 338_884.46, 4.1667: 199_027.21 }

// =============================================================================
// LOS CASOS
// =============================================================================

const entradaCostos = (
  items: LineaCompra[],
  cargos: CargoCompra[] = [],
  iiDeclarado: Record<number, number> = {}
): Record<string, unknown> => ({
  items: items.map(lineaAWire),
  cargos: cargos.map(cargoAWire),
  ii_declarado: iiDeclarado,
})

const linea = (over: Partial<LineaCompra> = {}): LineaCompra => ({
  id: 1, cantidad: 10, costoUnitario: 100, bonificacion: 0,
  impuestosInternos: 0, porcentajeIva: 21, condicionIva: 'gravado', ...over,
})
const cargo = (over: Partial<CargoCompra> = {}): CargoCompra => ({
  id: 1, concepto: 'x', monto: 0, condicionIva: 'no_gravado',
  enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: {}, ...over,
})

const UNIT = 'prorrateoCompra.test.ts'
const GOLDEN = 'prorrateoCompra.golden.test.ts'

/**
 * Los repartos: los diez casos unitarios de `prorratearCargo`, tal cual están en
 * la suite. No hay ninguno inventado a propósito: un caso que no está en ningún
 * test es un caso que nadie revisó.
 */
const CASOS_PRORRATEO: CasoEspejo[] = [
  { caso: 'reparto · proporcional al peso', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 1000, pesos: { 1: 1, 2: 1 } } },
  { caso: 'reparto · la suma da el monto exacto', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 1000, pesos: { 1: 1, 2: 1, 3: 1 } } },
  { caso: 'reparto · el residuo va a la linea de mayor peso', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 100, pesos: { 1: 1, 2: 1, 3: 4 } } },
  { caso: 'reparto · empate de peso maximo: desempata por menor id', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 100, pesos: { 7: 1, 3: 1, 5: 1 } } },
  { caso: 'reparto · peso cero excluye la linea', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 880, pesos: { 1: 0, 2: 0, 3: 1 } } },
  { caso: 'reparto · monto negativo (bonificacion)', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: -100, pesos: { 1: 1, 2: 1, 3: 1 } } },
  { caso: 'reparto · redondeo de Postgres: medio centavo negativo', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: -0.01, pesos: { 1: 1, 2: 1 } } },
  { caso: 'reparto · suma de pesos cero devuelve vacio', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 1000, pesos: { 1: 0, 2: 0 } } },
  { caso: 'reparto · sin pesos devuelve vacio', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 100, pesos: {} } },
  { caso: 'reparto · el flete real: 1.900.000 sobre 26 pallets', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 1_900_000, pesos: PALLETS_FLETE } },
]

/** Los casos de `calcularCostosCompra` que ya fija la suite unitaria. */
const CASOS_MOTOR: CasoEspejo[] = [
  { caso: 'motor · sin cargos: neto x (1 + II%)', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ impuestosInternos: 8.6956 })]) },
  { caso: 'motor · un cargo NO gravado entra al costo pero no a la base de IVA', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea()], [cargo({ monto: 500, pesos: { 1: 1 } })]) },
  { caso: 'motor · un cargo fuera de factura entra al costo y no al IVA', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea()], [cargo({ monto: 500, condicionIva: 'gravado', enFactura: false, pesos: { 1: 1 } })]) },
  { caso: 'motor · afectaBaseII=false: baja el IVA pero no el impuesto interno', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ impuestosInternos: 10 })], [cargo({ monto: -200, condicionIva: 'gravado', afectaBaseII: false, pesos: { 1: 1 } })]) },
  { caso: 'motor · afectaBaseII=true: baja las dos bases', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ impuestosInternos: 10 })], [cargo({ monto: -200, condicionIva: 'gravado', afectaBaseII: true, pesos: { 1: 1 } })]) },
  { caso: 'motor · el factor de ajuste cuadra el II declarado', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ impuestosInternos: 10 })], [], { 10: 110 }) },
  { caso: 'motor · cantidad 0 no explota', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ cantidad: 0 })]) },
  { caso: 'motor · la linea exenta no suma a netoGravado pero tiene costo', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ id: 1 }), linea({ id: 2, condicionIva: 'exento', porcentajeIva: 0 })]) },
  { caso: 'motor · la linea no gravada abre su propio total', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ id: 1 }), linea({ id: 2, condicionIva: 'no_gravado', porcentajeIva: 0 })]) },
  { caso: 'motor · un cargo en factura que no prorratea: no gravado y no costo', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea()], [cargo({ monto: 500, prorrateaAlCosto: false, pesos: { 1: 1 } })]) },
  { caso: 'motor · 4.17 y 4.1667 son alicuotas distintas', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ id: 1, impuestosInternos: 4.1667 }), linea({ id: 2, impuestosInternos: 4.17 })], [], { 4.1667: 50 }) },
]

/** La factura testigo entera: 21 líneas, 6 cargos, las dos alícuotas declaradas. */
const CASOS_TESTIGO: CasoEspejo[] = [
  { caso: 'testigo · factura A0005-00461415 completa', motor: 'calcular_costos_compra', origen: GOLDEN,
    entrada: entradaCostos(ITEMS_TESTIGO, CARGOS_TESTIGO, II_DECLARADO_TESTIGO) },
  { caso: 'testigo · la misma factura sin el cargo de separadores', motor: 'calcular_costos_compra', origen: GOLDEN,
    entrada: entradaCostos(ITEMS_TESTIGO, CARGOS_TESTIGO.filter(c => c.concepto !== 'Separadores bidon'), II_DECLARADO_TESTIGO) },
  { caso: 'testigo · sin el II declarado (factor 1, sin ajuste)', motor: 'calcular_costos_compra', origen: GOLDEN,
    entrada: entradaCostos(ITEMS_TESTIGO, CARGOS_TESTIGO) },
]

/**
 * Los casos de CONTRATO: los dos motores tienen que LANZAR.
 *
 * Coincidir cuando andan es la mitad del espejo. La otra mitad es que el dato
 * corrupto se frene en los dos lados: si el SQL lanza y el TS devuelve un
 * número, la vista previa le muestra al usuario un costo que la base va a
 * rechazar —o peor, uno que nadie va a poder explicar—.
 *
 * SOBRE EL NaN Y EL INFINITO: no existen en JSON. `JSON.stringify(NaN)` es
 * `null`, así que en el cable —que es lo que este espejo compara— la única forma
 * de un peso podrido es `null` o una cadena. Los dos casos están, y los dos
 * motores tienen que rechazar los dos.
 */
const CASOS_CONTRATO: CasoEspejo[] = [
  { caso: 'contrato · peso negativo', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 100, pesos: { 1: 1, 2: -1 } } },
  { caso: 'contrato · peso no finito (null en el cable)', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 100, pesos: { 1: null, 2: 1 } } },
  { caso: 'contrato · peso no finito (la cadena "NaN")', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 100, pesos: { 1: 1, 2: 'NaN' } } },
  { caso: 'contrato · monto no finito (null en el cable)', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: null, pesos: { 1: 1 } } },
  { caso: 'contrato · monto no finito (la cadena "Infinity")', motor: 'prorratear_cargo', origen: UNIT,
    entrada: { monto: 'Infinity', pesos: { 1: 1 } } },
  { caso: 'contrato · cantidad negativa', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: entradaCostos([linea({ id: 7, cantidad: -1 })]) },
  { caso: 'contrato · cantidad no finita (null en el cable)', motor: 'calcular_costos_compra', origen: UNIT,
    entrada: { items: [{ ...lineaAWire(linea({ id: 4 })), cantidad: null }], cargos: [], ii_declarado: {} } },
  { caso: 'contrato · condicion_iva invalida en la linea', motor: 'calcular_costos_compra', origen: 'mig 193',
    entrada: { items: [{ ...lineaAWire(linea()), condicion_iva: 'gravada' }], cargos: [], ii_declarado: {} } },
  { caso: 'contrato · condicion_iva invalida en el cargo', motor: 'calcular_costos_compra', origen: 'mig 193',
    entrada: { items: [lineaAWire(linea())], cargos: [{ ...cargoAWire(cargo({ monto: 100, pesos: { 1: 1 } })), condicion_iva: 'grabado' }], ii_declarado: {} } },
  { caso: 'contrato · dos lineas con el mismo id', motor: 'calcular_costos_compra', origen: 'mig 193',
    entrada: entradaCostos([linea({ id: 1 }), linea({ id: 1 })]) },
  { caso: 'contrato · dos tasas declaradas que colapsan al mismo bucket', motor: 'calcular_costos_compra', origen: 'mig 193',
    entrada: { items: [lineaAWire(linea({ impuestosInternos: 10 }))], cargos: [], ii_declarado: { '10': 100, '10.0': 100 } } },
]

/** Todo lo que el espejo compara. El orden es el del reporte. */
export const CASOS_ESPEJO: CasoEspejo[] = [
  ...CASOS_PRORRATEO,
  ...CASOS_MOTOR,
  ...CASOS_TESTIGO,
  ...CASOS_CONTRATO,
]

/**
 * Los casos que esperan que LAS DOS implementaciones lancen.
 *
 * Se deriva del nombre y no de un flag por caso para que agregar un caso de
 * contrato sea imposible de olvidar marcar.
 */
export const esCasoDeContrato = (c: CasoEspejo) => c.caso.startsWith('contrato ·')

/**
 * LO QUE ESTE ESPEJO NO CUBRE. Está acá y no sólo en el README porque un límite
 * que no se lee es un límite que se olvida:
 *
 *  · `resolverBasesII` NO TIENE ESPEJO EN SQL. El solver de bases de impuesto
 *    interno vive sólo en TypeScript: la mig 193 no lo implementa y no hay nada
 *    contra qué compararlo. Lo cubren `prorrateoCompra.test.ts` y el golden, y
 *    nada más. Que use `calcularCostosCompra` por dentro tampoco lo cubre: el
 *    espejo verifica el motor, no la búsqueda que lo llama 2^N veces.
 *  · `calcularTotalesCompra` y `lineaParaMotor` tampoco: la regla de ZZ y la
 *    cabecera fiscal tienen su espejo en la mig 194 (`v_items_motor`), que este
 *    archivo no toca.
 *  · Los DEFAULTS del borde jsonb. La mig 193 completa las claves ausentes
 *    (`condicion_iva`, `en_factura`, `porcentaje_iva`…) y el TS no las tiene
 *    porque se las exige el compilador. Es una asimetría deliberada y
 *    documentada en la 193; acá todos los casos mandan el objeto completo.
 */
export const NO_CUBIERTO = [
  'resolverBasesII (el solver de bases de II) no tiene implementacion en SQL: no hay espejo posible',
  'calcularTotalesCompra / lineaParaMotor (la regla de ZZ y la cabecera fiscal, mig 194)',
  'los defaults del borde jsonb de la mig 193: todos los casos mandan el objeto completo',
] as const
