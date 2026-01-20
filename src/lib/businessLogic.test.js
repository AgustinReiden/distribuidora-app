import { describe, it, expect } from 'vitest'
import {
  modalClienteSchema,
  modalProductoSchema,
  modalPagoSchema,
  modalMermaSchema,
  modalProveedorSchema,
  validateForm
} from './schemas'

// ============================================
// Tests para normalizarNumero (parseador regional)
// ============================================

// Reimplementar la función para tests
const normalizarNumero = (valor) => {
  if (valor === null || valor === undefined || valor === '') return 0
  if (typeof valor === 'number') return isNaN(valor) ? 0 : valor

  let str = String(valor).trim()
  str = str.replace(/[$€£¥]/g, '').trim()

  const ultimoPunto = str.lastIndexOf('.')
  const ultimaComa = str.lastIndexOf(',')

  // Formato europeo/argentino: 1.500,50
  if (ultimaComa > ultimoPunto) {
    str = str.replace(/\./g, '').replace(',', '.')
  }
  // Formato americano: 1,500.50
  else if (ultimoPunto > ultimaComa && ultimaComa !== -1) {
    str = str.replace(/,/g, '')
  }
  // Solo coma decimal: 1500,50
  else if (ultimaComa !== -1 && ultimoPunto === -1) {
    str = str.replace(',', '.')
  }

  const resultado = parseFloat(str)
  return isNaN(resultado) ? 0 : resultado
}

describe('normalizarNumero - Parsing de números regionales', () => {
  describe('Formato europeo/argentino (coma decimal)', () => {
    it('convierte "1.500,50" a 1500.50', () => {
      expect(normalizarNumero('1.500,50')).toBe(1500.50)
    })

    it('convierte "10.000,00" a 10000', () => {
      expect(normalizarNumero('10.000,00')).toBe(10000)
    })

    it('convierte "1.234.567,89" a 1234567.89', () => {
      expect(normalizarNumero('1.234.567,89')).toBe(1234567.89)
    })

    it('convierte "500,75" a 500.75', () => {
      expect(normalizarNumero('500,75')).toBe(500.75)
    })
  })

  describe('Formato americano (punto decimal)', () => {
    it('convierte "1,500.50" a 1500.50', () => {
      expect(normalizarNumero('1,500.50')).toBe(1500.50)
    })

    it('convierte "10,000.00" a 10000', () => {
      expect(normalizarNumero('10,000.00')).toBe(10000)
    })

    it('convierte "1,234,567.89" a 1234567.89', () => {
      expect(normalizarNumero('1,234,567.89')).toBe(1234567.89)
    })
  })

  describe('Números simples', () => {
    it('convierte "500.75" a 500.75', () => {
      expect(normalizarNumero('500.75')).toBe(500.75)
    })

    it('convierte "1500" a 1500', () => {
      expect(normalizarNumero('1500')).toBe(1500)
    })

    it('convierte "0" a 0', () => {
      expect(normalizarNumero('0')).toBe(0)
    })
  })

  describe('Con símbolos de moneda', () => {
    it('convierte "$1.500,50" a 1500.50', () => {
      expect(normalizarNumero('$1.500,50')).toBe(1500.50)
    })

    it('convierte "€1.500,50" a 1500.50', () => {
      expect(normalizarNumero('€1.500,50')).toBe(1500.50)
    })

    it('convierte "$ 2,500.00" a 2500', () => {
      expect(normalizarNumero('$ 2,500.00')).toBe(2500)
    })
  })

  describe('Valores especiales', () => {
    it('retorna 0 para null', () => {
      expect(normalizarNumero(null)).toBe(0)
    })

    it('retorna 0 para undefined', () => {
      expect(normalizarNumero(undefined)).toBe(0)
    })

    it('retorna 0 para string vacío', () => {
      expect(normalizarNumero('')).toBe(0)
    })

    it('retorna 0 para texto no numérico', () => {
      expect(normalizarNumero('abc')).toBe(0)
    })

    it('preserva números ya parseados', () => {
      expect(normalizarNumero(1500.50)).toBe(1500.50)
    })

    it('retorna 0 para NaN', () => {
      expect(normalizarNumero(NaN)).toBe(0)
    })
  })
})

// ============================================
// Tests para validación de stock offline
// ============================================

describe('Validación de stock offline', () => {
  const mockProductos = [
    { id: 'prod1', nombre: 'Producto 1', stock: 100 },
    { id: 'prod2', nombre: 'Producto 2', stock: 50 },
    { id: 'prod3', nombre: 'Producto 3', stock: 10 }
  ]

  // Simular la lógica de validación de stock
  const validarStockOffline = (items, productos, pedidosPendientes = []) => {
    const itemsSinStock = []
    const stockSnapshot = {}

    // Calcular stock reservado por pedidos pendientes
    const stockReservado = {}
    pedidosPendientes.forEach(pedido => {
      pedido.items?.forEach(item => {
        stockReservado[item.productoId] = (stockReservado[item.productoId] || 0) + item.cantidad
      })
    })

    for (const item of items) {
      const producto = productos.find(p => p.id === item.productoId)
      if (producto) {
        const stockActual = producto.stock || 0
        const reservado = stockReservado[item.productoId] || 0
        const stockDisponible = stockActual - reservado

        stockSnapshot[item.productoId] = {
          stockAlMomento: stockActual,
          reservadoOffline: reservado,
          disponible: stockDisponible
        }

        if (item.cantidad > stockDisponible) {
          itemsSinStock.push({
            productoId: item.productoId,
            nombre: producto.nombre,
            solicitado: item.cantidad,
            disponible: Math.max(0, stockDisponible)
          })
        }
      }
    }

    return {
      success: itemsSinStock.length === 0,
      itemsSinStock,
      stockSnapshot
    }
  }

  describe('Validación básica', () => {
    it('permite pedido con stock suficiente', () => {
      const items = [{ productoId: 'prod1', cantidad: 50 }]
      const result = validarStockOffline(items, mockProductos)

      expect(result.success).toBe(true)
      expect(result.itemsSinStock).toHaveLength(0)
    })

    it('rechaza pedido sin stock suficiente', () => {
      const items = [{ productoId: 'prod3', cantidad: 15 }]
      const result = validarStockOffline(items, mockProductos)

      expect(result.success).toBe(false)
      expect(result.itemsSinStock).toHaveLength(1)
      expect(result.itemsSinStock[0].solicitado).toBe(15)
      expect(result.itemsSinStock[0].disponible).toBe(10)
    })

    it('permite pedido que usa exactamente todo el stock', () => {
      const items = [{ productoId: 'prod3', cantidad: 10 }]
      const result = validarStockOffline(items, mockProductos)

      expect(result.success).toBe(true)
    })
  })

  describe('Con pedidos pendientes', () => {
    it('considera stock reservado por pedidos offline pendientes', () => {
      const items = [{ productoId: 'prod2', cantidad: 30 }]
      const pedidosPendientes = [
        { items: [{ productoId: 'prod2', cantidad: 25 }] }
      ]

      const result = validarStockOffline(items, mockProductos, pedidosPendientes)

      expect(result.success).toBe(false)
      expect(result.itemsSinStock[0].disponible).toBe(25) // 50 - 25 reservado
    })

    it('acumula reservas de múltiples pedidos pendientes', () => {
      const items = [{ productoId: 'prod1', cantidad: 50 }]
      const pedidosPendientes = [
        { items: [{ productoId: 'prod1', cantidad: 30 }] },
        { items: [{ productoId: 'prod1', cantidad: 25 }] }
      ]

      const result = validarStockOffline(items, mockProductos, pedidosPendientes)

      expect(result.success).toBe(false)
      expect(result.stockSnapshot['prod1'].reservadoOffline).toBe(55)
      expect(result.stockSnapshot['prod1'].disponible).toBe(45)
    })
  })

  describe('Stock snapshot', () => {
    it('genera snapshot correcto del estado del stock', () => {
      const items = [
        { productoId: 'prod1', cantidad: 10 },
        { productoId: 'prod2', cantidad: 5 }
      ]

      const result = validarStockOffline(items, mockProductos)

      expect(result.stockSnapshot['prod1']).toEqual({
        stockAlMomento: 100,
        reservadoOffline: 0,
        disponible: 100
      })
      expect(result.stockSnapshot['prod2']).toEqual({
        stockAlMomento: 50,
        reservadoOffline: 0,
        disponible: 50
      })
    })
  })
})

// ============================================
// Tests para schemas de validación Zod
// ============================================

describe('Schemas Zod para modales', () => {
  describe('modalClienteSchema', () => {
    it('valida cliente con datos mínimos correctos', () => {
      const data = {
        tipo_documento: 'CUIT',
        numero_documento: '20-12345678-9',
        razonSocial: 'Test Company',
        nombreFantasia: 'Test',
        direccion: 'Calle Test 123'
      }
      const result = modalClienteSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('rechaza razón social muy corta', () => {
      const data = {
        tipo_documento: 'CUIT',
        numero_documento: '20-12345678-9',
        razonSocial: 'A',
        nombreFantasia: 'Test',
        direccion: 'Calle Test 123'
      }
      const result = modalClienteSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('rechaza dirección muy corta', () => {
      const data = {
        tipo_documento: 'CUIT',
        numero_documento: '20-12345678-9',
        razonSocial: 'Test Company',
        nombreFantasia: 'Test',
        direccion: 'ABC'
      }
      const result = modalClienteSchema.safeParse(data)
      expect(result.success).toBe(false)
    })
  })

  describe('modalProductoSchema', () => {
    it('valida producto con datos correctos', () => {
      const data = {
        nombre: 'Producto Test',
        stock: 100,
        precio: 150.50
      }
      const result = modalProductoSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('rechaza precio 0 o negativo', () => {
      const data = {
        nombre: 'Producto Test',
        stock: 100,
        precio: 0
      }
      const result = modalProductoSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('rechaza stock negativo', () => {
      const data = {
        nombre: 'Producto Test',
        stock: -5,
        precio: 100
      }
      const result = modalProductoSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('convierte strings numéricos a números', () => {
      const data = {
        nombre: 'Producto Test',
        stock: '100',
        precio: '150.50'
      }
      const result = modalProductoSchema.safeParse(data)
      expect(result.success).toBe(true)
      expect(result.data.stock).toBe(100)
      expect(result.data.precio).toBe(150.50)
    })
  })

  describe('modalPagoSchema', () => {
    it('valida pago en efectivo', () => {
      const data = {
        monto: 1000,
        formaPago: 'efectivo'
      }
      const result = modalPagoSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('requiere número de cheque para pagos con cheque', () => {
      const data = {
        monto: 1000,
        formaPago: 'cheque',
        referencia: ''
      }
      const result = modalPagoSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('acepta pago con cheque si tiene número', () => {
      const data = {
        monto: 1000,
        formaPago: 'cheque',
        referencia: '12345678'
      }
      const result = modalPagoSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('rechaza monto 0 o negativo', () => {
      const data = {
        monto: 0,
        formaPago: 'efectivo'
      }
      const result = modalPagoSchema.safeParse(data)
      expect(result.success).toBe(false)
    })
  })

  describe('modalMermaSchema', () => {
    it('valida merma con datos correctos', () => {
      const data = {
        cantidad: 5,
        motivo: 'rotura'
      }
      const result = modalMermaSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('requiere motivo', () => {
      const data = {
        cantidad: 5,
        motivo: ''
      }
      const result = modalMermaSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('rechaza cantidad 0', () => {
      const data = {
        cantidad: 0,
        motivo: 'vencimiento'
      }
      const result = modalMermaSchema.safeParse(data)
      expect(result.success).toBe(false)
    })
  })

  describe('modalProveedorSchema', () => {
    it('valida proveedor con nombre', () => {
      const data = {
        nombre: 'Proveedor Test'
      }
      const result = modalProveedorSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('valida CUIT con 11 dígitos', () => {
      const data = {
        nombre: 'Proveedor Test',
        cuit: '20-12345678-9'
      }
      const result = modalProveedorSchema.safeParse(data)
      expect(result.success).toBe(true)
    })

    it('rechaza CUIT con menos de 11 dígitos', () => {
      const data = {
        nombre: 'Proveedor Test',
        cuit: '12345'
      }
      const result = modalProveedorSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('rechaza email inválido', () => {
      const data = {
        nombre: 'Proveedor Test',
        email: 'no-es-email'
      }
      const result = modalProveedorSchema.safeParse(data)
      expect(result.success).toBe(false)
    })

    it('acepta email válido', () => {
      const data = {
        nombre: 'Proveedor Test',
        email: 'test@example.com'
      }
      const result = modalProveedorSchema.safeParse(data)
      expect(result.success).toBe(true)
    })
  })
})
