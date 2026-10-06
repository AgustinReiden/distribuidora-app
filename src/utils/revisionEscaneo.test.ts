/**
 * Escáner, Entrega C: la lógica pura de la pantalla de revisión. Qué bloquea el
 * guardado, cuál es la próxima línea, qué se suma con qué, la conversión que se
 * muestra, y el pre-llenado del pie sin pisar lo tipeado.
 */
import { describe, it, expect } from 'vitest'
import {
  bonificacionDelPie, construirLineasRevision, controlConBonificacionDelPie, conversionOfrecida,
  duplicadosPorProducto, estadoDeRevision, iiDelPiePorTasa, ordenRevision, prellenarCampos,
  siguientePendiente, soltarDelEscaneo, sugerenciaEsLaDelPie, textoCantidad, UMBRAL_ACEPTAR_TODAS,
} from './revisionEscaneo'
import type { LineaImpresa, LineaRevision, ResolucionLinea } from './revisionEscaneo'

const impresa = (descripcion: string, extra: Partial<LineaImpresa> = {}): LineaImpresa => ({
  codigo: null, descripcion, cantidad: 2, costoUnitario: 1200, bonificacion: 0, iva: 21, ...extra,
})

const conProducto = (productoId: string, unidadesPorBulto: number | null = null): ResolucionLinea => ({
  tipo: 'producto', productoId, productoNombre: `P${productoId}`, via: 'manual', unidadesPorBulto, conversionConfirmada: false,
})

const linea = (
  resolucion: ResolucionLinea,
  match: Partial<LineaRevision['match']> = {},
  imp: Partial<LineaImpresa> = {},
): LineaRevision => ({
  impresa: impresa('X', imp),
  match: { estado: 'sin_match', confianza: 0, motivo: '', alternativas: [], ...match },
  resolucion,
  advertencias: [],
})

const PENDIENTE: ResolucionLinea = { tipo: 'pendiente' }
const OMITIDA: ResolucionLinea = { tipo: 'omitida' }

describe('construirLineasRevision', () => {
  const impresas = [impresa('COLA 3L'), impresa('AGUA S/G'), impresa('RARO'), impresa('BAJA')]
  const matches = [
    { estado: 'vinculado' as const, productoId: '1', confianza: 1, motivo: 'eq', alternativas: [], unidadesPorBulto: 6 },
    { estado: 'sugerido' as const, productoId: '2', confianza: 0.8, motivo: 'parecido', alternativas: [{ productoId: '3' }] },
    { estado: 'sin_match' as const, confianza: 0.1, motivo: 'nada', alternativas: [] },
    // Vinculado a un producto que no está en el catálogo: no puede nacer resuelta.
    { estado: 'vinculado' as const, productoId: '99', confianza: 1, motivo: 'eq', alternativas: [] },
  ]
  const nombres: Record<string, string> = { 1: 'Cola', 2: 'Agua', 3: 'Agua 2' }
  const lineas = construirLineasRevision(impresas, matches,
    [{ mensaje: 'línea 2 dudosa', linea: 2 }, { mensaje: 'total no cierra' }], id => nombres[id])

  it('sólo lo vinculado nace resuelto, con la conversión de la equivalencia', () => {
    expect(lineas[0].resolucion).toEqual({
      tipo: 'producto', productoId: '1', productoNombre: 'Cola', via: 'automatico', unidadesPorBulto: 6, conversionConfirmada: false,
    })
    expect(lineas.slice(1).map(l => l.resolucion.tipo)).toEqual(['pendiente', 'pendiente', 'pendiente'])
  })

  it('guarda la sugerencia y las alternativas por id, y las advertencias de cada línea', () => {
    expect(lineas[1].match).toMatchObject({ estado: 'sugerido', productoId: '2', confianza: 0.8, alternativas: ['3'] })
    expect(lineas[1].advertencias).toEqual(['línea 2 dudosa'])
    expect(lineas[0].advertencias).toEqual([])
  })
})

describe('estadoDeRevision: qué bloquea el guardado', () => {
  it('lo pendiente bloquea; omitir cuenta como resuelto', () => {
    const e = estadoDeRevision([linea(conProducto('1')), linea(OMITIDA), linea(PENDIENTE)])
    expect(e).toMatchObject({ pendientes: [2], resueltas: 1, omitidas: 1, bloqueaGuardado: true })
    expect(estadoDeRevision([linea(conProducto('1')), linea(OMITIDA)]).bloqueaGuardado).toBe(false)
  })

  it('"aceptar todas" toma sólo las sugeridas pendientes con 85% o más', () => {
    const e = estadoDeRevision([
      linea(PENDIENTE, { estado: 'sugerido', productoId: 'a', confianza: UMBRAL_ACEPTAR_TODAS }),
      linea(PENDIENTE, { estado: 'sugerido', productoId: 'b', confianza: 0.84 }),
      linea(conProducto('c'), { estado: 'sugerido', productoId: 'c', confianza: 0.89 }),
      linea(PENDIENTE, { estado: 'sin_match', confianza: 0.95 }),
    ])
    expect(e.aceptablesEnLote).toEqual([0])
  })
})

describe('siguientePendiente', () => {
  const lineas = [linea(PENDIENTE), linea(conProducto('1')), linea(PENDIENTE), linea(OMITIDA)]
  it('va a la próxima pendiente en el orden de la tabla y da la vuelta', () => {
    expect(siguientePendiente(lineas, [0, 1, 2, 3], 0)).toBe(2)
    expect(siguientePendiente(lineas, [0, 1, 2, 3], 2)).toBe(0)
    expect(siguientePendiente(lineas, [2, 1, 0, 3], 1)).toBe(0)
  })
  it('sin otra pendiente, null', () => {
    expect(siguientePendiente([linea(PENDIENTE), linea(OMITIDA)], [0, 1], 0)).toBeNull()
  })
})

describe('duplicados: dos renglones al mismo producto se muestran juntos', () => {
  const lineas = [linea(conProducto('a')), linea(conProducto('b')), linea(PENDIENTE), linea(conProducto('a'))]
  it('agrupa por producto resuelto', () => {
    expect([...duplicadosPorProducto(lineas)]).toEqual([['a', [0, 3]]])
  })
  it('el orden pone el segundo debajo del primero, sin perder ninguno', () => {
    expect(ordenRevision(lineas)).toEqual([0, 3, 1, 2])
    expect(ordenRevision([linea(PENDIENTE), linea(PENDIENTE)])).toEqual([0, 1])
  })
})

describe('conversión bulto → unidad', () => {
  it('"2 bultos × 12 = 24 u" con la conversión aplicada', () => {
    expect(textoCantidad(linea(conProducto('a', 12), {}, { cantidad: 2, unidad: 'bulto' }))).toBe('2 bultos × 12 = 24 u')
  })
  it('sin conversión, la cantidad con la unidad impresa', () => {
    expect(textoCantidad(linea(conProducto('a'), {}, { cantidad: 1, unidad: 'bulto' }))).toBe('1 bulto')
    expect(textoCantidad(linea(PENDIENTE, {}, { cantidad: 3, unidad: 'unidad' }))).toBe('3 u')
    expect(textoCantidad(linea(PENDIENTE, {}, { cantidad: 3, unidad: null }))).toBe('3')
  })
  it('se OFRECE la del papel sólo si viene en bultos, la línea está resuelta y 1:1', () => {
    expect(conversionOfrecida(linea(conProducto('a'), {}, { unidad: 'bulto', unidadesPorBulto: 12 }))).toBe(12)
    expect(conversionOfrecida(linea(conProducto('a', 12), {}, { unidad: 'bulto', unidadesPorBulto: 12 }))).toBeNull()
    expect(conversionOfrecida(linea(PENDIENTE, {}, { unidad: 'bulto', unidadesPorBulto: 12 }))).toBeNull()
    expect(conversionOfrecida(linea(conProducto('a'), {}, { unidad: 'unidad', unidadesPorBulto: 12 }))).toBeNull()
  })
})

describe('prellenarCampos: el pie nunca pisa lo tipeado', () => {
  it('llena lo vacío y marca que lo llenó el escaneo', () => {
    const r = prellenarCampos({ total: 0, iva: 0 }, { total: 1000, iva: null }, [])
    expect(r.valores).toEqual({ total: 1000, iva: 0 })
    expect(r.delEscaneo).toEqual(['total'])
  })
  it('lo tipeado (con valor y sin marca) se respeta', () => {
    const r = prellenarCampos({ total: 900 }, { total: 1000 }, [])
    expect(r.valores.total).toBe(900)
    expect(r.delEscaneo).toEqual([])
  })
  it('lo que llenó un escaneo anterior lo puede pisar el nuevo', () => {
    expect(prellenarCampos({ total: 900 }, { total: 1000 }, ['total']).valores.total).toBe(1000)
  })
  it('lo no leído no se toca nunca', () => {
    expect(prellenarCampos({ total: 900 }, {}, ['total']).valores.total).toBe(900)
  })
  it('tocar un campo lo saca de la lista', () => {
    expect(soltarDelEscaneo(['control.total', 'percepcionIva'], ['control.total'])).toEqual(['percepcionIva'])
    const lista = ['a']
    expect(soltarDelEscaneo(lista, ['b'])).toBe(lista)
    expect(soltarDelEscaneo(undefined, ['b'])).toEqual([])
  })
})

describe('iiDelPiePorTasa: el II del pie contra las tasas de las líneas', () => {
  it('la tasa impresa redondeada cae en la de la ficha más cercana', () => {
    expect(iiDelPiePorTasa([{ tasa: 8.7, monto: 300 }, { tasa: 4.17, monto: 50 }], [8.6957, 4.1667, 0])).toEqual({ 8.6957: 300, 4.1667: 50 })
  })
  it('sin tasa impresa, sólo si hay una única tasa con II', () => {
    expect(iiDelPiePorTasa([{ tasa: null, monto: 300 }], [8.6957, 8.6957, 0])).toEqual({ 8.6957: 300 })
    expect(iiDelPiePorTasa([{ tasa: null, monto: 300 }], [8.6957, 4.1667])).toEqual({})
  })
  it('lo que no encuentra tasa se deja afuera (queda en el total de control)', () => {
    expect(iiDelPiePorTasa([{ tasa: 20, monto: 10 }], [8.6957])).toEqual({})
  })
})

describe('la bonificación del pie alimenta la detección de #908', () => {
  it('toma los renglones de bonificación o promoción y suma', () => {
    expect(bonificacionDelPie([
      { descripcion: 'Bonif. promo 3000cc', monto: -500 },
      { descripcion: 'Dto. promoción', monto: 120.5 },
      { descripcion: 'Redondeo', monto: 0.3 },
    ])).toEqual({ descripcion: 'Bonif. promo 3000cc + Dto. promoción', monto: 620.5 })
    expect(bonificacionDelPie([{ descripcion: 'Redondeo', monto: 1 }])).toBeNull()
    expect(bonificacionDelPie(undefined)).toBeNull()
  })

  const control = { gravadoImpreso: 0, gravadoCalculado: 10000, totalImpreso: 0, totalCalculado: 12100 }
  it('sin gravado ni total del papel, el gravado impreso es el de las líneas menos la bonificación', () => {
    expect(controlConBonificacionDelPie(control, { monto: 500 }, 10000).gravadoImpreso).toBe(9500)
  })
  it('con gravado o total del papel manda el papel; sin bonificación no cambia nada', () => {
    const conPapel = { ...control, gravadoImpreso: 9400 }
    expect(controlConBonificacionDelPie(conPapel, { monto: 500 }, 10000)).toBe(conPapel)
    expect(controlConBonificacionDelPie(control, null, 10000)).toBe(control)
  })
  it('la sugerencia "es la del pie" si el monto coincide al peso', () => {
    expect(sugerenciaEsLaDelPie(500.4, { monto: 500 })).toBe(true)
    expect(sugerenciaEsLaDelPie(530, { monto: 500 })).toBe(false)
    expect(sugerenciaEsLaDelPie(500, null)).toBe(false)
  })
})
