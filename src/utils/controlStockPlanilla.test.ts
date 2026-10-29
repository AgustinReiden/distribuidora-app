import { afterEach, describe, expect, it, vi } from 'vitest'
import ExcelJS from 'exceljs'
import { enteroDeCelda, exportControlStock, readControlStockPlanilla } from './excel'

/**
 * #1254 · La planilla de control de stock de punta a punta: la que baja el
 * sistema (exportControlStock), completada a mano, y leída de vuelta. El
 * "Stock Sistema" tiene que volver con cada fila (sin él la RPC no puede
 * aplicar la diferencia), y un conteo que no es un entero ≥ 0 no se redondea.
 */

/** Descarga la planilla real capturando el Blob en vez de bajarlo. */
async function planillaDelSistema(productos: { codigo: string | null; nombre: string; stock: number }[]) {
  let blob: Blob | null = null
  const crear = vi.fn((b: Blob) => { blob = b; return 'blob:ensayo' })
  Object.assign(URL, { createObjectURL: crear, revokeObjectURL: vi.fn() })
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  await exportControlStock(productos.map(p => ({ ...p, categoria: 'Bebidas' })))
  // El Blob es el de jsdom: se lee con su FileReader.
  const buffer = await new Promise<ArrayBuffer>((resolve, reject) => {
    const lector = new FileReader()
    lector.onload = () => resolve(lector.result as ArrayBuffer)
    lector.onerror = () => reject(lector.error)
    lector.readAsArrayBuffer(blob as unknown as Blob)
  })
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(buffer)
  return wb
}

/** Completa la columna "Stock Real" (E) de la fila del producto y devuelve el archivo. */
async function completar(wb: ExcelJS.Workbook, conteos: Record<string, unknown>): Promise<ArrayBuffer> {
  const ws = wb.worksheets[0]
  ws.eachRow((row) => {
    const nombre = String(row.getCell(2).value ?? '')
    if (nombre in conteos) row.getCell(5).value = conteos[nombre] as ExcelJS.CellValue
  })
  return (await wb.xlsx.writeBuffer()) as ArrayBuffer
}

afterEach(() => { vi.restoreAllMocks() })

describe('enteroDeCelda', () => {
  it('acepta enteros y texto con sólo dígitos', () => {
    expect(enteroDeCelda(10)).toBe(10)
    expect(enteroDeCelda(0)).toBe(0)
    expect(enteroDeCelda(' 25 ')).toBe(25)
    expect(enteroDeCelda(-3)).toBe(-3)
  })

  it('no adivina: 2,5, 2.5, "1.000" y basura son null', () => {
    expect(enteroDeCelda(2.5)).toBeNull()
    expect(enteroDeCelda('2,5')).toBeNull()
    expect(enteroDeCelda('1.000')).toBeNull()
    expect(enteroDeCelda('diez')).toBeNull()
    expect(enteroDeCelda(null)).toBeNull()
  })
})

describe('readControlStockPlanilla', () => {
  const productos = [
    { codigo: 'A1', nombre: 'Agua', stock: 12 },
    { codigo: 'B2', nombre: 'Birra', stock: 30 },
    { codigo: null, nombre: 'Cola', stock: 5 },
    { codigo: 'D4', nombre: 'Dulce', stock: 8 },
  ]

  it('devuelve el Stock Sistema de la descarga junto con lo contado', async () => {
    const wb = await planillaDelSistema(productos)
    const { filas, invalidas } = await readControlStockPlanilla(await completar(wb, { Agua: 10, Cola: '4' }))
    expect(invalidas).toEqual([])
    expect(filas).toEqual([
      { codigo: 'A1', nombre: 'Agua', stockReal: 10, stockPlanilla: 12 },
      { codigo: null, nombre: 'Cola', stockReal: 4, stockPlanilla: 5 },
    ])
  })

  it('una fila sin conteo no se ajusta (ni a 0): se omite', async () => {
    const wb = await planillaDelSistema(productos)
    const { filas } = await readControlStockPlanilla(await completar(wb, { Birra: 0 }))
    expect(filas.map(f => f.nombre)).toEqual(['Birra'])
    expect(filas[0].stockReal).toBe(0)
  })

  it('un conteo con decimales o negativo no se redondea: vuelve como inválido con su fila', async () => {
    const wb = await planillaDelSistema(productos)
    const { filas, invalidas } = await readControlStockPlanilla(
      await completar(wb, { Agua: 2.5, Birra: '2,5', Cola: -1, Dulce: 7 }),
    )
    expect(filas.map(f => f.nombre)).toEqual(['Dulce'])
    expect(invalidas.map(i => i.nombre)).toEqual(['Agua', 'Birra', 'Cola'])
    expect(invalidas.every(i => i.fila >= 5 && /entero/.test(i.motivo))).toBe(true)
  })

  it('sin el Stock Sistema de una fila no hay contra qué restar: inválida', async () => {
    const wb = await planillaDelSistema(productos)
    wb.worksheets[0].eachRow((row) => { if (row.getCell(2).value === 'Agua') row.getCell(4).value = null })
    const { filas, invalidas } = await readControlStockPlanilla(await completar(wb, { Agua: 10 }))
    expect(filas).toEqual([])
    expect(invalidas[0]).toMatchObject({ nombre: 'Agua', codigo: 'A1' })
    expect(invalidas[0].motivo).toMatch(/Stock Sistema/)
  })

  it('una planilla sin la columna Stock Sistema se rechaza entera', async () => {
    const wb = new ExcelJS.Workbook()
    const ws = wb.addWorksheet('Control de Stock')
    ws.getRow(4).values = ['Código', 'Producto', 'Stock Real']
    ws.getRow(5).values = ['A1', 'Agua', 10]
    const buffer = (await wb.xlsx.writeBuffer()) as ArrayBuffer
    await expect(readControlStockPlanilla(buffer)).rejects.toThrow(/Stock Sistema/)
  })
})
