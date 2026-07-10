import { describe, it, expect } from 'vitest'
import {
  addDiasISO,
  diffDiasISO,
  ventanaPeriodoDashboard,
  ventanaAnterior,
  agregarMetricasPeriodo,
  serieVentas7Dias,
  type PedidoMetricaRow,
} from './metricasDashboard'

describe('addDiasISO', () => {
  it('suma un día sin perderse por el parseo UTC (bug del último día)', () => {
    // new Date('2026-07-10') parsea a medianoche UTC y en AR (UTC-3) el +1 se
    // anulaba; la aritmética por partes no depende del huso.
    expect(addDiasISO('2026-07-10', 1)).toBe('2026-07-11')
  })

  it('cruza el mes', () => {
    expect(addDiasISO('2026-06-30', 1)).toBe('2026-07-01')
  })

  it('resta días cruzando el mes', () => {
    expect(addDiasISO('2026-03-01', -1)).toBe('2026-02-28')
  })

  it('respeta años bisiestos', () => {
    expect(addDiasISO('2024-02-28', 1)).toBe('2024-02-29')
    expect(addDiasISO('2024-03-01', -1)).toBe('2024-02-29')
  })
})

describe('diffDiasISO', () => {
  it('cuenta los días entre dos fechas', () => {
    expect(diffDiasISO('2026-07-01', '2026-07-10')).toBe(9)
    expect(diffDiasISO('2026-07-10', '2026-07-10')).toBe(0)
  })
})

describe('ventanaPeriodoDashboard', () => {
  const HOY = '2026-07-10'

  it('hoy: un solo día, acotado arriba', () => {
    expect(ventanaPeriodoDashboard('hoy', HOY)).toEqual({ desde: HOY, hasta: HOY })
  })

  it('semana: desde hace 7 días, sin tope', () => {
    expect(ventanaPeriodoDashboard('semana', HOY)).toEqual({ desde: '2026-07-03', hasta: null })
  })

  it('mes: desde el 1° del mes, sin tope', () => {
    expect(ventanaPeriodoDashboard('mes', HOY)).toEqual({ desde: '2026-07-01', hasta: null })
  })

  it('anio: desde el 1° de enero, sin tope', () => {
    expect(ventanaPeriodoDashboard('anio', HOY)).toEqual({ desde: '2026-01-01', hasta: null })
  })

  it('historico: sin ventana', () => {
    expect(ventanaPeriodoDashboard('historico', HOY)).toEqual({ desde: null, hasta: null })
  })

  it('personalizado: usa las fechas provistas, incluido el último día', () => {
    expect(ventanaPeriodoDashboard('personalizado', HOY, '2026-07-01', '2026-07-09'))
      .toEqual({ desde: '2026-07-01', hasta: '2026-07-09' })
  })

  it('personalizado con una sola fecha', () => {
    expect(ventanaPeriodoDashboard('personalizado', HOY, '2026-07-01', null))
      .toEqual({ desde: '2026-07-01', hasta: null })
    expect(ventanaPeriodoDashboard('personalizado', HOY, null, '2026-07-09'))
      .toEqual({ desde: null, hasta: '2026-07-09' })
  })

  it('personalizado del mismo día', () => {
    expect(ventanaPeriodoDashboard('personalizado', HOY, '2026-07-05', '2026-07-05'))
      .toEqual({ desde: '2026-07-05', hasta: '2026-07-05' })
  })
})

describe('ventanaAnterior', () => {
  it('misma duración terminando el día antes (convención del RPC)', () => {
    expect(ventanaAnterior('2026-07-01', '2026-07-10'))
      .toEqual({ desde: '2026-06-21', hasta: '2026-06-30' })
  })

  it('un solo día → el día anterior', () => {
    expect(ventanaAnterior('2026-07-10', '2026-07-10'))
      .toEqual({ desde: '2026-07-09', hasta: '2026-07-09' })
  })
})

describe('agregarMetricasPeriodo', () => {
  const pedido = (over: Partial<PedidoMetricaRow>): PedidoMetricaRow => ({
    cliente_id: 'c1',
    estado: 'entregado',
    total: 100,
    ...over,
  })

  it('separa venta entregada de lo en curso y excluye cancelados', () => {
    const r = agregarMetricasPeriodo([
      pedido({ estado: 'entregado', total: 1000 }),
      pedido({ estado: 'entregado', total: 500, cliente_id: 'c2' }),
      pedido({ estado: 'pendiente', total: 200 }),
      pedido({ estado: 'asignado', total: 300 }),
      pedido({ estado: 'cancelado', total: 9999 }),
    ])
    expect(r.ventasPeriodo).toBe(1500)
    expect(r.ventasEnCurso).toBe(500)
    expect(r.pedidosPeriodo).toBe(4)
    expect(r.pedidosEntregados).toBe(2)
    expect(r.pedidosEnCurso).toBe(2)
    expect(r.pedidosPorEstado).toEqual({ pendiente: 1, asignado: 1, entregado: 2 })
  })

  it('en_preparacion cuenta como en curso y se agrupa con pendientes', () => {
    const r = agregarMetricasPeriodo([
      pedido({ estado: 'en_preparacion', total: 400 }),
      pedido({ estado: 'entregado', total: 100 }),
    ])
    expect(r.ventasPeriodo).toBe(100)
    expect(r.ventasEnCurso).toBe(400)
    expect(r.pedidosEnCurso).toBe(1)
    expect(r.pedidosPorEstado).toEqual({ pendiente: 1, asignado: 0, entregado: 1 })
  })

  it('arma top de productos y clientes sobre la actividad no cancelada', () => {
    const r = agregarMetricasPeriodo([
      pedido({
        total: 100,
        cliente: { nombre_fantasia: 'Kiosco A' },
        items: [
          { producto_id: 'p1', cantidad: 5, producto: { nombre: 'Manaos Cola' } },
          { producto_id: 'p2', cantidad: 2, producto: { nombre: 'Placer Manzana' } },
        ],
      }),
      pedido({
        estado: 'pendiente',
        total: 50,
        cliente: { nombre_fantasia: 'Kiosco A' },
        items: [{ producto_id: 'p1', cantidad: 3, producto: { nombre: 'Manaos Cola' } }],
      }),
    ])
    expect(r.productosMasVendidos).toEqual([
      { id: 'p1', nombre: 'Manaos Cola', cantidad: 8 },
      { id: 'p2', nombre: 'Placer Manzana', cantidad: 2 },
    ])
    expect(r.clientesMasActivos).toEqual([
      { id: 'c1', nombre: 'Kiosco A', total: 150, pedidos: 2 },
    ])
  })

  it('devuelve ceros con dataset vacío', () => {
    const r = agregarMetricasPeriodo([])
    expect(r.ventasPeriodo).toBe(0)
    expect(r.pedidosPeriodo).toBe(0)
    expect(r.pedidosPorEstado).toEqual({ pendiente: 0, asignado: 0, entregado: 0 })
    expect(r.productosMasVendidos).toEqual([])
  })
})

describe('serieVentas7Dias', () => {
  it('devuelve 7 buckets terminando hoy y rellena con 0 los días sin filas', () => {
    const serie = serieVentas7Dias(
      [
        { fecha: '2026-07-10', total: 100 },
        { fecha: '2026-07-10', total: 50 },
        { fecha: '2026-07-08', total: 30 },
        { fecha: '2026-07-01', total: 999 }, // fuera de la ventana de 7 días
      ],
      '2026-07-10',
    )
    expect(serie).toHaveLength(7)
    expect(serie.map(s => s.ventas)).toEqual([0, 0, 0, 0, 30, 0, 150])
    expect(serie.map(s => s.pedidos)).toEqual([0, 0, 0, 0, 1, 0, 2])
  })

  it('ignora filas sin fecha', () => {
    const serie = serieVentas7Dias([{ fecha: null, total: 100 }], '2026-07-10')
    expect(serie.every(s => s.ventas === 0)).toBe(true)
  })
})
