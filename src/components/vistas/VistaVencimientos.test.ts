/**
 * Tests del schema de la devolución al proveedor (issue #564).
 *
 * `producto_lotes.id` es bigint → PostgREST lo devuelve como NUMBER en runtime.
 * Con `z.string()` el número falla el chequeo de tipo base y el formulario diría
 * "Invalid input" sin que nada más se rompa, que es exactamente el bug que el
 * schema de ModalCambioProducto ya pagó una vez.
 */
import { describe, it, expect } from 'vitest'
import { devolucionProveedorSchema } from './VistaVencimientos'

const base = {
  loteId: 123,
  cantidad: 3,
  numeroNota: 'NC-0001',
  motivo: 'Vencido, se lo lleva el proveedor',
}

describe('devolucionProveedorSchema', () => {
  it('acepta el id NUMÉRICO (el caso real de runtime: bigint → number)', () => {
    const result = devolucionProveedorSchema.safeParse(base)
    expect(result.success).toBe(true)
    if (result.success) expect(result.data.loteId).toBe('123')
  })

  it('acepta la cantidad como string (viene de un <input type="number">)', () => {
    const result = devolucionProveedorSchema.safeParse({ ...base, cantidad: '3' })
    expect(result.success).toBe(true)
    if (result.success) expect(result.data.cantidad).toBe(3)
  })

  it('exige el número de la nota de crédito', () => {
    const result = devolucionProveedorSchema.safeParse({ ...base, numeroNota: '   ' })
    expect(result.success).toBe(false)
    if (!result.success) {
      const msg = result.error.issues.find(i => i.path[0] === 'numeroNota')?.message
      expect(msg).toBe('Falta el número de la nota de crédito')
    }
  })

  it('rechaza fracciones: las unidades son enteras en la base', () => {
    const result = devolucionProveedorSchema.safeParse({ ...base, cantidad: 2.5 })
    expect(result.success).toBe(false)
  })

  it('rechaza cantidad no positiva', () => {
    const result = devolucionProveedorSchema.safeParse({ ...base, cantidad: 0 })
    expect(result.success).toBe(false)
  })

  it('el motivo es opcional', () => {
    const { motivo: _omit, ...sinMotivo } = base
    const result = devolucionProveedorSchema.safeParse(sinMotivo)
    expect(result.success).toBe(true)
  })
})
