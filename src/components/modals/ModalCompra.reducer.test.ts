/**
 * Vector de pesos de los cargos de compra, a nivel reducer.
 *
 * Se testea el reducer y no el DOM porque lo que puede corromper un costo en
 * silencio vive acá: qué peso se pre-llena, cuál se pisa y cuál no, y qué pasa
 * con el vector cuando cambian las líneas. Un peso que queda pegado al producto
 * equivocado no rompe ninguna pantalla; sólo reparte mal el flete.
 */
import { describe, it, expect } from 'vitest'
import {
  compraReducer, initialState, lineasParaMotor, cargosParaMotor,
  cuadreImpuestoInterno, DESVIO_II_TOLERADO, cargosPlantillaNuevos,
  cargosParaRPC, validarCargos, resolucionBasesII,
} from './ModalCompra.reducer'
import type { CompraState } from './ModalCompra.reducer'
import type { CargoPlantillaCompra } from '../../types'
import { prorratearCargo, calcularCostosCompra } from '../../utils/prorrateoCompra'
import type { ProductoDB } from '../../types'

type Accion = Parameters<typeof compraReducer>[1]

const producto = (id: string, costo: number): ProductoDB => ({
  id,
  nombre: `Producto ${id}`,
  codigo: id,
  costo_sin_iva: costo,
  impuestos_internos: 0,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
  stock: 10,
} as unknown as ProductoDB)

const correr = (acciones: Accion[], desde: CompraState = initialState): CompraState =>
  acciones.reduce(compraReducer, desde)

/** Estado con dos líneas (neto 100 y 300) y un cargo recién agregado. */
const conDosLineasYUnCargo = () => correr([
  { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
  { type: 'AGREGAR_ITEM', payload: producto('b', 300) },
  { type: 'AGREGAR_CARGO' },
])

describe('cargos: pre-llenado del vector de pesos', () => {
  it('numera las lineas y pre-llena por monto al agregar el cargo', () => {
    const s = conDosLineasYUnCargo()
    expect(s.items.map(i => i.lineaId)).toEqual([1, 2])
    expect(s.cargos[0].baseProrrateo).toBe('monto')
    expect(s.cargos[0].pesos).toEqual({ 1: 100, 2: 300 })
  })

  it('pre-llena por cantidad y en partes iguales', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('b', 300) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 1, campo: 'cantidad', valor: 5 } },
      { type: 'AGREGAR_CARGO' },
    ])
    const id = base.cargos[0].id

    const porCantidad = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { baseProrrateo: 'cantidad' } } },
    ], base)
    expect(porCantidad.cargos[0].pesos).toEqual({ 1: 1, 2: 5 })

    const partesIguales = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { baseProrrateo: 'unidades' } } },
    ], base)
    expect(partesIguales.cargos[0].pesos).toEqual({ 1: 1, 2: 1 })
  })

  it('no arrastra la cola binaria del neto al campo de peso', () => {
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 158823.76) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'bonificacion', valor: 0.6 } },
      { type: 'AGREGAR_CARGO' },
    ])
    // 158823,76 × 0,994 = 157870,81744 → 4 decimales, la precision de
    // compra_cargo_repartos.peso. Sin redondear, el campo mostraria la cola entera.
    expect(String(s.cargos[0].pesos[1])).toBe('157870.8174')
  })
})

describe('cargos: el vector sigue a las lineas', () => {
  it('respeta el peso tipeado a mano al agregar, editar y quitar lineas', () => {
    const base = conDosLineasYUnCargo()
    const id = base.cargos[0].id

    // Peso 0 = excluir la linea. Es el caso que NO se puede pisar.
    let s = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { monto: 400 } } },
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 2, peso: 0 } },
    ], base)
    expect(prorratearCargo(s.cargos[0].monto, s.cargos[0].pesos)).toEqual({ 1: 400, 2: 0 })

    s = correr([{ type: 'AGREGAR_ITEM', payload: producto('c', 50) }], s)
    expect(s.cargos[0].pesos).toEqual({ 1: 100, 2: 0, 3: 50 })

    // Cambiar un costo re-calcula lo automatico y deja quieto lo manual: si no,
    // el flete se repartiria con los numeros de antes sin avisar.
    s = correr([{ type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'costoUnitario', valor: 200 } }], s)
    expect(s.cargos[0].pesos).toEqual({ 1: 200, 2: 0, 3: 50 })

    // Al borrar una linea su peso sale del vector; si quedara, prorratearCargo
    // le asignaria plata y la grilla dejaria de sumar el monto del cargo.
    s = correr([{ type: 'ELIMINAR_ITEM', payload: 1 }], s)
    expect(s.cargos[0].pesos).toEqual({ 1: 200, 3: 50 })
    expect(Object.values(prorratearCargo(400, s.cargos[0].pesos)).reduce((a, v) => a + v, 0)).toBe(400)
  })

  it('re-elegir la base es la salida: borra las marcas de manual', () => {
    const base = conDosLineasYUnCargo()
    const id = base.cargos[0].id
    const s = correr([
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 1, peso: 999 } },
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { baseProrrateo: 'unidades' } } },
    ], base)
    expect(s.cargos[0].pesos).toEqual({ 1: 1, 2: 1 })
  })

  it('quitar un cargo no toca a los demas', () => {
    const base = correr([{ type: 'AGREGAR_CARGO' }], conDosLineasYUnCargo())
    const [primero, segundo] = base.cargos
    const s = correr([{ type: 'ELIMINAR_CARGO', payload: primero.id }], base)
    expect(s.cargos.map(c => c.id)).toEqual([segundo.id])
    expect(s.cargos[0].pesos).toEqual({ 1: 100, 2: 300 })
  })
})

describe('cargos: plantilla del proveedor', () => {
  const plantilla = (over: Partial<CargoPlantillaCompra> = {}): CargoPlantillaCompra => ({
    concepto: 'Flete y descarga',
    condicionIva: 'no_gravado',
    enFactura: true,
    prorrateaAlCosto: true,
    afectaBaseII: false,
    baseProrrateo: 'monto',
    pesosPorProducto: { a: 40, b: 60 },
    ...over,
  })

  it('remapea los pesos por producto y deja el monto en 0', () => {
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('b', 300) },
      { type: 'APLICAR_CARGOS_PLANTILLA', payload: [plantilla()] },
    ])
    expect(s.cargos).toHaveLength(1)
    expect(s.cargos[0].concepto).toBe('Flete y descarga')
    expect(s.cargos[0].monto).toBe(0)
    expect(s.cargos[0].pesos).toEqual({ 1: 40, 2: 60 })
  })

  it('la linea que no matchea ningun producto de la plantilla queda en 0', () => {
    // Y en 0 se QUEDA: si el pre-llenado por monto la pisara, el separador del
    // bidon terminaria repartido sobre toda la factura.
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('z', 900) },
      { type: 'APLICAR_CARGOS_PLANTILLA', payload: [plantilla({ pesosPorProducto: { a: 7 } })] },
    ])
    expect(s.cargos[0].pesos).toEqual({ 1: 7, 2: 0 })
  })

  it('el peso traido sobrevive a editar la linea, y re-elegir la base lo suelta', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'APLICAR_CARGOS_PLANTILLA', payload: [plantilla({ pesosPorProducto: { a: 7 } })] },
    ])
    const id = base.cargos[0].id

    // Cambiar la cantidad NO recalcula el peso traido: entra al vector con la
    // misma marca de manual que un peso tipeado a mano.
    const editada = correr([
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 9 } },
    ], base)
    expect(editada.cargos[0].pesos).toEqual({ 1: 7 })

    // Una linea AGREGADA despues de traer la plantilla si entra por la base, y
    // es la misma regla que con los pesos manuales: la plantilla no puede opinar
    // sobre una linea que no existia cuando se la trajo. El orden natural es
    // cargar los renglones y despues traer los cargos.
    const conLineaNueva = correr([{ type: 'AGREGAR_ITEM', payload: producto('b', 300) }], editada)
    expect(conLineaNueva.cargos[0].pesos).toEqual({ 1: 7, 2: 300 })

    const resoltada = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { baseProrrateo: 'monto' } } },
    ], conLineaNueva)
    expect(resoltada.cargos[0].pesos).toEqual({ 1: 900, 2: 300 })
  })

  it('no duplica un concepto ya cargado ni cambia el estado si no hay nada nuevo', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'APLICAR_CARGOS_PLANTILLA', payload: [plantilla(), plantilla({ concepto: 'Pallets' })] },
    ])
    expect(base.cargos.map(c => c.concepto)).toEqual(['Flete y descarga', 'Pallets'])
    expect(cargosPlantillaNuevos(base.cargos, [plantilla({ concepto: '  flete y  DESCARGA ' })])).toEqual([])

    const otraVez = correr([{ type: 'APLICAR_CARGOS_PLANTILLA', payload: [plantilla()] }], base)
    expect(otraVez).toBe(base)
  })

  it('sanea la combinacion imposible: afectaBaseII sin ser gravado', () => {
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'APLICAR_CARGOS_PLANTILLA', payload: [plantilla({ afectaBaseII: true })] },
    ])
    expect(s.cargos[0].afectaBaseII).toBe(false)
  })
})

describe('cargos: el payload que sale a la RPC', () => {
  /** Tres lineas (neto 100, 200, 300) y un cargo con la base en monto. */
  const conTresLineas = () => correr([
    { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
    { type: 'AGREGAR_ITEM', payload: producto('b', 200) },
    { type: 'AGREGAR_ITEM', payload: producto('c', 300) },
    { type: 'AGREGAR_CARGO' },
  ])

  it('los pesos viajan por INDICE del array de items, no por lineaId', () => {
    const s = conTresLineas()
    // El vector interno esta contra lineaId, que arranca en 1.
    expect(s.cargos[0].pesos).toEqual({ 1: 100, 2: 200, 3: 300 })

    const [cargo] = cargosParaRPC(s.items, s.cargos)
    // Y sale contra el indice del payload, base 0.
    expect(cargo.pesos).toEqual({ 0: 100, 1: 200, 2: 300 })
  })

  it('borrar una linea del medio corre los indices, y por eso adentro se usa lineaId', () => {
    // Este es el caso que justifica los dos sistemas de numeracion: el peso de
    // la tercera linea tiene que terminar en el indice 1, no en el 2, o la RPC
    // se lo cobra a otro producto (o lo rechaza por fuera de rango).
    const s = correr([{ type: 'ELIMINAR_ITEM', payload: 1 }], conTresLineas())
    expect(s.items.map(i => i.lineaId)).toEqual([1, 3])
    expect(s.cargos[0].pesos).toEqual({ 1: 100, 3: 300 })

    const [cargo] = cargosParaRPC(s.items, s.cargos)
    expect(cargo.pesos).toEqual({ 0: 100, 1: 300 })
  })

  it('traduce el resto del cargo a lo que espera la mig 194', () => {
    const base = conTresLineas()
    const id = base.cargos[0].id
    const s = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: {
        concepto: '  Flete y descarga  ', monto: 1900000, condicionIva: 'gravado',
        enFactura: false, prorrateaAlCosto: true, afectaBaseII: true, baseProrrateo: 'cantidad',
      } } },
    ], base)

    expect(cargosParaRPC(s.items, s.cargos)[0]).toEqual({
      concepto: 'Flete y descarga',
      monto: 1900000,
      condicionIva: 'gravado',
      enFactura: false,
      prorrateaAlCosto: true,
      afectaBaseII: true,
      baseProrrateo: 'cantidad',
      pesos: { 0: 1, 1: 1, 2: 1 },
    })
  })

  it('avisa antes de salir a la red lo que la RPC iba a rechazar', () => {
    const base = conTresLineas()
    const id = base.cargos[0].id

    expect(validarCargos(base.cargos)).toMatch(/sin concepto/i)

    const conNombre = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { concepto: 'Flete' } } },
    ], base)
    expect(validarCargos(conNombre.cargos)).toBeNull()

    // Todos los pesos en 0 y el cargo prorratea: no llegaria a ningun costo.
    const sinLineas = correr([
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 1, peso: 0 } },
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 2, peso: 0 } },
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 3, peso: 0 } },
    ], conNombre)
    expect(validarCargos(sinLineas.cargos)).toMatch(/no tiene ninguna l.nea asignada/i)

    // Mismo cargo sin prorratear al costo: es legal, solo suma al cuadre.
    const soloFactura = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { prorrateaAlCosto: false } } },
    ], sinLineas)
    expect(validarCargos(soloFactura.cargos)).toBeNull()

    const pesoPodrido = correr([
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 1, peso: NaN } },
    ], conNombre)
    expect(validarCargos(pesoPodrido.cargos)).toMatch(/peso inv.lido/i)
  })
})

describe('cargos: banderas fiscales', () => {
  it('apaga afectaBaseII al salir de gravado', () => {
    const base = conDosLineasYUnCargo()
    const id = base.cargos[0].id
    const gravado = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { condicionIva: 'gravado', afectaBaseII: true } } },
    ], base)
    expect(gravado.cargos[0].afectaBaseII).toBe(true)

    // El motor lo lee como `gravado && afectaBaseII`: dejarlo prendido seria
    // estado invisible que reaparece solo, y ademas se persistiria asi.
    const noGravado = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { condicionIva: 'no_gravado' } } },
    ], gravado)
    expect(noGravado.cargos[0].afectaBaseII).toBe(false)
  })

  it('el impuesto interno declarado en 0 borra la clave en vez de guardarla', () => {
    // Con declarado 0 y calculado > 0 el factor de ajuste da 0 y el impuesto
    // interno de esa alicuota se borra entero. Vaciar el campo tiene que
    // significar "no declarado", no "declaro cero".
    const cargado = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 4.1667, monto: 1234 } }])
    expect(cargado.iiDeclarado).toEqual({ 4.1667: 1234 })

    const vaciado = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 4.1667, monto: 0 } }], cargado)
    expect(vaciado.iiDeclarado).toEqual({})
  })
})

describe('no gravado de cabecera: sale de los cargos', () => {
  /** Dos líneas, pallets (170.800 en el papel) y flete (no está en el papel). */
  const conPalletsYFlete = () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('b', 300) },
      { type: 'AGREGAR_CARGO' },
      { type: 'AGREGAR_CARGO' },
    ])
    const [pallets, flete] = base.cargos
    return correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id: pallets.id, cambios: { concepto: 'Pallets', monto: 170_800, condicionIva: 'no_gravado', enFactura: true } } },
      { type: 'ACTUALIZAR_CARGO', payload: { id: flete.id, cambios: { concepto: 'Flete', monto: 1_900_000, condicionIva: 'no_gravado', enFactura: false } } },
    ], base)
  }

  it('suma los no gravados que estan en la factura y deja afuera al flete', () => {
    // El flete tambien es no gravado, pero lo factura el transportista aparte:
    // no esta en ESTE papel, asi que no puede entrar al no gravado de cabecera.
    const s = conPalletsYFlete()
    expect(s.noGravado).toBe(170_800)
    expect(s.noGravadoManual).toBe(false)
  })

  it('un cargo gravado no entra al no gravado por mas que este en la factura', () => {
    const base = conPalletsYFlete()
    const bonif = correr([{ type: 'AGREGAR_CARGO' }], base)
    const id = bonif.cargos[2].id
    const s = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { concepto: 'Bonif. promo', monto: -103_465.32, condicionIva: 'gravado', enFactura: true } } },
    ], bonif)
    expect(s.noGravado).toBe(170_800)
  })

  it('sigue al cargo: cambiar el monto o sacarlo del papel mueve la cabecera', () => {
    const base = conPalletsYFlete()
    const idPallets = base.cargos[0].id

    const masCaro = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id: idPallets, cambios: { monto: 162_000 } } },
    ], base)
    expect(masCaro.noGravado).toBe(162_000)

    // Destildar "viene en la factura" lo saca del cuadre contra el papel.
    const fueraDelPapel = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id: idPallets, cambios: { enFactura: false } } },
    ], masCaro)
    expect(fueraDelPapel.noGravado).toBe(0)

    // Y borrarlo tambien.
    const sinCargo = correr([{ type: 'ELIMINAR_CARGO', payload: idPallets }], masCaro)
    expect(sinCargo.noGravado).toBe(0)
  })

  it('lo tipeado a mano no se pisa, y el boton lo devuelve al automatico', () => {
    // Misma regla que los pesos: el pre-llenado no le gana a lo escrito. Una
    // factura puede traer un no gravado que no se cargo como cargo.
    const aMano = correr([
      { type: 'SET_EXTRAS', payload: { noGravado: 999 } },
    ], conPalletsYFlete())
    expect(aMano.noGravado).toBe(999)
    expect(aMano.noGravadoManual).toBe(true)

    const idPallets = aMano.cargos[0].id
    const tocandoElCargo = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id: idPallets, cambios: { monto: 500_000 } } },
    ], aMano)
    expect(tocandoElCargo.noGravado).toBe(999)

    const devuelto = correr([{ type: 'USAR_NO_GRAVADO_DE_CARGOS' }], tocandoElCargo)
    expect(devuelto.noGravado).toBe(500_000)
    expect(devuelto.noGravadoManual).toBe(false)
  })

  it('tipear un 0 es un dato, no un campo vacio', () => {
    // Si el 0 no marcara manual, el pre-llenado lo pisaria en el siguiente tick
    // y el usuario no podria decir "esta factura no trae no gravado".
    const s = correr([
      { type: 'SET_EXTRAS', payload: { noGravado: 0 } },
    ], conPalletsYFlete())
    expect(s.noGravadoManual).toBe(true)

    const idPallets = s.cargos[0].id
    const despues = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id: idPallets, cambios: { monto: 162_000 } } },
    ], s)
    expect(despues.noGravado).toBe(0)
  })

  it('tocar otra percepcion no marca el no gravado como manual', () => {
    const s = correr([
      { type: 'SET_EXTRAS', payload: { percepcionIva: 1234 } },
    ], conPalletsYFlete())
    expect(s.noGravadoManual).toBe(false)
    expect(s.noGravado).toBe(170_800)
  })

  it('dice lo mismo que el motor sobre la misma factura', () => {
    // `totales.noGravado` del motor y la cabecera contestan la misma pregunta:
    // que parte de esta compra el proveedor facturo fuera del IVA. Si dijeran
    // distinto, el cuadre contra la factura se pondria rojo sin nada mal.
    const s = conPalletsYFlete()
    const r = calcularCostosCompra(
      lineasParaMotor(s.items, s.tipoFactura),
      cargosParaMotor(s.cargos),
      {},
    )
    expect(r.totales.noGravado).toBeCloseTo(s.noGravado, 2)
  })
})

describe('borde del motor: la regla de ZZ', () => {
  const conII = () => correr([
    { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
    { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 4 } },
    { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'impuestosInternos', valor: 8.6956 } },
  ])

  it('en ZZ pone la tasa de II y la alicuota en 0, igual que la mig 194', () => {
    const s = conII()
    expect(lineasParaMotor(s.items, 'FC')[0]).toMatchObject({
      impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado',
    })
    expect(lineasParaMotor(s.items, 'ZZ')[0]).toMatchObject({
      impuestosInternos: 0, porcentajeIva: 0, condicionIva: 'gravado',
    })
  })

  it('en ZZ el cargo suma al costo pero el impuesto interno no', () => {
    // El caso medido en la mig 194: 4 x 1000 con flete de 400 y la linea
    // declarando 8,6956 de II da costo_real 1100, no 1186,96.
    const s = conII()
    const flete = [{
      id: 1, concepto: 'Flete', monto: 400, condicionIva: 'no_gravado' as const,
      enFactura: false, prorrateaAlCosto: true, afectaBaseII: false, pesos: { 1: 1 },
    }]
    const zz = calcularCostosCompra(lineasParaMotor(s.items, 'ZZ'), flete, {})
    expect(zz.lineas[0].costoRealUnitario).toBeCloseTo(1100, 6)
    expect(zz.lineas[0].iiUnitario).toBe(0)

    // La misma compra como FC si paga el II: el cargo no cambia, la tasa si.
    const fc = calcularCostosCompra(lineasParaMotor(s.items, 'FC'), flete, {})
    expect(fc.lineas[0].costoRealUnitario).toBeCloseTo(1186.956, 3)
  })
})

describe('cuadre del impuesto interno por alicuota', () => {
  /** Dos lineas de neto 1000 con tasas de II que NO colapsan al mismo bucket. */
  const dosAlicuotas = () => correr([
    { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
    { type: 'AGREGAR_ITEM', payload: producto('b', 1000) },
    { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'impuestosInternos', valor: 4.1667 } },
    { type: 'ACTUALIZAR_ITEM', payload: { index: 1, campo: 'impuestosInternos', valor: 4.17 } },
  ])

  it('4,1667 y 4,17 son buckets distintos: declarar uno no ajusta el otro', () => {
    const s = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 4.1667, monto: 50 } }], dosAlicuotas())
    const cuadre = cuadreImpuestoInterno(s.items, s.cargos, s.iiDeclarado, 'FC')!
    expect(cuadre.map(c => c.tasa)).toEqual([4.1667, 4.17])
    expect(cuadre[0].calculado).toBeCloseTo(41.667, 6)
    expect(cuadre[0].declarado).toBe(50)
    expect(cuadre[0].factor).toBeCloseTo(50 / 41.667, 6)
    // El otro no se declaro: sin ajuste, y el cuadre lo muestra en vez de
    // arrastrarlo con el factor del vecino.
    expect(cuadre[1].declarado).toBeUndefined()
    expect(cuadre[1].factor).toBe(1)
    expect(cuadre[1].desvio).toBe(0)
  })

  it('el calculado NO viene ya ajustado por lo declarado', () => {
    // Si el "calculado" saliera del motor CON la apertura, seria igual al
    // declarado por construccion y el desvio daria 0 siempre: el cuadre no
    // podria avisar nunca.
    const s = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 4.1667, monto: 50 } }], dosAlicuotas())
    const cuadre = cuadreImpuestoInterno(s.items, s.cargos, s.iiDeclarado, 'FC')!
    expect(cuadre[0].calculado).not.toBeCloseTo(50, 2)
    expect(Math.abs(cuadre[0].desvio)).toBeGreaterThan(DESVIO_II_TOLERADO)
  })

  it('un cargo con afectaBaseII mueve el calculado; sin el flag, no', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'impuestosInternos', valor: 10 } },
      { type: 'AGREGAR_CARGO' },
    ])
    const id = base.cargos[0].id
    const bonif = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { monto: -200, condicionIva: 'gravado' } } },
    ], base)
    expect(cuadreImpuestoInterno(bonif.items, bonif.cargos, {}, 'FC')![0].calculado).toBeCloseTo(100, 6)

    const conFlag = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { afectaBaseII: true } } },
    ], bonif)
    expect(cuadreImpuestoInterno(conFlag.items, conFlag.cargos, {}, 'FC')![0].calculado).toBeCloseTo(80, 6)
  })

  it('en ZZ no hay nada que cuadrar', () => {
    const s = dosAlicuotas()
    expect(cuadreImpuestoInterno(s.items, s.cargos, s.iiDeclarado, 'ZZ')).toEqual([])
  })
})

describe('el declarado deduce que bonificaciones bajan la base', () => {
  /** Una línea de neto 1000 al 10% de II (= 100) con una bonificación gravada de −200. */
  const conBonificacion = () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'impuestosInternos', valor: 10 } },
      { type: 'AGREGAR_CARGO' },
    ])
    return correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id: base.cargos[0].id, cambios: { monto: -200, condicionIva: 'gravado' } } },
    ], base)
  }

  it('declarar 80 escribe el flag; declarar 100 lo deja apagado', () => {
    // 100 es el II sin bajar la base y 80 el II bajándola: el declarado
    // distingue las dos hipótesis y el reducer escribe la que cierra.
    const s = conBonificacion()
    const baja = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 80 } }], s)
    expect(baja.cargos[0].afectaBaseII).toBe(true)
    expect(baja.cargos[0].afectaBaseIIManual).toBe(false)

    const noBaja = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 100 } }], s)
    expect(noBaja.cargos[0].afectaBaseII).toBe(false)
  })

  it('la deduccion es punto fijo: no oscila al seguir tocando el formulario', () => {
    // Aplicar la solución cambia el flag, y el reducer vuelve a resolver en la
    // acción siguiente. Si la búsqueda mirara el valor actual del candidato,
    // esto alternaría entre dos estados en cada tecla.
    const s = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 80 } }], conBonificacion())
    const otraVez = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 80 } }], s)
    expect(otraVez.cargos[0].afectaBaseII).toBe(true)
    expect(otraVez.cargos).toStrictEqual(s.cargos)
  })

  it('lo tildado a mano manda sobre lo deducido', () => {
    const s = conBonificacion()
    const id = s.cargos[0].id
    const aMano = correr([{ type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { afectaBaseII: true } } }], s)
    expect(aMano.cargos[0].afectaBaseIIManual).toBe(true)
    // El declarado dice que NO baja la base; el usuario dijo que sí. Manda él.
    const conDeclarado = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 100 } }], aMano)
    expect(conDeclarado.cargos[0].afectaBaseII).toBe(true)
  })

  it('salir de gravado suelta la marca y el solver vuelve a opinar al volver', () => {
    const s = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 80 } }], conBonificacion())
    const id = s.cargos[0].id
    const destildado = correr([{ type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { afectaBaseII: false } } }], s)
    expect(destildado.cargos[0].afectaBaseII).toBe(false)

    // La decisión manual era sobre un cargo gravado: al dejar de serlo se va con
    // el flag, y si vuelve a serlo el declarado manda otra vez.
    const vuelta = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { condicionIva: 'no_gravado' } } },
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { condicionIva: 'gravado' } } },
    ], destildado)
    expect(vuelta.cargos[0].afectaBaseIIManual).toBe(false)
    expect(vuelta.cargos[0].afectaBaseII).toBe(true)
  })

  it('si la deduccion no es unica no se escribe nada', () => {
    // Dos bonificaciones idénticas: "baja la primera" y "baja la segunda" dan el
    // mismo impuesto interno. Escribir cualquiera de las dos sería inventar.
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'impuestosInternos', valor: 10 } },
      { type: 'AGREGAR_CARGO' },
      { type: 'AGREGAR_CARGO' },
    ])
    const dos = correr(base.cargos.map(c => (
      { type: 'ACTUALIZAR_CARGO', payload: { id: c.id, cambios: { monto: -200, condicionIva: 'gravado' } } } as Accion
    )), base)
    const s = correr([{ type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 80 } }], dos)
    expect(s.cargos.map(c => c.afectaBaseII)).toEqual([false, false])
    expect(resolucionBasesII(s.items, s.cargos, s.iiDeclarado, 'FC')!.estado).toBe('ambigua')
  })

  it('en ZZ no hay apertura declarada, asi que no hay nada que deducir', () => {
    const s = correr([
      { type: 'SET_TIPO_FACTURA', payload: 'ZZ' },
      { type: 'SET_II_DECLARADO', payload: { tasa: 10, monto: 80 } },
    ], conBonificacion())
    expect(s.cargos[0].afectaBaseII).toBe(false)
    expect(resolucionBasesII(s.items, s.cargos, s.iiDeclarado, 'ZZ')!.estado).toBe('sin_datos')
  })
})
