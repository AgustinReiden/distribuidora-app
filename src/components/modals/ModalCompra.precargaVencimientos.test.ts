/**
 * L4 (#1603): una compra con dos líneas del mismo producto (FRG2-1: 100 pagas + 10
 * de regalo) y vencimientos se guarda como UN lote por fecha (110). Al abrir la
 * edición, la precarga ponía los 110 en la primera línea, que tiene 100, y
 * `validarVencimientosLineas` no dejaba volver a guardar la compra.
 */
import { describe, it, expect } from 'vitest'
import { precargarVencimientos, type CompraItemForm } from './ModalCompra.reducer'
import { validarVencimientosLineas, aplanarVencimientos } from '../../utils/vencimientos'

const linea = (productoId: string, cantidad: number, bonificacion = 0) =>
  ({ productoId, productoNombre: `Producto ${productoId}`, cantidad, costoUnitario: 50, bonificacion }) as CompraItemForm

const validar = (items: CompraItemForm[]) =>
  validarVencimientosLineas(items.map(it => ({ nombre: it.productoNombre, cantidad: it.cantidad, vencimientos: it.vencimientos })))

describe('precargarVencimientos con dos líneas del mismo producto', () => {
  it('reparte el lote entre las líneas: cada una valida y el total por fecha no cambia', () => {
    const items = [linea('7', 100), linea('7', 10, 100)]
    const lotes = { '7': [{ fecha: '2027-03-01', cantidad: 110 }] }

    const precargadas = precargarVencimientos(items, lotes)

    expect(precargadas.map(l => l.vencimientos)).toEqual([
      [{ fecha: '2027-03-01', cantidad: 100 }],
      [{ fecha: '2027-03-01', cantidad: 10 }],
    ])
    expect(validar(precargadas)).toBeNull()
    expect(aplanarVencimientos(precargadas)).toEqual([{ producto_id: 7, fecha_vencimiento: '2027-03-01', cantidad: 110 }])
  })

  it('con dos fechas, llena en orden y una línea puede llevar las dos', () => {
    const items = [linea('7', 100), linea('3', 5), linea('7', 10, 100)]
    const lotes = { '7': [{ fecha: '2027-03-01', cantidad: 95 }, { fecha: '2027-04-01', cantidad: 15 }], '3': [{ fecha: '2027-01-01', cantidad: 5 }] }

    const precargadas = precargarVencimientos(items, lotes)

    expect(precargadas[0].vencimientos).toEqual([{ fecha: '2027-03-01', cantidad: 95 }, { fecha: '2027-04-01', cantidad: 5 }])
    expect(precargadas[1].vencimientos).toEqual([{ fecha: '2027-01-01', cantidad: 5 }])
    expect(precargadas[2].vencimientos).toEqual([{ fecha: '2027-04-01', cantidad: 10 }])
    expect(validar(precargadas)).toBeNull()
  })

  it('una línea a la que no le toca nada queda como estaba', () => {
    const items = [linea('7', 100), linea('7', 10, 100)]
    const precargadas = precargarVencimientos(items, { '7': [{ fecha: '2027-03-01', cantidad: 40 }] })
    expect(precargadas[0].vencimientos).toEqual([{ fecha: '2027-03-01', cantidad: 40 }])
    expect(precargadas[1]).toBe(items[1])
  })

  it('lo que no entra en ninguna va a la última, y la validación lo dice', () => {
    const items = [linea('7', 100), linea('7', 10, 100)]
    const precargadas = precargarVencimientos(items, { '7': [{ fecha: '2027-03-01', cantidad: 120 }] })
    expect(precargadas[1].vencimientos).toEqual([{ fecha: '2027-03-01', cantidad: 20 }])
    expect(validar(precargadas)).not.toBeNull()
    expect(aplanarVencimientos(precargadas)).toEqual([{ producto_id: 7, fecha_vencimiento: '2027-03-01', cantidad: 120 }])
  })

  it('una sola línea del producto lleva todo, como antes', () => {
    const items = [linea('7', 100)]
    const lotes = { '7': [{ fecha: '2027-03-01', cantidad: 60 }, { fecha: '2027-04-01', cantidad: 40 }] }
    expect(precargarVencimientos(items, lotes)[0].vencimientos).toEqual(lotes['7'])
  })
})
