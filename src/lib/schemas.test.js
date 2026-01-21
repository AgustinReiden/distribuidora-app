/* eslint-disable no-unused-vars */
import { describe, it, expect } from 'vitest'
import {
  clienteSchema,
  clienteRapidoSchema,
  productoSchema,
  pedidoSchema,
  pagoSchema,
  compraSchema,
  mermaSchema,
  validateForm,
  getFirstError
} from './schemas'

describe('Schemas de Validación', () => {
  describe('clienteSchema', () => {
    it('valida cliente completo correctamente', () => {
      const cliente = {
        nombre: 'Juan Pérez',
        nombre_fantasia: 'Almacén Don Juan',
        direccion: 'Av. Siempre Viva 742',
        telefono: '1122334455',
        email: 'juan@test.com',
        cuit: '20123456789',
        tipo: 'minorista',
        zona: 'norte',
        limite_credito: 50000
      }

      const result = validateForm(clienteSchema, cliente)
      expect(result.success).toBe(true)
    })

    it('rechaza nombre vacío', () => {
      const cliente = {
        nombre: '',
        nombre_fantasia: 'Test',
        direccion: 'Dirección',
        tipo: 'minorista',
        zona: 'norte'
      }

      const result = validateForm(clienteSchema, cliente)
      expect(result.success).toBe(false)
      expect(result.errors.nombre).toBeDefined()
    })

    it('rechaza nombre con solo espacios', () => {
      const cliente = {
        nombre: '   ',
        nombre_fantasia: 'Test',
        direccion: 'Dirección válida',
        tipo: 'minorista',
        zona: 'norte'
      }

      const result = validateForm(clienteSchema, cliente)
      expect(result.success).toBe(false)
    })

    it('valida CUIT de 11 dígitos', () => {
      const cliente = {
        nombre: 'Test',
        nombre_fantasia: 'Test',
        direccion: 'Dirección válida',
        tipo: 'minorista',
        zona: 'norte',
        cuit: '20-12345678-9'
      }

      const result = validateForm(clienteSchema, cliente)
      expect(result.success).toBe(true)
    })

    it('rechaza CUIT inválido', () => {
      const cliente = {
        nombre: 'Test',
        nombre_fantasia: 'Test',
        direccion: 'Dirección válida',
        tipo: 'minorista',
        zona: 'norte',
        cuit: '12345' // Muy corto
      }

      const result = validateForm(clienteSchema, cliente)
      expect(result.success).toBe(false)
    })

    it('rechaza tipo inválido', () => {
      const cliente = {
        nombre: 'Test',
        nombre_fantasia: 'Test',
        direccion: 'Dirección válida',
        tipo: 'invalido',
        zona: 'norte'
      }

      const result = validateForm(clienteSchema, cliente)
      expect(result.success).toBe(false)
      expect(result.errors.tipo).toBeDefined()
    })
  })

  describe('clienteRapidoSchema', () => {
    it('valida cliente rápido', () => {
      const cliente = {
        nombre: 'Cliente Nuevo',
        nombre_fantasia: 'Negocio',
        direccion: 'Calle 123',
        zona: 'sur'
      }

      const result = validateForm(clienteRapidoSchema, cliente)
      expect(result.success).toBe(true)
    })

    it('rechaza dirección muy corta', () => {
      const cliente = {
        nombre: 'Test',
        nombre_fantasia: 'Test',
        direccion: 'ABC',
        zona: 'sur'
      }

      const result = validateForm(clienteRapidoSchema, cliente)
      expect(result.success).toBe(false)
    })
  })

  describe('productoSchema', () => {
    it('valida producto correctamente', () => {
      const producto = {
        nombre: 'Coca Cola 2L',
        codigo: 'COC001',
        precio: 1500,
        costo_sin_iva: 1000,
        porcentaje_iva: 21,
        stock: 100,
        stock_minimo: 10,
        unidad: 'unidad'
      }

      const result = validateForm(productoSchema, producto)
      expect(result.success).toBe(true)
    })

    it('rechaza precio negativo', () => {
      const producto = {
        nombre: 'Test',
        precio: -100,
        unidad: 'unidad'
      }

      const result = validateForm(productoSchema, producto)
      expect(result.success).toBe(false)
      expect(result.errors.precio).toBeDefined()
    })

    it('rechaza stock negativo', () => {
      const producto = {
        nombre: 'Test',
        precio: 100,
        stock: -5,
        unidad: 'unidad'
      }

      const result = validateForm(productoSchema, producto)
      expect(result.success).toBe(false)
    })

    it('rechaza IVA mayor a 100%', () => {
      const producto = {
        nombre: 'Test',
        precio: 100,
        porcentaje_iva: 150,
        unidad: 'unidad'
      }

      const result = validateForm(productoSchema, producto)
      expect(result.success).toBe(false)
    })
  })

  describe('pagoSchema', () => {
    it('valida pago en efectivo', () => {
      const pago = {
        cliente_id: '123e4567-e89b-12d3-a456-426614174000',
        monto: 5000,
        forma_pago: 'efectivo'
      }

      const result = validateForm(pagoSchema, pago)
      expect(result.success).toBe(true)
    })

    it('rechaza monto cero', () => {
      const pago = {
        cliente_id: '123e4567-e89b-12d3-a456-426614174000',
        monto: 0,
        forma_pago: 'efectivo'
      }

      const result = validateForm(pagoSchema, pago)
      expect(result.success).toBe(false)
      expect(result.errors.monto).toBeDefined()
    })

    it('rechaza cheque sin número', () => {
      const pago = {
        cliente_id: '123e4567-e89b-12d3-a456-426614174000',
        monto: 5000,
        forma_pago: 'cheque',
        numero_cheque: ''
      }

      const result = validateForm(pagoSchema, pago)
      expect(result.success).toBe(false)
      expect(result.errors.numero_cheque).toBeDefined()
    })

    it('valida cheque con número', () => {
      const pago = {
        cliente_id: '123e4567-e89b-12d3-a456-426614174000',
        monto: 5000,
        forma_pago: 'cheque',
        numero_cheque: '12345678',
        banco: 'Banco Nación'
      }

      const result = validateForm(pagoSchema, pago)
      expect(result.success).toBe(true)
    })
  })

  describe('compraSchema', () => {
    it('valida compra con proveedor existente', () => {
      const compra = {
        proveedor_id: '123e4567-e89b-12d3-a456-426614174000',
        fecha_compra: '2024-06-15',
        forma_pago: 'efectivo',
        items: [
          {
            producto_id: '123e4567-e89b-12d3-a456-426614174001',
            cantidad: 10,
            costo_unitario: 100
          }
        ]
      }

      const result = validateForm(compraSchema, compra)
      expect(result.success).toBe(true)
    })

    it('valida compra con proveedor nuevo', () => {
      const compra = {
        proveedor_nombre: 'Proveedor Nuevo',
        fecha_compra: '2024-06-15',
        forma_pago: 'transferencia',
        items: [
          {
            producto_id: '123e4567-e89b-12d3-a456-426614174001',
            cantidad: 5,
            costo_unitario: 200
          }
        ]
      }

      const result = validateForm(compraSchema, compra)
      expect(result.success).toBe(true)
    })

    it('rechaza compra sin proveedor', () => {
      const compra = {
        fecha_compra: '2024-06-15',
        forma_pago: 'efectivo',
        items: [
          {
            producto_id: '123e4567-e89b-12d3-a456-426614174001',
            cantidad: 10,
            costo_unitario: 100
          }
        ]
      }

      const result = validateForm(compraSchema, compra)
      expect(result.success).toBe(false)
    })

    it('rechaza compra sin items', () => {
      const compra = {
        proveedor_id: '123e4567-e89b-12d3-a456-426614174000',
        fecha_compra: '2024-06-15',
        forma_pago: 'efectivo',
        items: []
      }

      const result = validateForm(compraSchema, compra)
      expect(result.success).toBe(false)
    })
  })

  describe('mermaSchema', () => {
    it('valida merma correctamente', () => {
      const merma = {
        producto_id: '123e4567-e89b-12d3-a456-426614174000',
        cantidad: 5,
        motivo: 'vencimiento'
      }

      const result = validateForm(mermaSchema, merma)
      expect(result.success).toBe(true)
    })

    it('rechaza cantidad cero', () => {
      const merma = {
        producto_id: '123e4567-e89b-12d3-a456-426614174000',
        cantidad: 0,
        motivo: 'rotura'
      }

      const result = validateForm(mermaSchema, merma)
      expect(result.success).toBe(false)
    })

    it('rechaza motivo inválido', () => {
      const merma = {
        producto_id: '123e4567-e89b-12d3-a456-426614174000',
        cantidad: 5,
        motivo: 'motivo_inexistente'
      }

      const result = validateForm(mermaSchema, merma)
      expect(result.success).toBe(false)
    })
  })

  describe('Helpers de validación', () => {
    describe('getFirstError', () => {
      it('retorna null para datos válidos', () => {
        const data = {
          nombre: 'Test',
          nombre_fantasia: 'Test',
          direccion: 'Dirección válida',
          tipo: 'minorista',
          zona: 'norte'
        }

        const error = getFirstError(clienteSchema, data)
        expect(error).toBeNull()
      })

      it('retorna primer error para datos inválidos', () => {
        const data = {
          nombre: '',
          nombre_fantasia: '',
          direccion: '',
          tipo: 'invalido',
          zona: ''
        }

        const error = getFirstError(clienteSchema, data)
        expect(error).toBeDefined()
        expect(typeof error).toBe('string')
      })
    })
  })
})
