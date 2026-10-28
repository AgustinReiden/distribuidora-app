import { describe, expect, it } from 'vitest'
import { armarPreviewControlStock, buscarProductoControlStock } from './controlStockPreview'
import type { ControlStockRow } from './excel'

const fila = (over: Partial<ControlStockRow>): ControlStockRow =>
  ({ codigo: null, nombre: null, stockReal: 0, stockPlanilla: 0, ...over })

const prod = (id: number, nombre: string, stock: number, codigo: string | null = null) => ({ id, nombre, stock, codigo })

describe('armarPreviewControlStock', () => {
  it('#1254: se descarga con 12, se cuentan 10 y después se venden 3 → queda en 7, no en 10', () => {
    // El sistema ya bajó a 9 por la venta posterior al conteo.
    const { cambios } = armarPreviewControlStock(
      [fila({ codigo: 'A', stockPlanilla: 12, stockReal: 10 })],
      [prod(1, 'Agua', 9, 'A')],
    )
    expect(cambios).toEqual([expect.objectContaining({
      diferencia: -2, stockActual: 9, stockNuevo: 7, movido: true, quedaNegativo: false,
    })])
  })

  it('sin movimientos desde la descarga, la diferencia da lo mismo que pisar', () => {
    const { cambios } = armarPreviewControlStock(
      [fila({ codigo: 'A', stockPlanilla: 12, stockReal: 15 })],
      [prod(1, 'Agua', 12, 'A')],
    )
    expect(cambios[0]).toMatchObject({ diferencia: 3, stockNuevo: 15, movido: false })
  })

  it('contado igual a la planilla no aplica nada aunque el stock se haya movido', () => {
    const r = armarPreviewControlStock(
      [fila({ codigo: 'A', stockPlanilla: 12, stockReal: 12 })],
      [prod(1, 'Agua', 4, 'A')],
    )
    expect(r.cambios).toEqual([])
    expect(r.sinCambio).toBe(1)
  })

  it('si lo vendido después del conteo deja el stock negativo, se marca (la RPC no lo aplica)', () => {
    const { cambios } = armarPreviewControlStock(
      [fila({ codigo: 'A', stockPlanilla: 10, stockReal: 2 })],
      [prod(1, 'Agua', 5, 'A')],
    )
    expect(cambios[0]).toMatchObject({ stockNuevo: -3, quedaNegativo: true })
  })

  it('un producto en dos filas va a repetidos y no a cambios', () => {
    const r = armarPreviewControlStock(
      [fila({ codigo: 'A', stockPlanilla: 10, stockReal: 8 }), fila({ nombre: 'agua', stockPlanilla: 10, stockReal: 7 })],
      [prod(1, 'Agua', 10, 'A')],
    )
    expect(r.cambios).toEqual([])
    expect(r.repetidos).toEqual([{ producto: expect.objectContaining({ id: 1 }), filas: 2 }])
  })

  it('lo que no se puede asociar a un producto queda aparte', () => {
    const r = armarPreviewControlStock([fila({ codigo: 'ZZ', nombre: 'Nada', stockReal: 3 })], [prod(1, 'Agua', 10, 'A')])
    expect(r.sinAsociar).toHaveLength(1)
    expect(r.cambios).toEqual([])
  })
})

describe('buscarProductoControlStock', () => {
  const productos = [prod(1, 'Agua', 1, 'A'), prod(2, 'Birra', 1, null)]

  it('primero por código, después por nombre sin mayúsculas ni espacios', () => {
    expect(buscarProductoControlStock(fila({ codigo: 'A', nombre: 'otra cosa' }), productos)?.id).toBe(1)
    expect(buscarProductoControlStock(fila({ codigo: 'X', nombre: '  birra ' }), productos)?.id).toBe(2)
    expect(buscarProductoControlStock(fila({ codigo: 'X' }), productos)).toBeUndefined()
  })
})
