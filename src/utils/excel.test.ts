import { describe, it, expect } from 'vitest'
import { armarWorkbookMultiHoja, NUM_FMT_EXCEL } from './excel'

describe('armarWorkbookMultiHoja: formato de celdas', () => {
  it('aplica el formato por columna sólo a los números', () => {
    const wb = armarWorkbookMultiHoja([{
      name: 'Datos',
      data: [
        { Nombre: 'A', Total: 1234.5, Pct: 0.256 },
        { Nombre: 'B', Total: 'n/d', Pct: 0.1 },
      ],
      formatos: { Total: 'moneda', Pct: 'porcentaje' },
    }])
    const ws = wb.getWorksheet('Datos')!
    expect(ws.getCell('A2').numFmt).toBeUndefined()
    expect(ws.getCell('B2').numFmt).toBe(NUM_FMT_EXCEL.moneda)
    expect(ws.getCell('B2').numFmt).toBe('#,##0.00')
    expect(ws.getCell('C2').numFmt).toBe('0.0%')
    // un texto en una columna con formato queda como está
    expect(ws.getCell('B3').value).toBe('n/d')
    expect(ws.getCell('B3').numFmt).toBeUndefined()
    expect(ws.getCell('C3').numFmt).toBe('0.0%')
  })

  it('formatoCelda decide por fila y pisa a formatos', () => {
    const wb = armarWorkbookMultiHoja([{
      name: 'Resumen',
      data: [
        { Indicador: 'Venta', Valor: 1500 },
        { Indicador: 'Pedidos', Valor: 12 },
        { Indicador: 'Margen %', Valor: 0.25 },
        { Indicador: 'Desde', Valor: '2026-10-01' },
      ],
      formatos: { Valor: 'moneda' },
      formatoCelda: (fila, col) => {
        if (col !== 'Valor') return undefined
        if (fila.Indicador === 'Pedidos') return 'entero'
        if (fila.Indicador === 'Margen %') return 'porcentaje'
        return undefined
      },
    }])
    const ws = wb.getWorksheet('Resumen')!
    expect(ws.getCell('B2').numFmt).toBe('#,##0.00')
    expect(ws.getCell('B3').numFmt).toBe('#,##0')
    expect(ws.getCell('B4').numFmt).toBe('0.0%')
    expect(ws.getCell('B5').numFmt).toBeUndefined()
  })

  it('la fecha lleva formato sólo si el valor es un Date', () => {
    const wb = armarWorkbookMultiHoja([{
      name: 'Serie',
      data: [
        { Fecha: new Date(Date.UTC(2026, 9, 31)), Venta: 10 },
        { Fecha: '31/10', Venta: 20 },
      ],
      formatos: { Fecha: 'fecha' },
    }])
    const ws = wb.getWorksheet('Serie')!
    expect(ws.getCell('A2').numFmt).toBe('dd/mm/yyyy')
    expect(ws.getCell('A3').numFmt).toBeUndefined()
    expect(ws.getCell('A3').value).toBe('31/10')
  })

  it('sin formatos no toca nada', () => {
    const wb = armarWorkbookMultiHoja([{ name: 'X', data: [{ a: 1 }] }])
    expect(wb.getWorksheet('X')!.getCell('A2').numFmt).toBeUndefined()
  })
})
