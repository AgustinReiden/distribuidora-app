/**
 * Tests del schema de validación del cambio/devolución.
 *
 * Regresión: clientes.id y productos.id son bigint → PostgREST los devuelve como
 * NUMBER en runtime. Con z.string() el número fallaba el chequeo de tipo base y
 * devolvía "Invalid input", por lo que el cambio NUNCA se pudo cargar. El schema
 * ahora usa z.coerce.string() para tolerar ids numéricos.
 */
import { describe, it, expect } from 'vitest'
import { modalCambioProductoSchema } from './ModalCambioProducto'

const baseNumerico = {
  clienteId: 123,
  productoDevueltoId: 45,
  cantidadDevuelta: 2,
  productoEntregadoId: 45,
  cantidadEntregada: 2,
  observaciones: '',
  motivo: 'vencimiento' as const,
}

describe('modalCambioProductoSchema', () => {
  it('acepta ids NUMÉRICOS (el caso real de runtime: bigint → number)', () => {
    const result = modalCambioProductoSchema.safeParse(baseNumerico)
    expect(result.success).toBe(true)
    if (result.success) {
      // coerce normaliza a string para el RPC (que hace Number(...))
      expect(result.data.clienteId).toBe('123')
      expect(result.data.productoDevueltoId).toBe('45')
      expect(result.data.productoEntregadoId).toBe('45')
    }
  })

  it('acepta ids string (por si algún path los stringifica)', () => {
    const result = modalCambioProductoSchema.safeParse({
      ...baseNumerico,
      clienteId: '123',
      productoDevueltoId: '45',
      productoEntregadoId: '45',
    })
    expect(result.success).toBe(true)
  })

  it('rechaza cliente sin seleccionar (string vacío) con el mensaje en español', () => {
    const result = modalCambioProductoSchema.safeParse({ ...baseNumerico, clienteId: '' })
    expect(result.success).toBe(false)
    if (!result.success) {
      const msg = result.error.issues.find(i => i.path[0] === 'clienteId')?.message
      expect(msg).toBe('Debe seleccionar un cliente')
    }
  })

  it('rechaza cantidad no positiva', () => {
    const result = modalCambioProductoSchema.safeParse({ ...baseNumerico, cantidadDevuelta: 0 })
    expect(result.success).toBe(false)
  })

  it('aplica el default de motivo cuando falta', () => {
    const { motivo: _omit, ...sinMotivo } = baseNumerico
    const result = modalCambioProductoSchema.safeParse(sinMotivo)
    expect(result.success).toBe(true)
    if (result.success) expect(result.data.motivo).toBe('erroneo')
  })
})
