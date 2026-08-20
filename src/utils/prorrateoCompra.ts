import { redondearSQL, type CondicionIva } from './calculations'

/** Vector de pesos de un cargo: id de línea → peso. Peso 0 excluye la línea. */
export type PesosCargo = Record<number, number>

/**
 * Reparte un monto entre líneas según un vector de pesos.
 *
 * La suma de los repartos es EXACTAMENTE el monto: se redondea cada parte a 2
 * decimales y el residuo se asigna a la línea de mayor peso (desempate: menor
 * id). Sin esa regla, repartir sobre pesos fraccionarios no vuelve a sumar el
 * monto y el check de integridad COMPRA-A2 se pone rojo por centavos.
 *
 * Contrato de entrada. El cero es un estado válido; el negativo y el NaN son
 * corrupción:
 *  - Peso 0: legal, excluye la línea. Es el mecanismo de alcance del cargo.
 *  - Todos los pesos en 0, o `pesos` vacío: devuelve {}. Legal, es la grilla a
 *    medio llenar.
 *  - Peso negativo o no finito: lanza, nombrando la línea. Antes un peso
 *    negativo hacía desaparecer el cargo entero sin aviso (los pesos se
 *    cancelaban a 0) y un NaN se redistribuía a las demás líneas. Esto se
 *    convierte en costo: tragárselo es peor que fallar.
 *  - Monto no finito: lanza.
 *
 * La implementación canónica es la de SQL (`prorratear_cargo`, mig 193), porque
 * el prorrateo se calcula y se persiste en la base. Ésta es la réplica que
 * alimenta la vista previa del modal: las dos tienen que dar el mismo número al
 * centavo —de ahí redondearSQL y no redondear— así que si cambiás una, cambiá
 * la otra. Eso ya NO es sólo una frase: lo verifica el espejo
 * (`scripts/espejo-motor-compras.mjs`), que corre las dos sobre los mismos casos
 * y falla si difieren en un centavo. Tocar esto y no el SQL pone rojo el gate.
 */
export function prorratearCargo(monto: number, pesos: PesosCargo): Record<number, number> {
  if (!Number.isFinite(monto)) {
    throw new Error(`prorratearCargo: monto no finito (${monto}).`)
  }

  const entradas = Object.entries(pesos).map(([k, v]) => {
    const id = Number(k)
    // Sin Number(v) || 0 a propósito: convertir NaN en 0 vuelve indistinguible
    // un dato corrupto de una exclusión deliberada, porque 0 ES la exclusión.
    if (!Number.isFinite(v)) {
      throw new Error(
        `prorratearCargo: peso no finito en la linea ${id} (${v}). ` +
        'Se esperan numeros finitos; el 0 excluye una linea.'
      )
    }
    if (v < 0) {
      throw new Error(
        `prorratearCargo: peso negativo en la linea ${id} (${v}). ` +
        'Los pesos son proporciones; el 0 excluye una linea.'
      )
    }
    return [id, v] as const
  })

  // Validados los pesos, esto significa exactamente "todos en cero" (o sin
  // líneas): ya no puede ser una cancelación entre positivos y negativos.
  const totalPeso = entradas.reduce((acc, [, p]) => acc + p, 0)
  if (totalPeso === 0) return {}

  // Mayor peso, desempate por menor id. Sin ordenar: `entradas` queda intacto y
  // el for de abajo conserva su orden. reduce sin semilla es seguro porque el
  // totalPeso === 0 de arriba ya descartó el vector vacío.
  const [idResiduo] = entradas.reduce((mejor, e) =>
    e[1] > mejor[1] || (e[1] === mejor[1] && e[0] < mejor[0]) ? e : mejor
  )

  const salida: Record<number, number> = {}
  let acumulado = 0
  for (const [id, peso] of entradas) {
    if (id === idResiduo) continue
    const parte = redondearSQL(monto * peso / totalPeso, 2)
    salida[id] = parte
    acumulado += parte
  }
  salida[idResiduo] = redondearSQL(monto - acumulado, 2)
  return salida
}

export interface LineaCompra {
  id: number
  cantidad: number
  costoUnitario: number
  bonificacion: number       // %
  impuestosInternos: number  // tasa efectiva %
  porcentajeIva: number      // %
  condicionIva: CondicionIva
}

/**
 * Un cargo de la factura: flete, pallets, separadores, bonificación general.
 *
 * No lleva alícuota propia a propósito: un cargo gravado tributa a la alícuota
 * de las líneas sobre las que se prorratea. Hoy los 247 productos son 21%, así
 * que la distinción no se plantea. Si alguna vez conviven alícuotas distintas
 * en una misma compra, esto deja de alcanzar: hay que decidir qué significa la
 * base gravada de una línea que recibe un cargo de otra alícuota.
 */
export interface CargoCompra {
  id: number
  concepto: string
  monto: number              // SIN IVA. Negativo = bonificación
  condicionIva: CondicionIva
  enFactura: boolean         // suma al cuadre contra el papel
  prorrateaAlCosto: boolean  // entra al costo unitario
  afectaBaseII: boolean
  pesos: PesosCargo
}

export interface CostosLinea {
  id: number
  /** Base sobre la que tributa el IVA de ESTA línea. 0 si la línea no es gravada. */
  baseIvaUnitaria: number
  iiUnitario: number
  cargosUnitarios: number
  ivaUnitario: number
  costoNetoUnitario: number
  costoRealUnitario: number
}

/** El dominio de `condicion_iva`, el mismo que define la mig 192. */
const CONDICIONES_IVA: string[] = ['gravado', 'exento', 'no_gravado']

export interface CostosCompra {
  lineas: CostosLinea[]
  totales: {
    /** Neto de las líneas gravadas + cargos gravados en factura. Cuadra contra el papel. */
    netoGravado: number
    netoExento: number
    netoNoGravado: number
    iva: number
    impuestosInternos: number
    /** Cargos NO gravados EN FACTURA. Va a compras.no_gravado y al cuadre. */
    noGravado: number
    /** Cargos NO gravados que PRORRATEAN. Reconcilia contra Σ cargosUnitarios × cantidad. */
    cargosAlCosto: number
  }
  /** tasa de II (normalizada a 4 decimales) → declarado/calculado. 1 = cuadra solo. */
  factorAjuste: Record<number, number>
}

/**
 * Motor de costos de una compra (espejo de `calcular_costos_compra`, mig 193).
 *
 * Que sea un espejo lo sostiene `scripts/espejo-motor-compras.mjs`, que manda la
 * MISMA entrada a las dos implementaciones y deja que la comparación la haga
 * Postgres; y `prorrateoCompra.espejo.test.ts`, que hace lo mismo contra una
 * foto congelada de la salida del SQL y corre sin base. La canónica es la de
 * SQL: lo que se persiste sale de ahí.
 *
 * Tres bases separadas a propósito, porque responden preguntas distintas:
 *   · baseIva   → neto de la línea (si es gravada) + cargos gravados EN FACTURA.
 *     Alimenta compras.iva y el cuadre contra el papel.
 *   · baseCosto → neto + cargos GRAVADOS que prorratean. Los NO gravados que
 *     prorratean van aparte, en `cargosAlCosto`, y se suman recién en
 *     costoRealUnitario: quien replique esto no tiene que sumarlos dos veces.
 *   · baseII    → neto + los cargos GRAVADOS con afectaBaseII. El filtro por
 *     condición es deliberado, no un olvido: el flag existe para distinguir un
 *     descuento de precio (baja la base) de una bonificación comercial (no la
 *     baja), y las dos son siempre gravadas. Un cargo no gravado —pallets,
 *     separadores— no tiene por qué mover la base del impuesto interno. Mismo
 *     filtro en la mig 193; si cambiás uno, cambiá el otro.
 * El IVA de un flete de transportista inscripto es crédito fiscal: entra su
 * neto al costo, su IVA no entra a ningún lado de esta factura.
 *
 * Los nombres de `totales` son los de calcularTotalesCompra a propósito: los dos
 * clasifican la misma factura y tienen que decir lo mismo con las mismas palabras.
 *
 * Un cargo gravado prorrateado sobre una línea NO gravada suma a `netoGravado`
 * (está en el papel como gravado) pero no a ninguna `baseIvaUnitaria` (la línea
 * no tributa). Es el único caso donde Σ baseIvaUnitaria × cantidad ≠ netoGravado,
 * y es el mismo que el comentario de CargoCompra deja fuera de alcance.
 *
 * @param iiDeclarado - tasa de II → monto declarado en la factura. Vacío = sin ajuste.
 */
export function calcularCostosCompra(
  lineas: LineaCompra[],
  cargos: CargoCompra[],
  iiDeclarado: Record<number, number>
): CostosCompra {
  // Clave de bucket de II. Las tasas reales son 4.1667 y 8.6956, y en compra_items
  // conviven 4.1667 y 4.1700 (alguien tipeó 4,17): a 4 decimales quedan en buckets
  // distintos, que es lo correcto. Si la factura declara uno solo, el otro no se
  // ajusta y el cuadre avisa. En SQL, round(tasa, 4) en las dos puntas.
  const tasaII = (t: number) => redondearSQL(t || 0, 4)

  // Misma regla que prorratearCargo: el 0 es un estado válido (una línea recién
  // agregada), el negativo y el NaN son corrupción. Sin esto la línea devolvía 0
  // en cada unitario mientras el total sumaba el neto igual, y el dato corrupto
  // pasaba de largo.
  for (const l of lineas) {
    if (!Number.isFinite(l.cantidad) || l.cantidad < 0) {
      throw new Error(
        `calcularCostosCompra: cantidad invalida en la linea ${l.id} (${l.cantidad}). ` +
        'Se espera un numero finito no negativo.'
      )
    }
  }

  // LAS CUATRO GUARDAS QUE SIGUEN LAS TENÍA LA MIG 193 Y ESTE ARCHIVO NO. Eran
  // el único lugar donde las dos implementaciones no fallaban ante lo mismo, y
  // las encontró el espejo (`scripts/espejo-motor-compras.mjs`) la primera vez
  // que se lo pudo correr contra la base: en los cuatro casos el SQL rechazaba
  // la entrada y acá salía un número. Eso es peor que un número distinto — la
  // vista previa muestra un costo que la base no va a aceptar, o que va a
  // aceptar contando plata dos veces— y por eso la 193 dejó anotado que el
  // espejo tenía que copiarlas. Orden y mensajes calcados de esa migración.

  // Dos líneas con el mismo id hacen que el reparto de un cargo se cuente una
  // vez por cada una: `repartos` es un mapa por id y las dos leen la misma
  // entrada. Desde compra_items es imposible (id es PK), desde un payload no.
  const vistos = new Set<number>()
  for (const l of lineas) {
    if (vistos.has(l.id)) {
      throw new Error(`calcularCostosCompra: la linea ${l.id} aparece mas de una vez.`)
    }
    vistos.add(l.id)
  }

  // Un typo en la condición NO es inocuo: `esGravada` y los dos CASE de exento y
  // no_gravado son excluyentes, así que un valor que no es ninguno de los tres
  // cae en el hueco y el neto de esa línea desaparece de los CUATRO totales a la
  // vez, sin un solo error. El tipo lo frena en tiempo de compilación; esto lo
  // frena cuando el dato viene de la red, que es de donde viene.
  for (const l of lineas) {
    if (!CONDICIONES_IVA.includes(l.condicionIva)) {
      throw new Error(
        `calcularCostosCompra: condicionIva invalida en la linea ${l.id} (${l.condicionIva}). ` +
        'Se espera gravado, exento o no_gravado.'
      )
    }
  }

  // Del lado del cargo el hueco es distinto pero igual de mudo: `gravado(c)` sale
  // de comparar contra 'gravado', así que cualquier typo cae en la rama NO
  // gravada y el cargo deja de sumar a la base de IVA sin avisar. Se lo nombra
  // por posición y concepto porque el cargo puede no tener id todavía (viene de
  // una grilla a medio llenar).
  cargos.forEach((c, i) => {
    if (!CONDICIONES_IVA.includes(c.condicionIva)) {
      throw new Error(
        `calcularCostosCompra: condicionIva invalida en el cargo ${i + 1} ` +
        `(${c.concepto || 'sin concepto'}): ${c.condicionIva}. ` +
        'Se espera gravado, exento o no_gravado.'
      )
    }
  })

  // Dos tasas declaradas que colapsan al MISMO bucket de 4 decimales ('10' y
  // '10.0', o '4.1667' y '04.1667'): acá la segunda pisaba a la primera en
  // `factorAjuste` sin avisar, y en SQL el subselect del factor devolvía dos
  // filas y reventaba. Los dos casos son el mismo dato mal cargado.
  const bucketsDeclarados = new Map<number, string>()
  for (const clave of Object.keys(iiDeclarado)) {
    const bucket = tasaII(Number(clave))
    const previa = bucketsDeclarados.get(bucket)
    if (previa !== undefined) {
      throw new Error(
        `calcularCostosCompra: las tasas declaradas "${previa}" y "${clave}" ` +
        'caen en el mismo bucket de 4 decimales y se pisarian.'
      )
    }
    bucketsDeclarados.set(bucket, clave)
  }

  const repartos = new Map<number, Record<number, number>>()
  for (const c of cargos) repartos.set(c.id, prorratearCargo(c.monto, c.pesos))
  const asignado = (c: CargoCompra, lineaId: number) => repartos.get(c.id)?.[lineaId] ?? 0

  const neto = (l: LineaCompra) => l.cantidad * l.costoUnitario * (1 - (l.bonificacion || 0) / 100)
  const suma = (l: LineaCompra, filtro: (c: CargoCompra) => boolean) =>
    cargos.filter(filtro).reduce((acc, c) => acc + asignado(c, l.id), 0)

  const gravado = (c: CargoCompra) => c.condicionIva === 'gravado'

  const bases = lineas.map(l => {
    const esGravada = l.condicionIva === 'gravado'
    const cargosGravadosFactura = suma(l, c => gravado(c) && c.enFactura)
    return {
      linea: l,
      neto: neto(l),
      esGravada,
      cargosGravadosFactura,
      baseIva: esGravada ? neto(l) + cargosGravadosFactura : 0,
      baseCosto: neto(l) + suma(l, c => gravado(c) && c.prorrateaAlCosto),
      baseII: neto(l) + suma(l, c => gravado(c) && c.afectaBaseII),
      noGravadoFactura: suma(l, c => !gravado(c) && c.enFactura),
      cargosAlCosto: suma(l, c => !gravado(c) && c.prorrateaAlCosto),
    }
  })

  // Factor de ajuste por alícuota de II, con la tasa normalizada en las dos
  // puntas: se agrupa por clave exacta y se busca por clave exacta.
  const factorAjuste: Record<number, number> = {}
  for (const [tasaStr, declarado] of Object.entries(iiDeclarado)) {
    const tasa = tasaII(Number(tasaStr))
    const calculado = bases
      .filter(b => tasaII(b.linea.impuestosInternos) === tasa)
      .reduce((acc, b) => acc + b.baseII * tasa / 100, 0)
    factorAjuste[tasa] = calculado ? declarado / calculado : 1
  }

  const calculadas = bases.map(b => ({
    ...b,
    ii: b.baseII * (b.linea.impuestosInternos || 0) / 100
      * (factorAjuste[tasaII(b.linea.impuestosInternos)] ?? 1),
    iva: b.baseIva * b.linea.porcentajeIva / 100,
  }))

  const total = (f: (c: typeof calculadas[number]) => number) =>
    calculadas.reduce((a, c) => a + f(c), 0)

  return {
    // Los unitarios se derivan del total de la línea, nunca al revés: el total no
    // se reconstruye multiplicando de vuelta por la cantidad.
    lineas: calculadas.map(b => {
      const cant = b.linea.cantidad
      const porUnidad = (v: number) => (cant > 0 ? v / cant : 0)
      return {
        id: b.linea.id,
        baseIvaUnitaria: porUnidad(b.baseIva),
        iiUnitario: porUnidad(b.ii),
        cargosUnitarios: porUnidad(b.cargosAlCosto),
        ivaUnitario: porUnidad(b.iva),
        costoNetoUnitario: porUnidad(b.neto),
        costoRealUnitario: porUnidad(b.baseCosto + b.ii + b.cargosAlCosto),
      }
    }),
    totales: {
      netoGravado: total(b => (b.esGravada ? b.neto : 0) + b.cargosGravadosFactura),
      netoExento: total(b => (b.linea.condicionIva === 'exento' ? b.neto : 0)),
      netoNoGravado: total(b => (b.linea.condicionIva === 'no_gravado' ? b.neto : 0)),
      iva: total(b => b.iva),
      impuestosInternos: total(b => b.ii),
      noGravado: total(b => b.noGravadoFactura),
      cargosAlCosto: total(b => b.cargosAlCosto),
    },
    factorAjuste,
  }
}

// =============================================================================
// EL SOLVER DE BASES DE IMPUESTO INTERNO
// =============================================================================

/**
 * Piso absoluto de la tolerancia del cuadre de impuesto interno, en pesos.
 *
 * Es el mismo peso que ya usan `COMPRA-A1`, el control blando de cuadre de la
 * RPC y el ✓ del panel "Control contra factura": abajo de un peso ninguna parte
 * de este sistema afirma nada. Existe porque la parte relativa sola quedaría
 * absurdamente dura en una factura chica —al 0,05%, un II declarado de 500 pesos
 * toleraría 25 centavos, y el proveedor redondea cada renglón a 2 decimales—.
 */
export const TOLERANCIA_II_PISO = 1

/**
 * Parte relativa de la tolerancia: 0,5 por mil del II declarado de la alícuota.
 *
 * Medido contra la factura testigo A0005-00461415, que es el único caso real con
 * la respuesta conocida:
 *
 *   alícuota │ declarado  │ tolerancia │ residuo de la      │ residuo de la más
 *            │            │            │ hipótesis correcta │ cercana que NO
 *   ─────────┼────────────┼────────────┼────────────────────┼──────────────────
 *    8,6956% │ 338.884,46 │     169,44 │               0,06 │       7.022,93
 *    4,1667% │ 199.027,21 │      99,51 │               0,01 │         795,39
 *
 * O sea: la correcta entra con 2.800 veces de margen y la siguiente queda afuera
 * por 8 veces. Es el ancho que separa "el proveedor redondeó" de "esa
 * bonificación no es la que baja la base", y deja lugar para que la próxima
 * factura sea bastante peor que ésta sin que se rompa nada.
 *
 * POR QUÉ RELATIVA Y NO UN NÚMERO FIJO. Lo que hay que tolerar es el redondeo del
 * proveedor, que crece con la factura: centavos por renglón, más lo que se corra
 * el reparto de la bonificación entre alícuotas respecto del que hizo él. Un
 * absoluto calibrado con esta factura de 13 millones (169 pesos) aceptaría
 * cualquier cosa en una de 200.000; uno calibrado con la chica rechazaría la
 * hipótesis correcta en la grande.
 *
 * Si alguna vez hay que aflojarla, que sea con otra factura testigo en la mano y
 * moviendo también el test que mide la separación: subirla hasta pasar los 795
 * pesos del 4,1667% convierte al solver en un generador de respuestas plausibles.
 */
export const TOLERANCIA_II_RELATIVA = 0.0005

/**
 * Tope de cargos candidatos. 2^10 = 1024 hipótesis.
 *
 * El costo de la fuerza bruta no es el problema —mil corridas del motor sobre 21
 * líneas es nada—; el problema es que cada variable binaria que se agrega duplica
 * las chances de que alguna combinación cierre por casualidad contra las dos o
 * tres ecuaciones que da una factura. Con diez bonificaciones gravadas y dos
 * alícuotas, la respuesta honesta ya no es "la encontré".
 */
export const MAX_CARGOS_BASE_II = 10

/** Lo que se le tolera al cuadre de una alícuota, en pesos. */
export function toleranciaII(declarado: number): number {
  return Math.max(TOLERANCIA_II_PISO, Math.abs(declarado) * TOLERANCIA_II_RELATIVA)
}

/** Una hipótesis que cierra contra el impuesto interno declarado. */
export interface HipotesisBasesII {
  /** cargoId → afectaBaseII. Sólo nombra a los candidatos. */
  asignacion: Record<number, boolean>
  /** tasa → declarado − calculado (misma orientación que `CuadreII.desvio`). */
  residuos: Record<number, number>
  /**
   * El peor residuo medido en tolerancias: 0 es exacto, 1 es el borde. Ordena
   * las hipótesis y deja ver si una solución cerró holgada o raspando.
   */
  holgura: number
}

export type EstadoBasesII =
  /** Exactamente una combinación cierra. Es la respuesta. */
  | 'unica'
  /** Más de una cierra: la factura no alcanza para distinguirlas. */
  | 'ambigua'
  /** Ninguna cierra: o el declarado está mal, o falta un cargo, o una alícuota. */
  | 'sin_solucion'
  /** No hay ninguna ecuación que resolver (no se declaró el II, o es ZZ). */
  | 'sin_datos'
  /** Demasiados candidatos: ver `MAX_CARGOS_BASE_II`. */
  | 'demasiadas_hipotesis'

export interface ResultadoBasesII {
  estado: EstadoBasesII
  /** Las hipótesis que cierran, de la más ajustada a la menos. */
  soluciones: HipotesisBasesII[]
  /** Ids de los cargos que entraron a la búsqueda. */
  candidatos: number[]
  /** Ids de los cargos gravados cuyo efecto no se puede medir. Ver abajo. */
  indeterminables: number[]
  /** Las alícuotas que se usaron como ecuación. */
  alicuotas: number[]
}

/**
 * Deduce qué bonificaciones bajan la base del impuesto interno.
 *
 * EL PROBLEMA QUE RESUELVE. `afectaBaseII` distingue un descuento de precio (baja
 * la base imponible) de una bonificación comercial (no la baja), y esa distinción
 * vale casi el 5% del impuesto interno de la factura testigo. Pero no hay ninguna
 * regla que el que carga la factura pueda aplicar mirándola: lo decide el
 * proveedor, y la testigo demuestra que Manaos trató las dos bonificaciones del
 * MISMO comprobante de forma distinta. Un casillero que el usuario no puede
 * llenar no sirve de nada.
 *
 * LO QUE SÍ HAY es que la factura declara el impuesto interno abierto POR
 * ALÍCUOTA. Eso es una ecuación por alícuota. Con N bonificaciones gravadas hay
 * 2^N hipótesis: se prueban todas y se busca cuál cierra. En la testigo, con las
 * dos bonificaciones reales, cierra una sola —la misma que el golden ya tenía
 * como correcta—; las otras tres se van por entre 795 y 16.020 pesos.
 *
 * QUÉ ES CANDIDATO. Sólo un cargo GRAVADO: el motor lee la base como
 * `gravado(c) && c.afectaBaseII`, así que prender el flag en un cargo no gravado
 * no mueve nada y sólo agregaría una variable libre que duplica las hipótesis sin
 * explicar ninguna diferencia.
 *
 * QUÉ ES INDETERMINABLE. Un cargo cuyo efecto sobre TODAS las alícuotas
 * declaradas es más chico que la tolerancia: la factura no trae con qué
 * decidirlo. El caso extremo es el cargo que no toca ninguna línea con impuesto
 * interno —efecto exactamente 0—, pero también cae acá el redondeo de −0,49 de la
 * testigo, que mueve el II 1,6 centavos. Si entraran a la búsqueda, TODA solución
 * vendría duplicada por su gemela con el flag al revés y el resultado sería
 * "ambigua" para siempre. Se los deja afuera con el valor que traen y se los
 * devuelve por separado, para que la interfaz no los marque como resueltos:
 * sobre ellos el solver no tiene nada que decir. Se podan de a uno y se verifica
 * que el CONJUNTO podado también sea despreciable, porque diez efectos
 * individualmente chicos pueden sumar uno grande.
 *
 * LOS TRES RESULTADOS SON DISTINTOS Y SE DEVUELVEN DISTINTOS. Una sola hipótesis
 * que cierra es una respuesta; varias es una ambigüedad; ninguna es un dato mal
 * cargado. Devolver "la mejor" en los dos últimos casos sería inventar una
 * respuesta que la factura no da, que es exactamente el defecto del ajuste
 * proporcional que este solver viene a reemplazar.
 *
 * Función pura: quien la llama decide si aplica el resultado. Y no atrapa lo que
 * lance el motor —un peso corrupto sigue siendo corrupción—, con el mismo
 * criterio que `prorratearCargo`.
 *
 * @param iiDeclarado - tasa de II → monto declarado en la factura.
 */
export function resolverBasesII(
  lineas: LineaCompra[],
  cargos: CargoCompra[],
  iiDeclarado: Record<number, number>
): ResultadoBasesII {
  const tasaII = (t: number) => redondearSQL(t || 0, 4)

  // Las ecuaciones son las alícuotas declaradas QUE ADEMÁS EXISTEN en las líneas.
  // Una declarada que ninguna línea tiene no es una ecuación: daría 0 calculado y
  // el solver estaría demostrando algo sobre una alícuota que no participa. Que
  // la factura declare una alícuota ausente de las líneas es un error de carga, y
  // el panel de cuadre ya lo muestra.
  const conLinea = new Set(
    lineas
      .filter(l => l.cantidad > 0 && tasaII(l.impuestosInternos) > 0)
      .map(l => tasaII(l.impuestosInternos))
  )
  const declarado = new Map<number, number>()
  for (const [clave, monto] of Object.entries(iiDeclarado)) {
    const tasa = tasaII(Number(clave))
    if (conLinea.has(tasa)) declarado.set(tasa, monto)
  }
  const alicuotas = [...declarado.keys()].sort((a, b) => a - b)

  const sinSoluciones = (
    estado: EstadoBasesII,
    candidatos: number[] = [],
    indeterminables: number[] = []
  ): ResultadoBasesII => ({ estado, soluciones: [], candidatos, indeterminables, alicuotas })

  if (alicuotas.length === 0) return sinSoluciones('sin_datos')

  const tolerancia = (tasa: number) => toleranciaII(declarado.get(tasa) ?? 0)
  const despreciable = (efecto: Record<number, number>) =>
    alicuotas.every(t => Math.abs(efecto[t]) < tolerancia(t))

  /**
   * El impuesto interno por alícuota bajo una hipótesis. Los cargos que la
   * hipótesis no nombra conservan el `afectaBaseII` con el que llegaron.
   *
   * La apertura declarada va VACÍA a propósito: el factor de ajuste residual del
   * motor fuerza el calculado contra el declarado, así que con la apertura puesta
   * toda hipótesis daría residuo 0 y no habría nada que resolver. Es el mismo
   * motivo por el que `cuadreImpuestoInterno` la deja vacía.
   */
  const iiPorTasa = (asignacion: Record<number, boolean>): Record<number, number> => {
    const hipotesis = cargos.map(c =>
      asignacion[c.id] === undefined ? c : { ...c, afectaBaseII: asignacion[c.id] }
    )
    const costos = calcularCostosCompra(lineas, hipotesis, {})
    const total: Record<number, number> = {}
    for (const t of alicuotas) total[t] = 0
    // Por ÍNDICE y no por id: es el orden que el motor conserva, y así esto no
    // depende de que los ids de línea sean únicos. Reconstruir el total como
    // unitario × cantidad es lo que ya hace `cuadreImpuestoInterno`, así que el
    // solver y el panel de cuadre no pueden discrepar. (Una línea de cantidad 0
    // aporta 0 por las dos vías; las RPCs rechazan darle peso a una.)
    lineas.forEach((linea, i) => {
      const tasa = tasaII(linea.impuestosInternos)
      if (total[tasa] === undefined) return
      total[tasa] += (costos.lineas[i]?.iiUnitario ?? 0) * linea.cantidad
    })
    return total
  }

  const gravados = cargos.filter(c => c.condicionIva === 'gravado')
  const apagados: Record<number, boolean> = {}
  for (const c of gravados) apagados[c.id] = false

  // Efecto de cada cargo, medido contra el piso "ninguno baja la base".
  const base = iiPorTasa(apagados)
  const efecto = new Map<number, Record<number, number>>()
  for (const c of gravados) {
    const conEste = iiPorTasa({ ...apagados, [c.id]: true })
    efecto.set(c.id, Object.fromEntries(alicuotas.map(t => [t, conEste[t] - base[t]])))
  }

  const mudos = gravados.filter(c => despreciable(efecto.get(c.id)!))
  const sumaMudos = Object.fromEntries(
    alicuotas.map(t => [t, mudos.reduce((acc, c) => acc + efecto.get(c.id)![t], 0)])
  )
  const indeterminables = despreciable(sumaMudos) ? mudos.map(c => c.id) : []
  const candidatos = gravados.map(c => c.id).filter(id => !indeterminables.includes(id))

  if (candidatos.length > MAX_CARGOS_BASE_II) {
    return sinSoluciones('demasiadas_hipotesis', candidatos, indeterminables)
  }

  const soluciones: HipotesisBasesII[] = []
  for (let mascara = 0; mascara < (1 << candidatos.length); mascara++) {
    const asignacion: Record<number, boolean> = {}
    candidatos.forEach((id, i) => { asignacion[id] = ((mascara >> i) & 1) === 1 })
    const ii = iiPorTasa(asignacion)
    const residuos: Record<number, number> = {}
    let holgura = 0
    for (const tasa of alicuotas) {
      residuos[tasa] = (declarado.get(tasa) ?? 0) - ii[tasa]
      holgura = Math.max(holgura, Math.abs(residuos[tasa]) / tolerancia(tasa))
    }
    if (holgura <= 1) soluciones.push({ asignacion, residuos, holgura })
  }
  soluciones.sort((a, b) => a.holgura - b.holgura)

  return {
    estado:
      soluciones.length === 1 ? 'unica'
        : soluciones.length > 1 ? 'ambigua'
          : 'sin_solucion',
    soluciones,
    candidatos,
    indeterminables,
    alicuotas,
  }
}

// =============================================================================
// EL DESGLOSE FISCAL DE LA CABECERA
// =============================================================================

/**
 * Una línea del formulario tal como la ve el motor, con la regla de ZZ aplicada
 * — el mismo CASE que arma `v_items_motor` en la mig 194.
 *
 * La regla: `tipo_factura` decide si se agregan IMPUESTOS encima, no si se
 * ignoran COSTOS. En ZZ lo pagado ya incluye IVA e impuestos internos, pero un
 * flete que factura un transportista aparte no está adentro de ese precio, así
 * que el cargo tiene que sumar igual. Se implementa poniendo la tasa en 0 acá y
 * no con un IF adentro del motor: con la tasa en 0, `ii = baseII × tasa ×
 * factor` da 0 cualquiera sea la base, mientras el cargo viaja por `baseCosto`
 * (si es gravado) o por `cargosAlCosto` (si no), y ninguno de los dos mira la
 * tasa.
 *
 * Vive acá y no en el modal porque ahora tiene DOS llamadores —la vista previa
 * de costos y el desglose de la cabecera— y dos copias del CASE se
 * desincronizan sin que nada avise. Si cambia el de la 194, cambia éste.
 */
export function lineaParaMotor(
  item: CompraItemCalculo,
  tipoFactura: 'ZZ' | 'FC',
  id: number
): LineaCompra {
  const esZZ = tipoFactura === 'ZZ'
  const condicionIva: CondicionIva = esZZ ? 'gravado' : (item.condicionIva ?? 'gravado')
  return {
    id,
    cantidad: item.cantidad || 0,
    costoUnitario: item.costoUnitario || 0,
    bonificacion: item.bonificacion || 0,
    impuestosInternos: esZZ ? 0 : (item.impuestosInternos || 0),
    porcentajeIva: esZZ || condicionIva !== 'gravado' ? 0 : (item.porcentajeIva ?? 21),
    condicionIva,
  }
}

export interface CompraItemCalculo {
  cantidad: number;
  costoUnitario: number;
  bonificacion?: number;
  porcentajeIva?: number;
  /** Tasa efectiva de imp. internos (%) */
  impuestosInternos?: number;
  /** Default: 'gravado' (así se comporta una línea que no lo trae). */
  condicionIva?: CondicionIva;
  /**
   * Id local de la línea. Sólo importa cuando hay cargos: los `pesos` de un
   * cargo se guardan contra este id, así que el motor tiene que ver la línea
   * con el MISMO id o el reparto no matchea nada. Sin cargos da igual y por eso
   * es opcional (cae al índice).
   */
  lineaId?: number;
}

export interface CompraExtras {
  percepcionIva?: number;
  percepcionIibb?: number;
  noGravado?: number;
  otrosImpuestos?: number;
}

export interface TotalesCompra {
  subtotalBruto: number;
  bonificacionTotal: number;
  /**
   * Neto de TODAS las líneas (bruto − bonif) = netoGravado + netoExento +
   * netoNoGravado CUANDO NO HAY CARGOS. Es lo que se manda como p_subtotal y lo
   * que valida el check COMPRA-A2 contra SUM(compra_items.subtotal): no
   * estrecharlo a "sólo gravado" ni meterle los cargos, o toda factura mixta —o
   * con flete— quedaría en rojo.
   */
  subtotal: number;
  /** Líneas gravadas + cargos gravados en factura. Cuadra contra el papel. */
  netoGravado: number;
  netoExento: number;
  /** Líneas de producto no gravadas. NO es `noGravado` (cabecera, sin línea). */
  netoNoGravado: number;
  /**
   * Σ de los cargos GRAVADOS que vienen en la factura, CON SU SIGNO: negativo
   * cuando son bonificaciones, que es el caso normal y el único que se ve hoy.
   *
   * Es la pieza que le faltaba a la cabecera para cuadrar contra el papel. El
   * `subtotal` es el neto de las LÍNEAS y lo clava `COMPRA-A2` contra
   * SUM(compra_items.subtotal), así que una bonificación general —que no es un
   * renglón de producto— no tenía dónde restarse: en la factura testigo dejaba
   * `compras.total` 306.784,09 arriba de lo que dice el papel. Va a la columna
   * `compras.bonificaciones` (mig 195) y entra a la identidad de `COMPRA-A1`.
   *
   * Se suman los MONTOS y no el prorrateo, igual que el "no gravado" de
   * cabecera y por la misma razón: la cabecera cuadra contra el papel, no contra
   * el reparto. Un cargo impreso en la factura está impreso aunque no se le haya
   * asignado ninguna línea.
   *
   * En ZZ es 0, como el IVA y las percepciones: sin comprobante no hay cuadre
   * contra el papel y `total = subtotal`.
   */
  bonificaciones: number;
  /** Neto gravado abierto por alícuota: { '21': 10000, '10.5': 5000 } */
  netoPorAlicuota: Record<string, number>;
  iva: number;
  impuestosInternos: number;
  percepcionIva: number;
  percepcionIibb: number;
  /** Conceptos de cabecera fuera del IVA (pallets, envases): sin línea de producto. */
  noGravado: number;
  otrosImpuestos: number;
  total: number;
}

/**
 * Totales de una compra según tipo de comprobante (fuente única del modal de
 * compras; estructura = factura A real: total = neto de líneas + bonificaciones
 * generales + IVA + II + percepciones + no gravado de cabecera + otros).
 *
 * POR QUÉ EL NETO GRAVADO, EL IVA Y EL IMPUESTO INTERNO SALEN DEL MOTOR Y NO DE
 * UN LOOP PROPIO. Antes de los cargos, una bonificación se cargaba como línea
 * negativa o no se cargaba, y `Σ neto × tasa` daba bien. Desde que existen los
 * cargos, la bonificación es un cargo gravado: baja la base del IVA siempre y
 * la del impuesto interno cuando es descuento de precio y no bonificación
 * comercial. Un loop que sólo mira las líneas no las ve, y en la factura
 * testigo dejaba el impuesto interno 8.996,90 arriba y el IVA 64.424,66 arriba
 * —números que van a `compras.impuestos_internos` y `compras.iva`, o sea a la
 * posición fiscal—. El motor ya arma las tres bases bien y es el espejo exacto
 * de la mig 193, así que el cuadre contra la base cierra por construcción y no
 * por coincidencia.
 *
 * NO HAY RAMA "si hay cargos". Con `cargos: []` el motor da `baseIva = neto` y
 * `baseII = neto` y factor 1, o sea exactamente la aritmética de antes: una
 * compra sin cargos sigue dando los mismos totales sin que nadie tenga que
 * mantener dos brazos de acuerdo. Es la única forma de que no queden dos
 * fuentes para el mismo número, que es como llegamos acá.
 *
 * LO QUE NO SALE DEL MOTOR es lo que el motor no conoce y las líneas sí: el
 * bruto, la bonificación de línea, el `subtotal` (que COMPRA-A2 clava contra
 * SUM(compra_items.subtotal)) y la apertura por alícuota. Un cargo gravado no
 * tiene alícuota propia —tributa a la de las líneas sobre las que cae— así que
 * no abre un bucket nuevo en `netoPorAlicuota`.
 *
 * ZZ (sin factura): lo pagado es todo — sin IVA, sin II, sin percepciones ni no
 * gravado. `total = subtotal`. La regla la aplica `lineaParaMotor` en el borde.
 *
 * @param cargos - los cargos de la factura. Sus `pesos` van por `lineaId`.
 * @param iiDeclarado - tasa de II → monto declarado. En ZZ se descarta.
 */
export function calcularTotalesCompra(
  items: CompraItemCalculo[],
  tipoFactura: 'ZZ' | 'FC' = 'FC',
  extras: CompraExtras = {},
  cargos: CargoCompra[] = [],
  iiDeclarado: Record<number, number> = {}
): TotalesCompra {
  const esFC = tipoFactura === 'FC';
  let subtotalBruto = 0;
  let bonificacionTotal = 0;
  const netoPorAlicuota: Record<string, number> = {};

  for (const item of items) {
    const bruto = (item.cantidad || 0) * (item.costoUnitario || 0);
    const bonif = bruto * (item.bonificacion || 0) / 100;
    subtotalBruto += bruto;
    bonificacionTotal += bonif;
    // En ZZ no hay comprobante que abrir por alícuota.
    if (esFC && (item.condicionIva ?? 'gravado') === 'gravado') {
      const alicuota = String(item.porcentajeIva ?? 21);
      netoPorAlicuota[alicuota] = (netoPorAlicuota[alicuota] || 0) + (bruto - bonif);
    }
  }

  // Los ids con los que las líneas entran al motor. El `item.lineaId ?? i` de
  // antes PODÍA COLISIONAR —un item con lineaId 1 y otro sin lineaId parado en
  // la posición 1 daban el mismo id— y una colisión hacía que los dos leyeran el
  // mismo reparto, o sea que un cargo se contara dos veces. Ahora el motor
  // rechaza los ids repetidos, así que además sería una excepción.
  // Se numeran los que faltan POR ENCIMA del máximo existente, igual que
  // `asegurarLineaIds` en el reducer del modal: los que sí tienen id conservan
  // el suyo y los `pesos` de los cargos siguen matcheando.
  let proximoId = items.reduce((max, it) => Math.max(max, it.lineaId ?? 0), 0) + 1
  const idsMotor = items.map(it => it.lineaId ?? proximoId++)

  const costos = calcularCostosCompra(
    items.map((item, i) => lineaParaMotor(item, tipoFactura, idsMotor[i])),
    cargos,
    // Mismo filtro que la RPC: en ZZ la apertura declarada no ajusta nada.
    esFC ? iiDeclarado : {}
  );
  const { netoGravado, netoExento, netoNoGravado, iva, impuestosInternos } = costos.totales;

  const subtotal = subtotalBruto - bonificacionTotal;
  const bonificaciones = esFC
    ? redondearSQL(
        cargos
          .filter(c => c.condicionIva === 'gravado' && c.enFactura)
          .reduce((acc, c) => acc + (c.monto || 0), 0),
        2
      )
    : 0;
  const percepcionIva = esFC ? (extras.percepcionIva || 0) : 0;
  const percepcionIibb = esFC ? (extras.percepcionIibb || 0) : 0;
  const noGravado = esFC ? (extras.noGravado || 0) : 0;
  const otrosImpuestos = esFC ? (extras.otrosImpuestos || 0) : 0;
  const total = subtotal + bonificaciones + iva + impuestosInternos
    + percepcionIva + percepcionIibb + noGravado + otrosImpuestos;

  return {
    subtotalBruto, bonificacionTotal, subtotal, bonificaciones,
    netoGravado, netoExento, netoNoGravado, netoPorAlicuota,
    iva, impuestosInternos,
    percepcionIva, percepcionIibb, noGravado, otrosImpuestos, total,
  };
}
