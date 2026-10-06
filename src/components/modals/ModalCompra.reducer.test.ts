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
  cargosParaRPC, validarCargos, resolucionBasesII, construirCompraItemDesdeScan,
  validarMedidasCargos, lineasSinMedida, lineaEnAlcance,
} from './ModalCompra.reducer'
import type { CompraState } from './ModalCompra.reducer'
import type { LineaImpresa, LineaRevision } from '../../utils/revisionEscaneo'
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

/** Un renglón impreso de la factura. */
const impresa = (descripcion: string, cantidad: number, costoUnitario: number, codigo: string | null = null): LineaImpresa =>
  ({ codigo, descripcion, cantidad, costoUnitario, bonificacion: 0, iva: 21 })

/** Una línea de la revisión: con producto, nace vinculada; sin, pendiente. */
const lineaRev = (imp: LineaImpresa, productoId?: string, match: Partial<LineaRevision['match']> = {}): LineaRevision => ({
  impresa: imp,
  match: {
    estado: productoId ? 'vinculado' : 'sin_match', productoId, confianza: productoId ? 1 : 0, motivo: '', alternativas: [], ...match,
  },
  resolucion: productoId
    ? { tipo: 'producto', productoId, productoNombre: `Producto ${productoId}`, via: 'automatico', unidadesPorBulto: match.unidadesPorBulto ?? null, conversionConfirmada: false }
    : { tipo: 'pendiente' },
  advertencias: [],
})

/** APLICAR_ESCANEO con estas líneas; los productos vinculados salen de `producto(id, costo)`. */
const aplicarEscaneo = (
  lineas: LineaRevision[],
  extra: Partial<Extract<Accion, { type: 'APLICAR_ESCANEO' }>['payload']> = {},
): Accion => ({
  type: 'APLICAR_ESCANEO',
  payload: {
    proveedorId: '20', proveedorNombre: '', numeroFactura: 'A-1', fechaCompra: '2026-10-06', formaPago: 'efectivo',
    revision: { lineas, rutaArchivo: null, advertenciasGenerales: [], bonificacionPie: null },
    productos: Object.fromEntries(lineas.flatMap(l =>
      l.resolucion.tipo === 'producto' ? [[l.resolucion.productoId, producto(l.resolucion.productoId, l.impresa.costoUnitario)]] : [])),
    ...extra,
  },
})

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
  const aplicar = (cargos: CargoPlantillaCompra[], proveedorId = 'p1'): Accion =>
    ({ type: 'APLICAR_PLANTILLA_PROVEEDOR', payload: { proveedorId, cargos } })

  it('trae los pesos por producto y deja el monto en 0', () => {
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('b', 300) },
      aplicar([plantilla()]),
    ])
    expect(s.cargos).toHaveLength(1)
    expect(s.cargos[0].concepto).toBe('Flete y descarga')
    expect(s.cargos[0].monto).toBe(0)
    expect(s.cargos[0].pesos).toEqual({ 1: 40, 2: 60 })
    expect(s.plantillaProveedorId).toBe('p1')
  })

  it('la linea que no matchea ningun producto de la plantilla queda en 0', () => {
    // Y en 0 se QUEDA: si el pre-llenado por monto la pisara, el separador del
    // bidon terminaria repartido sobre toda la factura.
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('z', 900) },
      aplicar([plantilla({ pesosPorProducto: { a: 7 } })]),
    ])
    expect(s.cargos[0].pesos).toEqual({ 1: 7, 2: 0 })
  })

  it('el alcance se aplica a cada linea que LLEGA, aunque llegue despues del proveedor', () => {
    // El proveedor se elige primero y las lineas llegan despues (a mano, por
    // Excel o por el escaneo, que las reemplaza). La plantilla no puede depender
    // del orden.
    const base = correr([aplicar([plantilla({ pesosPorProducto: { a: 7 } })])])
    expect(base.cargos[0].pesos).toEqual({})
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('z', 900) },
    ], base)
    expect(s.cargos[0].pesos).toEqual({ 1: 7, 2: 0 })

    // El escaneo REEMPLAZA las lineas: el alcance se vuelve a aplicar.
    const escaneada = correr([aplicarEscaneo([
      lineaRev(impresa('Z', 3, 10), 'z'),
      lineaRev(impresa('A', 2, 10), 'a'),
    ])], s)
    expect(escaneada.items.map(i => i.productoId)).toEqual(['z', 'a'])
    expect(escaneada.cargos[0].pesos).toEqual({ 1: 0, 2: 7 })
  })

  it('cambiar la cantidad no mueve el peso traido; re-elegir la base recalcula dentro del alcance', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('z', 300) },
      aplicar([plantilla({ pesosPorProducto: { a: 7 } })]),
    ])
    const id = base.cargos[0].id
    const editada = correr([
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 9 } },
    ], base)
    expect(editada.cargos[0].pesos).toEqual({ 1: 7, 2: 0 })

    // Elegir otra base es pedir el pre-llenado: sale de la base, pero sólo
    // sobre los productos que la plantilla tocaba.
    const porMonto = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { baseProrrateo: 'cantidad' } } },
    ], editada)
    expect(porMonto.cargos[0].pesos).toEqual({ 1: 9, 2: 0 })
  })

  it('no duplica un concepto ya cargado (sin tildes ni mayusculas)', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_CARGO' },
    ])
    const id = base.cargos[0].id
    const conFlete = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { concepto: 'Bonificación', monto: -5 } } },
    ], base)
    expect(cargosPlantillaNuevos(conFlete.cargos, [plantilla({ concepto: '  BONIFICACION ' })])).toEqual([])
    const s = correr([aplicar([plantilla({ concepto: 'bonificacion' }), plantilla({ concepto: 'Pallets' })])], conFlete)
    expect(s.cargos.map(c => c.concepto)).toEqual(['Bonificación', 'Pallets'])
  })

  it('cambiar de proveedor reemplaza SOLO los cargos de plantilla sin monto y sin tocar', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      aplicar([plantilla({ concepto: 'Flete' }), plantilla({ concepto: 'Pallets' }), plantilla({ concepto: 'Separadores' })], 'p1'),
    ])
    const [flete, pallets] = base.cargos
    const tocada = correr([
      // Al flete se le puso monto; a los pallets se les cambió el IVA.
      { type: 'ACTUALIZAR_CARGO', payload: { id: flete.id, cambios: { monto: 500 } } },
      { type: 'ACTUALIZAR_CARGO', payload: { id: pallets.id, cambios: { condicionIva: 'exento' } } },
    ], base)
    const s = correr([aplicar([plantilla({ concepto: 'Estiba' }), plantilla({ concepto: 'Flete' })], 'p2')], tocada)
    // Separadores (sin tocar) se va; Flete y Pallets quedan; entra Estiba, y el
    // Flete de p2 no se duplica.
    expect(s.cargos.map(c => c.concepto)).toEqual(['Flete', 'Pallets', 'Estiba'])
    expect(s.cargos[0].monto).toBe(500)
    expect(s.plantillaProveedorId).toBe('p2')
    // Los ids no se reciclan.
    expect(new Set(s.cargos.map(c => c.id)).size).toBe(3)
  })

  it('proveedor sin compra con cargos: se van los de plantilla sin tocar y no entra nada', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      aplicar([plantilla()], 'p1'),
    ])
    const s = correr([aplicar([], 'p2')], base)
    expect(s.cargos).toEqual([])
    expect(s.plantillaProveedorId).toBe('p2')
  })

  it('trae concepto y medida, y sanea afectaBaseII sin ser gravado', () => {
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      aplicar([plantilla({ afectaBaseII: true, conceptoId: '3', medidaId: '9', baseProrrateo: 'medida' })]),
    ])
    expect(s.cargos[0].afectaBaseII).toBe(false)
    expect(s.cargos[0].conceptoId).toBe('3')
    expect(s.cargos[0].medidaId).toBe('9')
    expect(cargosParaRPC(s.items, s.cargos)[0]).toMatchObject({ conceptoId: '3', medidaId: '9' })
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
      // mig 278: concepto escrito a mano, sin catálogo; la medida sólo viaja
      // con la base 'medida'.
      conceptoId: null,
      medidaId: null,
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

/**
 * La tasa de impuesto interno de una línea escaneada, y qué se propaga al maestro.
 *
 * Se testea acá porque el fallo era doble y los dos lados son mudos. La línea
 * nacía en 0, así que el costo de la compra salía sin la tasa entera —y con él el
 * costo_real y el CPP—; y como la propagación al producto miraba sólo "difiere de
 * la ficha", ese 0 viajaba como cambio y le borraba la alícuota al producto.
 * Aplicar un escaneo destruía el II de todo lo que matcheara.
 */
describe('escaneo: la tasa de II sale de la ficha, no de un 0', () => {
  const conII = (id: string, ii: number): ProductoDB => ({
    ...producto(id, 1000),
    impuestos_internos: ii,
  } as unknown as ProductoDB)

  const scan = (codigo: string, extra: Record<string, unknown> = {}) => ({
    codigo,
    descripcion: `Producto ${codigo}`,
    cantidad: 3,
    costoUnitario: 1000,
    bonificacion: 0,
    iva: 21,
    ...extra,
  })

  it('la línea hereda la alícuota del producto', () => {
    const item = construirCompraItemDesdeScan(conII('a', 8.6957), scan('a'))
    expect(item.impuestosInternos).toBeCloseTo(8.6957, 4)
  })

  it('un producto sin impuesto interno sigue en 0', () => {
    expect(construirCompraItemDesdeScan(conII('a', 0), scan('a')).impuestosInternos).toBe(0)
  })
})

/**
 * Escáner, Entrega B (mig 292): cada línea recuerda de qué renglón de la
 * factura salió, para que al guardar la compra se aprenda la equivalencia.
 * Si una fusión o un "vincular" pierde el origen, nada falla: la próxima
 * factura simplemente vuelve a preguntar.
 */
describe('escaneo: el origen de cada línea sobrevive hasta el guardado', () => {
  const scan = (codigo: string | null, descripcion: string, extra: Record<string, unknown> = {}) => ({
    codigo, descripcion, cantidad: 2, costoUnitario: 1200, bonificacion: 0, iva: 21, ...extra,
  })

  it('la línea construida desde el escaneo guarda código y descripción impresos', () => {
    const item = construirCompraItemDesdeScan(producto('a', 1000), scan('AB12', 'AGUA VILLAM S/G 600X12'))
    expect(item.origenesEscaneo).toEqual([{ codigo: 'AB12', descripcion: 'AGUA VILLAM S/G 600X12' }])
  })

  it('la conversión de la equivalencia multiplica la cantidad y divide el costo', () => {
    const item = construirCompraItemDesdeScan(producto('a', 1000), scan(null, 'CAJA X 12'), 12)
    expect(item.cantidad).toBe(24)
    expect(item.costoUnitario).toBe(100)
  })

  it('dos renglones del mismo producto se fusionan sin perder ninguno de los dos orígenes', () => {
    const s = correr([aplicarEscaneo([
      lineaRev({ ...scan('C1', 'COLA 3L') }, 'a'),
      lineaRev({ ...scan(null, 'COLA 3 LT PROMO') }, 'a'),
    ])])
    expect(s.items).toHaveLength(1)
    expect(s.items[0].origenesEscaneo).toEqual([
      { codigo: 'C1', descripcion: 'COLA 3L' },
      { codigo: null, descripcion: 'COLA 3 LT PROMO' },
    ])
  })

  it('vincular una línea pendiente a un producto ya cargado suma el origen a esa línea', () => {
    const s = correr([
      aplicarEscaneo([lineaRev(scan('C1', 'COLA 3L'), 'a'), lineaRev(scan(null, 'MANAOS COLA 3LT'))]),
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 1, producto: producto('a', 1000), via: 'manual' } },
    ])
    expect(s.items).toHaveLength(1)
    expect(s.items[0].cantidad).toBe(4)
    expect(s.items[0].origenesEscaneo?.map(o => o.descripcion)).toEqual(['COLA 3L', 'MANAOS COLA 3LT'])
    expect(s.revisionEscaneo?.lineas.map(l => l.resolucion.tipo)).toEqual(['producto', 'producto'])
  })

  it('la conversión sugerida sólo se aplica si se vincula al producto sugerido', () => {
    const pendiente = lineaRev(scan(null, 'CAJA COLA'), undefined, { estado: 'sugerido', productoId: 'a', confianza: 0.8, unidadesPorBulto: 6 })
    const aplicar = (prod: ProductoDB) => correr([
      aplicarEscaneo([pendiente]),
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 0, producto: prod, via: 'manual' } },
    ])
    expect(aplicar(producto('a', 1000)).items[0].cantidad).toBe(12)
    expect(aplicar(producto('b', 1000)).items[0].cantidad).toBe(2)
  })

  it('lo cargado a mano no trae origen de escaneo', () => {
    const s = correr([{ type: 'AGREGAR_ITEM', payload: producto('a', 1000) }])
    expect(s.items[0].origenesEscaneo).toBeUndefined()
  })
})

/**
 * El alta rápida desde la factura (mig 277). La línea nacía con II 0 siempre,
 * aunque el producto se diera de alta con encuadre: así quedaron sin impuesto
 * interno en el costo la Citrus 3L y la Cola Lata. Ahora toma la tasa que la
 * base derivó del encuadre elegido.
 */
describe('alta rápida: la línea toma la tasa derivada del encuadre', () => {
  const rapido = (impuestosInternos?: number) => correr([
    { type: 'AGREGAR_ITEM_RAPIDO', payload: { productoId: 'n1', nombre: 'Nuevo', codigo: 'N1', costoUnitario: 1000, impuestosInternos } },
  ])

  it('con encuadre, la línea nace con la tasa que devolvió la base', () => {
    expect(rapido(4.1667).items[0].impuestosInternos).toBe(4.1667)
  })

  it('sin encuadre (o un bundle viejo que no la manda), la línea queda en 0', () => {
    expect(rapido(undefined).items[0].impuestosInternos).toBe(0)
  })
})

/**
 * Dos renglones del mismo producto se fusionan, igual que al agregarlo dos veces
 * desde el buscador. Apilarlos dejaba dos `compra_items` del mismo producto, y
 * todo lo que los indexa por producto —la nota de crédito, el UNIQUE de
 * `producto_lotes`— los contaba dos veces o los pisaba.
 */
describe('items repetidos: import y escaneo fusionan por producto', () => {
  const linea = (productoId: string, cantidad: number, costo = 1000) => ({
    productoId,
    productoNombre: `Producto ${productoId}`,
    productoCodigo: productoId,
    cantidad,
    bonificacion: 0,
    costoUnitario: costo,
    impuestosInternos: 0,
    porcentajeIva: 21,
    condicionIva: 'gravado' as const,
    stockActual: 10,
  })

  it('IMPORTAR_ITEMS suma las cantidades del mismo producto', () => {
    const s = correr([
      { type: 'IMPORTAR_ITEMS', payload: [linea('a', 6), linea('b', 2), linea('a', 4)] },
    ])
    expect(s.items).toHaveLength(2)
    expect(s.items.map(i => [i.productoId, i.cantidad])).toEqual([['a', 10], ['b', 2]])
  })

  it('IMPORTAR_ITEMS suma sobre una línea que ya estaba cargada a mano', () => {
    const s = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 1000) },
      { type: 'IMPORTAR_ITEMS', payload: [linea('a', 4)] },
    ])
    expect(s.items).toHaveLength(1)
    expect(s.items[0].cantidad).toBe(5)
  })

  it('APLICAR_ESCANEO fusiona dentro del lote escaneado', () => {
    const s = correr([aplicarEscaneo([
      lineaRev(impresa('A', 6, 1000), 'a'),
      lineaRev(impresa('A otra vez', 4, 1000), 'a'),
      lineaRev(impresa('B', 1, 1000), 'b'),
    ])])
    expect(s.items).toHaveLength(2)
    expect(s.items.map(i => [i.productoId, i.cantidad])).toEqual([['a', 10], ['b', 1]])
    // Y quedan numeradas, que es de lo que dependen los pesos de los cargos.
    expect(s.items.map(i => i.lineaId)).toEqual([1, 2])
  })

  it('APLICAR_ESCANEO fija el tipo del comprobante y prellena sólo los totales leídos', () => {
    const base = correr([
      { type: 'SET_TIPO_FACTURA', payload: 'FC' },
      { type: 'SET_CONTROL', payload: { percepciones: 77 } },
    ])
    const aplicar = (tipoFactura: 'FC' | 'ZZ' | null) => correr([
      aplicarEscaneo([], { tipoFactura, control: { gravado: 9500, total: 12045.25 } }),
    ], base)
    const zz = aplicar('ZZ')
    expect(zz.tipoFactura).toBe('ZZ')
    expect(zz.controlFactura).toEqual({ ...base.controlFactura, gravado: 9500, total: 12045.25, percepciones: 77 })
    // Comprobante no reconocido: el tipo que tenía la compra no se toca.
    expect(aplicar(null).tipoFactura).toBe('FC')
  })

  it('una línea fusionada no deja un peso de cargo apuntando a nada', () => {
    // El vector del cargo se sincroniza contra las líneas que quedaron: con dos
    // renglones apilados, uno de los dos pesos quedaba huérfano.
    const s = correr([
      { type: 'IMPORTAR_ITEMS', payload: [linea('a', 6), linea('a', 4)] },
      { type: 'AGREGAR_CARGO' },
    ])
    expect(Object.keys(s.cargos[0].pesos)).toEqual([String(s.items[0].lineaId)])
  })
})

describe('HIDRATAR: retomar un borrador', () => {
  /** Una compra con todo lo que se toca a mano y el pre-llenado pisaría. */
  const compraCargada = () => {
    const base = conDosLineasYUnCargo()
    const id = base.cargos[0].id
    return correr([
      { type: 'SET_PROVEEDOR_ID', payload: 'prov-1' },
      { type: 'SET_NUMERO_FACTURA', payload: 'A0005-00467758' },
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { concepto: 'Bonif', monto: -50, condicionIva: 'gravado' } } },
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { afectaBaseII: true } } },
      { type: 'SET_PESO_CARGO', payload: { cargoId: id, lineaId: 2, peso: 7 } },
      { type: 'SET_EXTRAS', payload: { noGravado: 0 } },
      { type: 'SET_CONTROL', payload: { total: 1234.5 } },
      { type: 'SET_VENCIMIENTOS_ITEM', payload: { index: 0, vencimientos: [{ fecha: '2027-03-01', cantidad: 1 }] } },
      { type: 'SET_II_DECLARADO', payload: { tasa: 8, monto: 10 } },
    ], base)
  }

  it('deja el estado tal cual, marcas de manual incluidas', () => {
    const original = compraCargada()
    // Ida y vuelta por JSON, que es por donde pasa el borrador.
    const copia = JSON.parse(JSON.stringify(original)) as CompraState
    const s = compraReducer(initialState, { type: 'HIDRATAR', payload: copia })

    expect(s.cargos[0].pesos).toEqual({ 1: 100, 2: 7 })
    expect(s.cargos[0].pesosManuales).toEqual({ 2: true })
    expect(s.cargos[0].afectaBaseII).toBe(true)
    expect(s.cargos[0].afectaBaseIIManual).toBe(true)
    expect(s.noGravadoManual).toBe(true)
    expect(s.noGravado).toBe(0)
    expect(s.controlFactura.total).toBe(1234.5)
    expect(s.items[0].vencimientos).toEqual([{ fecha: '2027-03-01', cantidad: 1 }])
    expect(s).toEqual(original)
  })

  it('después de hidratar, el reducer sigue numerando sin pisar ids', () => {
    const copia = JSON.parse(JSON.stringify(compraCargada())) as CompraState
    const s = correr([
      { type: 'HIDRATAR', payload: copia },
      { type: 'AGREGAR_ITEM', payload: producto('c', 10) },
    ])
    expect(s.items.map(i => i.lineaId)).toEqual([1, 2, 3])
    // El peso manual sobrevive a la línea nueva.
    expect(s.cargos[0].pesos[2]).toBe(7)
  })
})

describe('cargos: base medida y catalogo (mig 278)', () => {
  // 1 = Pallet, 3 = Lugar en el flete (base: Pallet)
  const referencia: Accion = {
    type: 'SET_MEDIDAS_REFERENCIA',
    payload: { bases: { '1': null, '3': '1' }, ficha: { a: { '1': 120 } } },
  }
  const conMedida = () => {
    const base = correr([
      referencia,
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('b', 100) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 240 } },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 1, campo: 'cantidad', valor: 1000 } },
      { type: 'AGREGAR_CARGO' },
    ])
    const id = base.cargos[0].id
    return correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { concepto: 'Pallets', monto: 300, baseProrrateo: 'medida', medidaId: '1' } } },
    ], base)
  }
  const bonificacion = {
    id: '4', nombre: 'Bonificación', signo: -1 as const, condicionIva: 'gravado' as const, enFactura: true,
    prorrateaAlCosto: true, baseProrrateo: 'monto' as const, medidaId: null, activo: true,
  }

  it('peso = cantidad / u por pallet; sin medida queda 0 y bloquea el guardado', () => {
    const s = conMedida()
    expect(s.cargos[0].pesos).toEqual({ 1: 2, 2: 0 })
    expect(lineasSinMedida(s.cargos[0], s.items, s.medidas).map(i => i.productoId)).toEqual(['b'])
    expect(validarMedidasCargos(s.cargos, s.items, s.medidas)).toMatch(/Producto b/)
  })

  it('un 0 tipeado a mano es la exclusion explicita: desbloquea', () => {
    const s = conMedida()
    const excluida = correr([{ type: 'SET_PESO_CARGO', payload: { cargoId: s.cargos[0].id, lineaId: 2, peso: 0 } }], s)
    expect(validarMedidasCargos(excluida.cargos, excluida.items, excluida.medidas)).toBeNull()
  })

  it('pallets tipeados derivan u/pallet sin redondear y el peso vuelve exacto', () => {
    const s = conMedida()
    const cargada = correr([{ type: 'SET_MEDIDA_LINEA', payload: { productoId: 'b', medidaId: '1', unidadesPor: 1000 / 3 } }], s)
    expect(cargada.medidas.compra.b['1']).toEqual({ unidadesPor: 1000 / 3, guardarEnFicha: true })
    expect(cargada.cargos[0].pesos).toEqual({ 1: 2, 2: 3 })
    expect(validarMedidasCargos(cargada.cargos, cargada.items, cargada.medidas)).toBeNull()
  })

  it('cambiar la cantidad recalcula el peso por medida (no es manual)', () => {
    const s = correr([{ type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 360 } }], conMedida())
    expect(s.cargos[0].pesos[1]).toBe(3)
  })

  it('una medida con base cae al valor de la base', () => {
    const s = conMedida()
    const flete = correr([{ type: 'ACTUALIZAR_CARGO', payload: { id: s.cargos[0].id, cambios: { medidaId: '3' } } }], s)
    expect(flete.cargos[0].pesos[1]).toBe(2)
  })

  it('tipear u/pallet en una linea con peso manual le saca la marca y recalcula', () => {
    const s = conMedida()
    const manual = correr([{ type: 'SET_PESO_CARGO', payload: { cargoId: s.cargos[0].id, lineaId: 1, peso: 7 } }], s)
    expect(manual.cargos[0].pesos[1]).toBe(7)
    const recalculada = correr([{ type: 'SET_MEDIDA_LINEA', payload: { productoId: 'a', medidaId: '1', unidadesPor: 80 } }], manual)
    expect(recalculada.cargos[0].pesos[1]).toBe(3)
    // La ficha tenia 120: el check arranca desmarcado.
    expect(recalculada.medidas.compra.a['1'].guardarEnFicha).toBe(false)
  })

  it('cargo por medida sin medida elegida no deja guardar', () => {
    const s = conMedida()
    const sin = correr([{ type: 'ACTUALIZAR_CARGO', payload: { id: s.cargos[0].id, cambios: { medidaId: null } } }], s)
    expect(validarMedidasCargos(sin.cargos, sin.items, sin.medidas)).toMatch(/no tiene medida elegida/)
  })

  it('elegir un concepto precarga sus defaults, con el signo en el monto y sin doble inversion', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_CARGO' },
    ])
    const id = base.cargos[0].id
    const s = correr([
      { type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { monto: 500 } } },
      { type: 'ELEGIR_CONCEPTO', payload: { id, concepto: bonificacion } },
    ], base)
    expect(s.cargos[0]).toMatchObject({
      concepto: 'Bonificación', conceptoId: '4', monto: -500, condicionIva: 'gravado', baseProrrateo: 'monto',
    })
    const otraVez = correr([{ type: 'ELEGIR_CONCEPTO', payload: { id, concepto: bonificacion } }], s)
    expect(otraVez.cargos[0].monto).toBe(-500)
    // Todo sigue editable, y escribir el concepto a mano lo despega del catalogo.
    const editada = correr([{ type: 'ACTUALIZAR_CARGO', payload: { id, cambios: { concepto: 'Otra cosa', enFactura: false } } }], otraVez)
    expect(editada.cargos[0]).toMatchObject({ conceptoId: null, enFactura: false })
  })

  it('"+ Crear" marca el concepto nuevo y viaja con crearConcepto', () => {
    const base = correr([
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_CARGO' },
    ])
    const id = base.cargos[0].id
    const s = correr([{ type: 'CREAR_CONCEPTO', payload: { id, nombre: ' Estiba ' } }], base)
    expect(s.cargos[0]).toMatchObject({ concepto: 'Estiba', conceptoId: null, conceptoNuevo: true })
    expect(cargosParaRPC(s.items, s.cargos)[0]).toMatchObject({ concepto: 'Estiba', crearConcepto: true, conceptoId: null })
  })

  it('plantilla con base medida: el alcance manda y adentro el peso sale de la medida', () => {
    const s = correr([
      referencia,
      { type: 'APLICAR_PLANTILLA_PROVEEDOR', payload: { proveedorId: 'p', cargos: [{
        concepto: 'Pallets', condicionIva: 'no_gravado', enFactura: true, prorrateaAlCosto: true, afectaBaseII: false,
        baseProrrateo: 'medida', medidaId: '1', conceptoId: '2', pesosPorProducto: { a: 9 },
      }] } },
      { type: 'AGREGAR_ITEM', payload: producto('a', 100) },
      { type: 'AGREGAR_ITEM', payload: producto('z', 100) },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 360 } },
    ])
    // 'a' en alcance: 360 / 120 = 3 (no el 9 de la compra vieja). 'z' fuera: 0,
    // y no cuenta como medida faltante.
    expect(s.cargos[0].pesos).toEqual({ 1: 3, 2: 0 })
    expect(lineaEnAlcance(s.cargos[0], 'z')).toBe(false)
    expect(validarMedidasCargos(s.cargos, s.items, s.medidas)).toBeNull()
  })
})

/**
 * Escáner, Entrega C: la tabla de revisión. Cada renglón de la factura entra y
 * sale de `items` por su cuenta, sin rehacer lo que ya se editó en las demás
 * líneas, y el pie pre-llena sin pisar lo tipeado.
 */
describe('revisión del escaneo: los renglones entran y salen de items', () => {
  const tresLineas = () => aplicarEscaneo([
    lineaRev(impresa('COLA 3L', 2, 1200, 'C1'), 'a'),
    lineaRev(impresa('AGUA S/G', 3, 500), undefined, { estado: 'sugerido', productoId: 'b', confianza: 0.87 }),
    lineaRev(impresa('RARO', 1, 100)),
  ])

  it('sólo lo vinculado entra a items; lo demás queda pendiente en la revisión', () => {
    const s = correr([tresLineas()])
    expect(s.items.map(i => [i.productoId, i.cantidad, i.lineasRevision])).toEqual([['a', 2, [0]]])
    expect(s.revisionEscaneo?.lineas.map(l => l.resolucion.tipo)).toEqual(['producto', 'pendiente', 'pendiente'])
  })

  it('resolver ubica la línea en el orden de la factura', () => {
    const s = correr([
      tresLineas(),
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 2, producto: producto('z', 100), via: 'manual' } },
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 1, producto: producto('b', 500), via: 'sugerencia' } },
    ])
    expect(s.items.map(i => i.productoId)).toEqual(['a', 'b', 'z'])
    expect(s.revisionEscaneo?.lineas[1].resolucion).toMatchObject({ tipo: 'producto', productoId: 'b', via: 'sugerencia' })
  })

  it('cambiar el producto de un renglón le resta su parte al viejo sin tocar lo editado en otra línea', () => {
    const s = correr([
      tresLineas(),
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 1, producto: producto('b', 500), via: 'sugerencia' } },
      { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'costoUnitario', valor: 999 } },
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 1, producto: producto('a', 500), via: 'manual' } },
    ])
    // 'b' se fue entera; 'a' suma los dos renglones y conserva el costo tipeado.
    expect(s.items.map(i => [i.productoId, i.cantidad, i.costoUnitario])).toEqual([['a', 5, 999]])
    expect(s.items[0].lineasRevision).toEqual([0, 1])
    expect(s.items[0].origenesEscaneo?.map(o => o.descripcion)).toEqual(['COLA 3L', 'AGUA S/G'])
  })

  it('omitir saca el renglón de items; deshacer lo deja pendiente', () => {
    const omitida = correr([tresLineas(), { type: 'OMITIR_LINEA_ESCANEO', payload: { index: 0 } }])
    expect(omitida.items).toHaveLength(0)
    expect(omitida.revisionEscaneo?.lineas[0].resolucion.tipo).toBe('omitida')
    const reabierta = correr([{ type: 'REABRIR_LINEA_ESCANEO', payload: { index: 0 } }], omitida)
    expect(reabierta.revisionEscaneo?.lineas[0].resolucion.tipo).toBe('pendiente')
    expect(reabierta.items).toHaveLength(0)
  })

  it('aceptar las sugeridas sólo toca lo pendiente y lo que efectivamente se sugirió', () => {
    const s = correr([
      tresLineas(),
      { type: 'ACEPTAR_SUGERIDAS_ESCANEO', payload: [
        { index: 1, producto: producto('b', 500) },
        // Ya resuelta, y un producto que no es el sugerido: no se tocan.
        { index: 0, producto: producto('b', 500) },
        { index: 2, producto: producto('q', 1) },
      ] },
    ])
    expect(s.items.map(i => i.productoId)).toEqual(['a', 'b'])
    expect(s.revisionEscaneo?.lineas.map(l => l.resolucion.tipo)).toEqual(['producto', 'producto', 'pendiente'])
  })

  it('la conversión confirmada multiplica la cantidad, divide el costo y viaja a la equivalencia', () => {
    const s = correr([tresLineas(), { type: 'SET_CONVERSION_LINEA_ESCANEO', payload: { index: 0, unidadesPorBulto: 12 } }])
    expect(s.items[0]).toMatchObject({ cantidad: 24, costoUnitario: 100 })
    expect(s.items[0].origenesEscaneo).toEqual([{ codigo: 'C1', descripcion: 'COLA 3L', unidadesPorBulto: 12 }])
    expect(s.revisionEscaneo?.lineas[0].resolucion).toMatchObject({ unidadesPorBulto: 12, conversionConfirmada: true })
    // Volver a 1:1 también es una decisión: viaja como null.
    const unoAUno = correr([{ type: 'SET_CONVERSION_LINEA_ESCANEO', payload: { index: 0, unidadesPorBulto: null } }], s)
    expect(unoAUno.items[0]).toMatchObject({ cantidad: 2, costoUnitario: 1200 })
    expect(unoAUno.items[0].origenesEscaneo?.[0].unidadesPorBulto).toBeNull()
  })

  it('una línea cargada a mano que suma un renglón se queda con lo suyo si el renglón se va', () => {
    const s = correr([
      aplicarEscaneo([lineaRev(impresa('AGUA', 3, 500))]),
      { type: 'AGREGAR_ITEM', payload: producto('b', 500) },
      { type: 'RESOLVER_LINEA_ESCANEO', payload: { index: 0, producto: producto('b', 500), via: 'manual' } },
    ])
    expect(s.items.map(i => [i.productoId, i.cantidad, i.conCargaManual])).toEqual([['b', 4, true]])
    const sinRenglon = correr([{ type: 'OMITIR_LINEA_ESCANEO', payload: { index: 0 } }], s)
    expect(sinRenglon.items.map(i => [i.productoId, i.cantidad])).toEqual([['b', 1]])
    expect(sinRenglon.items[0].origenesEscaneo).toBeUndefined()
  })

  it('borrar la línea de compra omite sus renglones en la revisión', () => {
    const s = correr([tresLineas(), { type: 'ELIMINAR_ITEM', payload: 0 }])
    expect(s.items).toHaveLength(0)
    expect(s.revisionEscaneo?.lineas[0].resolucion.tipo).toBe('omitida')
  })

  it('cerrar la revisión sólo sin pendientes', () => {
    const abierta = correr([tresLineas(), { type: 'CERRAR_REVISION_ESCANEO' }])
    expect(abierta.revisionEscaneo).not.toBeNull()
    const cerrada = correr([
      { type: 'OMITIR_LINEA_ESCANEO', payload: { index: 1 } },
      { type: 'OMITIR_LINEA_ESCANEO', payload: { index: 2 } },
      { type: 'CERRAR_REVISION_ESCANEO' },
    ], abierta)
    expect(cerrada.revisionEscaneo).toBeNull()
    expect(cerrada.items.map(i => i.productoId)).toEqual(['a'])
  })
})

describe('revisión del escaneo: el pie pre-llena sin pisar lo tipeado', () => {
  const conII = (id: string, tasa: number): ProductoDB => ({ ...producto(id, 1000), impuestos_internos: tasa } as ProductoDB)
  const escaneo = (extra: Partial<Extract<Accion, { type: 'APLICAR_ESCANEO' }>['payload']> = {}): Accion => {
    const base = aplicarEscaneo([lineaRev(impresa('COLA 3L', 10, 1000), 'a')], extra)
    if (base.type !== 'APLICAR_ESCANEO') throw new Error('x')
    return { ...base, payload: { ...base.payload, productos: { a: conII('a', 8.6957) } } }
  }
  const PIE = {
    percepcionIva: 150, percepcionIibb: 200, noGravado: 300,
    impuestosInternos: [{ tasa: 8.7, monto: 870 }], descuentosPie: [],
  }

  it('llena control, percepciones, no gravado e II por alícuota', () => {
    const s = correr([escaneo({ control: { gravado: 9500, total: 12045.25 }, pie: PIE })])
    expect(s.controlFactura).toMatchObject({ gravado: 9500, total: 12045.25 })
    expect([s.percepcionIva, s.percepcionIibb]).toEqual([150, 200])
    expect([s.noGravado, s.noGravadoManual]).toEqual([300, true])
    expect(s.iiDeclarado).toEqual({ 8.6957: 870 })
  })

  it('lo tipeado antes de escanear no se pisa', () => {
    const s = correr([
      { type: 'SET_CONTROL', payload: { total: 11000 } },
      { type: 'SET_EXTRAS', payload: { percepcionIva: 99, noGravado: 0 } },
      { type: 'SET_II_DECLARADO', payload: { tasa: 8.6957, monto: 800 } },
      escaneo({ control: { gravado: 9500, total: 12045.25 }, pie: PIE }),
    ])
    expect(s.controlFactura).toMatchObject({ gravado: 9500, total: 11000 })
    expect([s.percepcionIva, s.percepcionIibb]).toEqual([99, 200])
    // Un 0 tipeado en el no gravado es un dato ("no trae"), no un vacío.
    expect(s.noGravado).toBe(0)
    expect(s.iiDeclarado).toEqual({ 8.6957: 800 })
  })

  it('un segundo escaneo pisa lo del primero, salvo lo que se tocó entre medio', () => {
    const s = correr([
      escaneo({ control: { total: 1000 }, pie: PIE }),
      { type: 'SET_EXTRAS', payload: { percepcionIva: 1 } },
      escaneo({ control: { total: 2000 }, pie: { ...PIE, percepcionIva: 5, percepcionIibb: 6 } }),
    ])
    expect(s.controlFactura.total).toBe(2000)
    expect([s.percepcionIva, s.percepcionIibb]).toEqual([1, 6])
  })
})
