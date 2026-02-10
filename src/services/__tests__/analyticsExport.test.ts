import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock modules first (before imports)
vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(),
  },
}))

vi.mock('../../utils/excel', () => ({
  createMultiSheetExcel: vi.fn(),
}))

vi.mock('../../utils/marketBasket', () => ({
  calculateMarketBasket: vi.fn(),
}))

// Import after mocking
import { supabase } from '../../lib/supabase'
import { createMultiSheetExcel } from '../../utils/excel'
import { calculateMarketBasket } from '../../utils/marketBasket'
import {
  fetchVentasDetallado,
  fetchClientesDimension,
  fetchProductosDimension,
  fetchComprasFact,
  fetchCobranzasFact,
  fetchCanastaProductos,
  exportarBI,
} from '../analyticsExport'

// Helper to create chainable Supabase mock
function createChainableMock(finalData: { data: unknown; error: unknown }) {
  const chain: Record<string, unknown> = {
    select: vi.fn(),
    gte: vi.fn(),
    lte: vi.fn(),
    is: vi.fn(),
    order: vi.fn(),
    in: vi.fn(),
  }

  // Make each method return the chain itself
  Object.keys(chain).forEach(key => {
    (chain[key] as ReturnType<typeof vi.fn>).mockReturnValue(chain)
  })

  // Make the chain thenable by adding then method
  chain.then = vi.fn((resolve) => {
    resolve(finalData)
    return Promise.resolve(finalData)
  })

  return chain
}

describe('analyticsExport', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('fetchVentasDetallado', () => {
    it('should fetch and denormalize ventas with margin calculations', async () => {
      const mockPedidos = [
        {
          id: 'p1',
          created_at: '2026-01-15T10:30:00',
          estado: 'entregado',
          estado_pago: 'pagado',
          forma_pago: 'efectivo',
          total: 1000,
          cliente: {
            id: 'c1',
            nombre_fantasia: 'Cliente Test',
            razon_social: 'Cliente Test SA',
            zona: 'Norte',
            cuit: '20-12345678-9',
          },
          items: [
            {
              id: 'i1',
              cantidad: 2,
              precio_unitario: 100,
              subtotal: 200,
              producto: {
                id: 'prod1',
                nombre: 'Producto A',
                codigo: 'PA001',
                categoria: 'Bebidas',
                costo_con_iva: 80,
              },
            },
            {
              id: 'i2',
              cantidad: 3,
              precio_unitario: 150,
              subtotal: 450,
              producto: {
                id: 'prod2',
                nombre: 'Producto B',
                codigo: 'PB002',
                categoria: 'Snacks',
                costo_con_iva: 100,
              },
            },
          ],
          preventista: { id: 'prev1', nombre: 'Juan Perez' },
          transportista: { id: 'trans1', nombre: 'Pedro Lopez' },
        },
      ]

      const chain = createChainableMock({ data: mockPedidos, error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchVentasDetallado('2026-01-01', '2026-01-31')

      expect(supabase.from).toHaveBeenCalledWith('pedidos')
      expect(chain.select).toHaveBeenCalled()
      expect(chain.gte).toHaveBeenCalledWith('created_at', '2026-01-01T00:00:00')
      expect(chain.lte).toHaveBeenCalledWith('created_at', '2026-01-31T23:59:59')
      expect(chain.is).toHaveBeenCalledWith('deleted_at', null)
      expect(chain.order).toHaveBeenCalledWith('created_at', { ascending: false })

      expect(result).toHaveLength(2)

      // First item
      expect(result[0]).toMatchObject({
        pedido_id: 'p1',
        cliente_nombre: 'Cliente Test',
        cliente_zona: 'Norte',
        producto_nombre: 'Producto A',
        cantidad: 2,
        precio_unitario: 100,
        subtotal: 200,
        costo_unitario: 80,
        costo_total: 160,
        margen_unitario: 20,
        margen_total: 40,
        margen_porcentaje: 20,
        estado_pedido: 'entregado',
        forma_pago: 'efectivo',
        preventista: 'Juan Perez',
        transportista: 'Pedro Lopez',
      })

      // Second item
      expect(result[1]).toMatchObject({
        producto_nombre: 'Producto B',
        cantidad: 3,
        precio_unitario: 150,
        subtotal: 450,
        costo_total: 300,
        margen_total: 150,
        margen_porcentaje: 33.33,
      })
    })

    it('should handle empty data', async () => {
      const chain = createChainableMock({ data: [], error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchVentasDetallado('2026-01-01', '2026-01-31')

      expect(result).toEqual([])
    })

    it('should handle pedidos with no items', async () => {
      const mockPedidos = [
        {
          id: 'p1',
          created_at: '2026-01-15T10:30:00',
          estado: 'pendiente',
          estado_pago: null,
          forma_pago: null,
          total: 0,
          cliente: { id: 'c1', nombre_fantasia: 'Cliente Test' },
          items: [],
          preventista: null,
          transportista: null,
        },
      ]

      const chain = createChainableMock({ data: mockPedidos, error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchVentasDetallado('2026-01-01', '2026-01-31')

      expect(result).toEqual([])
    })

    it('should throw error on Supabase error', async () => {
      const chain = createChainableMock({ data: null, error: { message: 'Database error' } })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      await expect(fetchVentasDetallado('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando ventas: Database error'
      )
    })

    it('should calculate margin correctly when subtotal is zero', async () => {
      const mockPedidos = [
        {
          id: 'p1',
          created_at: '2026-01-15T10:30:00',
          estado: 'pendiente',
          cliente: { id: 'c1', nombre_fantasia: 'Cliente' },
          items: [
            {
              id: 'i1',
              cantidad: 1,
              precio_unitario: 0,
              subtotal: 0,
              producto: { id: 'p1', nombre: 'Producto', costo_con_iva: 50 },
            },
          ],
          preventista: null,
          transportista: null,
        },
      ]

      const chain = createChainableMock({ data: mockPedidos, error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchVentasDetallado('2026-01-01', '2026-01-31')

      expect(result[0].margen_porcentaje).toBe(0)
    })
  })

  describe('fetchClientesDimension', () => {
    it('should calculate segmentation correctly', async () => {
      const mockClientes = [
        { id: 'c1', nombre_fantasia: 'Cliente Alto', activo: true },
        { id: 'c2', nombre_fantasia: 'Cliente Medio', activo: true },
        { id: 'c3', nombre_fantasia: 'Cliente Bajo', activo: true },
      ]

      const mockPedidos = [
        { id: 'p1', cliente_id: 'c1', total: 120000, created_at: '2026-01-15T10:00:00' },
        { id: 'p2', cliente_id: 'c2', total: 60000, created_at: '2026-01-16T10:00:00' },
        { id: 'p3', cliente_id: 'c3', total: 30000, created_at: '2026-01-17T10:00:00' },
      ]

      const clientesChain = createChainableMock({ data: mockClientes, error: null })
      const pedidosChain = createChainableMock({ data: mockPedidos, error: null })

      let callCount = 0
      vi.mocked(supabase.from).mockImplementation(() => {
        callCount++
        return (callCount === 1 ? clientesChain : pedidosChain) as never
      })

      const result = await fetchClientesDimension('2026-01-01', '2026-01-31')

      expect(result[0].segmento_valor).toBe('Alto')
      expect(result[1].segmento_valor).toBe('Medio')
      expect(result[2].segmento_valor).toBe('Bajo')
    })

    it('should calculate activity states correctly', async () => {
      const now = new Date()
      const recentDate = new Date(now.getTime() - 10 * 86400000).toISOString() // 10 days ago
      const midDate = new Date(now.getTime() - 45 * 86400000).toISOString() // 45 days ago
      const oldDate = new Date(now.getTime() - 100 * 86400000).toISOString() // 100 days ago

      const mockClientes = [
        { id: 'c1', nombre_fantasia: 'Activo' },
        { id: 'c2', nombre_fantasia: 'En riesgo' },
        { id: 'c3', nombre_fantasia: 'Inactivo' },
        { id: 'c4', nombre_fantasia: 'Nuevo' },
      ]

      const mockPedidos = [
        { id: 'p1', cliente_id: 'c1', total: 1000, created_at: recentDate },
        { id: 'p2', cliente_id: 'c2', total: 1000, created_at: midDate },
        { id: 'p3', cliente_id: 'c3', total: 1000, created_at: oldDate },
      ]

      const clientesChain = createChainableMock({ data: mockClientes, error: null })
      const pedidosChain = createChainableMock({ data: mockPedidos, error: null })

      let callCount = 0
      vi.mocked(supabase.from).mockImplementation(() => {
        callCount++
        return (callCount === 1 ? clientesChain : pedidosChain) as never
      })

      const result = await fetchClientesDimension('2026-01-01', '2026-01-31')

      expect(result[0].estado_actividad).toBe('Activo')
      expect(result[1].estado_actividad).toBe('En riesgo')
      expect(result[2].estado_actividad).toBe('Inactivo')
      expect(result[3].estado_actividad).toBe('Nuevo')
    })

    it('should throw error on clientes fetch error', async () => {
      const errorChain = createChainableMock({ data: null, error: { message: 'DB error' } })
      vi.mocked(supabase.from).mockReturnValue(errorChain as never)

      await expect(fetchClientesDimension('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando clientes: DB error'
      )
    })
  })

  describe('fetchProductosDimension', () => {
    it('should calculate rotation and velocidad_venta', async () => {
      const mockProductos = [
        { id: 'p1', nombre: 'Rapido', stock: 100, costo_con_iva: 50, activo: true },
        { id: 'p2', nombre: 'Medio', stock: 50, costo_con_iva: 30, activo: true },
        { id: 'p3', nombre: 'Lento', stock: 200, costo_con_iva: 20, activo: true },
      ]

      const mockItems = [
        // p1: 110 units over 2 days = 55 per day -> Rapida (> 10)
        {
          producto_id: 'p1',
          cantidad: 55,
          precio_unitario: 100,
          subtotal: 5500,
          pedido: { created_at: '2026-01-15T10:00:00' },
        },
        {
          producto_id: 'p1',
          cantidad: 55,
          precio_unitario: 100,
          subtotal: 5500,
          pedido: { created_at: '2026-01-16T10:00:00' },
        },
        // p2: 8 units over 2 days = 4 per day -> Media (> 3 but <= 10)
        {
          producto_id: 'p2',
          cantidad: 4,
          precio_unitario: 60,
          subtotal: 240,
          pedido: { created_at: '2026-01-15T10:00:00' },
        },
        {
          producto_id: 'p2',
          cantidad: 4,
          precio_unitario: 60,
          subtotal: 240,
          pedido: { created_at: '2026-01-16T10:00:00' },
        },
        // p3: 2 units over 1 day = 2 per day -> Lenta (<= 3)
        {
          producto_id: 'p3',
          cantidad: 2,
          precio_unitario: 40,
          subtotal: 80,
          pedido: { created_at: '2026-01-15T10:00:00' },
        },
      ]

      const productosChain = createChainableMock({ data: mockProductos, error: null })
      const itemsChain = createChainableMock({ data: mockItems, error: null })

      let callCount = 0
      vi.mocked(supabase.from).mockImplementation(() => {
        callCount++
        return (callCount === 1 ? productosChain : itemsChain) as never
      })

      const result = await fetchProductosDimension('2026-01-01', '2026-01-31')

      expect(result[0].velocidad_venta).toBe('Rapida') // 110/2 = 55 per day
      expect(result[1].velocidad_venta).toBe('Media') // 8/2 = 4 per day
      expect(result[2].velocidad_venta).toBe('Lenta') // 2/1 = 2 per day
    })

    it('should calculate stock_dias and handle zero rotation', async () => {
      const mockProductos = [
        { id: 'p1', nombre: 'Con ventas', stock: 100, costo_con_iva: 50, activo: true },
        { id: 'p2', nombre: 'Sin ventas', stock: 50, costo_con_iva: 30, activo: true },
      ]

      const mockItems = [
        {
          producto_id: 'p1',
          cantidad: 10,
          precio_unitario: 100,
          subtotal: 1000,
          pedido: { created_at: '2026-01-15T10:00:00' },
        },
      ]

      const productosChain = createChainableMock({ data: mockProductos, error: null })
      const itemsChain = createChainableMock({ data: mockItems, error: null })

      let callCount = 0
      vi.mocked(supabase.from).mockImplementation(() => {
        callCount++
        return (callCount === 1 ? productosChain : itemsChain) as never
      })

      const result = await fetchProductosDimension('2026-01-01', '2026-01-31')

      expect(result[0].stock_dias).toBe(10) // 100 stock / 10 rotation
      expect(result[1].stock_dias).toBe('N/A') // no sales
    })

    it('should throw error on productos fetch error', async () => {
      const errorChain = createChainableMock({ data: null, error: { message: 'DB error' } })
      vi.mocked(supabase.from).mockReturnValue(errorChain as never)

      await expect(fetchProductosDimension('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando productos: DB error'
      )
    })
  })

  describe('fetchComprasFact', () => {
    it('should denormalize compras correctly', async () => {
      const mockCompras = [
        {
          id: 'comp1',
          created_at: '2026-01-15T10:00:00',
          total: 5000,
          estado: 'recibida',
          proveedor: { nombre: 'Proveedor A', cuit: '30-12345678-9' },
          items: [
            {
              cantidad: 10,
              precio_unitario: 200,
              subtotal: 2000,
              producto: { nombre: 'Producto X', codigo: 'PX001', categoria: 'Cat1' },
            },
            {
              cantidad: 5,
              precio_unitario: 300,
              subtotal: 1500,
              producto: { nombre: 'Producto Y', codigo: 'PY002', categoria: 'Cat2' },
            },
          ],
        },
      ]

      const chain = createChainableMock({ data: mockCompras, error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchComprasFact('2026-01-01', '2026-01-31')

      expect(supabase.from).toHaveBeenCalledWith('compras')
      expect(result).toHaveLength(2)
      expect(result[0]).toMatchObject({
        compra_id: 'comp1',
        proveedor_nombre: 'Proveedor A',
        producto_nombre: 'Producto X',
        cantidad: 10,
        costo_unitario: 200,
        subtotal: 2000,
        estado: 'recibida',
      })
    })

    it('should throw error on Supabase error', async () => {
      const chain = createChainableMock({ data: null, error: { message: 'DB error' } })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      await expect(fetchComprasFact('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando compras: DB error'
      )
    })
  })

  describe('fetchCobranzasFact', () => {
    it('should map cobranzas correctly', async () => {
      const mockPagos = [
        {
          id: 'pago1',
          created_at: '2026-01-15T10:00:00',
          monto: 5000,
          forma_pago: 'transferencia',
          referencia: 'REF123',
          notas: 'Pago parcial',
          cliente: { id: 'c1', nombre_fantasia: 'Cliente A', zona: 'Norte' },
          pedido_id: 'p1',
        },
        {
          id: 'pago2',
          created_at: '2026-01-16T10:00:00',
          monto: 3000,
          forma_pago: 'efectivo',
          referencia: null,
          notas: null,
          cliente: { id: 'c2', nombre_fantasia: 'Cliente B', zona: 'Sur' },
          pedido_id: null,
        },
      ]

      const chain = createChainableMock({ data: mockPagos, error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchCobranzasFact('2026-01-01', '2026-01-31')

      expect(supabase.from).toHaveBeenCalledWith('pagos')
      expect(result).toHaveLength(2)
      expect(result[0]).toMatchObject({
        pago_id: 'pago1',
        cliente_nombre: 'Cliente A',
        monto: 5000,
        forma_pago: 'transferencia',
        referencia: 'REF123',
        pedido_asociado: 'p1',
      })
      expect(result[1].pedido_asociado).toBe('N/A')
    })

    it('should throw error on Supabase error', async () => {
      const chain = createChainableMock({ data: null, error: { message: 'DB error' } })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      await expect(fetchCobranzasFact('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando cobranzas: DB error'
      )
    })
  })

  describe('fetchCanastaProductos', () => {
    it('should call calculateMarketBasket and enrich with product names', async () => {
      const mockPedidos = [
        { id: 'p1', items: [{ producto_id: 'prod1' }, { producto_id: 'prod2' }] },
        { id: 'p2', items: [{ producto_id: 'prod1' }, { producto_id: 'prod3' }] },
      ]

      const mockPairs = [
        { producto_a: 'prod1', producto_b: 'prod2', frecuencia: 5, confianza: 0.8, lift: 1.6 },
        { producto_a: 'prod1', producto_b: 'prod3', frecuencia: 3, confianza: 0.6, lift: 1.2 },
      ]

      const mockProductos = [
        { id: 'prod1', nombre: 'Producto A', codigo: 'PA001' },
        { id: 'prod2', nombre: 'Producto B', codigo: 'PB002' },
        { id: 'prod3', nombre: 'Producto C', codigo: 'PC003' },
      ]

      const pedidosChain = createChainableMock({ data: mockPedidos, error: null })
      const productosChain = createChainableMock({ data: mockProductos, error: null })

      let callCount = 0
      vi.mocked(supabase.from).mockImplementation(() => {
        callCount++
        return (callCount === 1 ? pedidosChain : productosChain) as never
      })

      vi.mocked(calculateMarketBasket).mockReturnValue(mockPairs)

      const result = await fetchCanastaProductos('2026-01-01', '2026-01-31')

      expect(calculateMarketBasket).toHaveBeenCalledWith(
        [
          { items: [{ producto_id: 'prod1' }, { producto_id: 'prod2' }] },
          { items: [{ producto_id: 'prod1' }, { producto_id: 'prod3' }] },
        ],
        2
      )

      expect(result).toHaveLength(2)
      expect(result[0]).toMatchObject({
        producto_a_nombre: 'Producto A',
        producto_a_codigo: 'PA001',
        producto_b_nombre: 'Producto B',
        producto_b_codigo: 'PB002',
        veces_comprados_juntos: 5,
        confianza_porcentaje: 0.8,
        lift: 1.6,
        recomendacion: 'Fuerte',
      })
      expect(result[1].recomendacion).toBe('Moderada')
    })

    it('should return empty array when no pedidos', async () => {
      const chain = createChainableMock({ data: [], error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      const result = await fetchCanastaProductos('2026-01-01', '2026-01-31')

      expect(result).toEqual([])
      expect(calculateMarketBasket).not.toHaveBeenCalled()
    })

    it('should return empty array when calculateMarketBasket returns no pairs', async () => {
      const mockPedidos = [{ id: 'p1', items: [{ producto_id: 'prod1' }] }]

      const chain = createChainableMock({ data: mockPedidos, error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      vi.mocked(calculateMarketBasket).mockReturnValue([])

      const result = await fetchCanastaProductos('2026-01-01', '2026-01-31')

      expect(result).toEqual([])
    })

    it('should handle weak recommendations', async () => {
      const mockPedidos = [{ id: 'p1', items: [{ producto_id: 'prod1' }] }]
      const mockPairs = [
        { producto_a: 'prod1', producto_b: 'prod2', frecuencia: 1, confianza: 0.3, lift: 0.8 },
      ]
      const mockProductos = [
        { id: 'prod1', nombre: 'Producto A', codigo: 'PA001' },
        { id: 'prod2', nombre: 'Producto B', codigo: 'PB002' },
      ]

      const pedidosChain = createChainableMock({ data: mockPedidos, error: null })
      const productosChain = createChainableMock({ data: mockProductos, error: null })

      let callCount = 0
      vi.mocked(supabase.from).mockImplementation(() => {
        callCount++
        return (callCount === 1 ? pedidosChain : productosChain) as never
      })

      vi.mocked(calculateMarketBasket).mockReturnValue(mockPairs)

      const result = await fetchCanastaProductos('2026-01-01', '2026-01-31')

      expect(result[0].recomendacion).toBe('Debil')
    })

    it('should throw error on Supabase error', async () => {
      const chain = createChainableMock({ data: null, error: { message: 'DB error' } })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      await expect(fetchCanastaProductos('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando pedidos para canasta: DB error'
      )
    })
  })

  describe('exportarBI', () => {
    it('should call all fetch functions and create Excel with 7 sheets', async () => {
      // Mock all fetch functions
      const chain = createChainableMock({ data: [], error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)
      vi.mocked(calculateMarketBasket).mockReturnValue([])
      vi.mocked(createMultiSheetExcel).mockResolvedValue(undefined)

      await exportarBI('2026-01-01', '2026-01-31')

      expect(createMultiSheetExcel).toHaveBeenCalledTimes(1)

      const [sheets, filename] = vi.mocked(createMultiSheetExcel).mock.calls[0]

      expect(sheets).toHaveLength(7)
      expect(sheets[0].name).toBe('Info_Exportacion')
      expect(sheets[1].name).toBe('Ventas_Detallado')
      expect(sheets[2].name).toBe('Clientes')
      expect(sheets[3].name).toBe('Productos')
      expect(sheets[4].name).toBe('Compras')
      expect(sheets[5].name).toBe('Cobranzas')
      expect(sheets[6].name).toBe('Canasta_Productos')

      expect(filename).toBe('BI_Export_2026-01-01_2026-01-31')
    })

    it('should include metadata in Info_Exportacion sheet', async () => {
      const chain = createChainableMock({ data: [], error: null })
      vi.mocked(supabase.from).mockReturnValue(chain as never)
      vi.mocked(calculateMarketBasket).mockReturnValue([])
      vi.mocked(createMultiSheetExcel).mockResolvedValue(undefined)

      await exportarBI('2026-01-01', '2026-01-31')

      const [sheets] = vi.mocked(createMultiSheetExcel).mock.calls[0]
      const infoSheet = sheets[0]

      expect(infoSheet.data).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ Campo: 'Periodo desde', Valor: '2026-01-01' }),
          expect.objectContaining({ Campo: 'Periodo hasta', Valor: '2026-01-31' }),
          expect.objectContaining({ Campo: 'Filas en Ventas_Detallado' }),
        ])
      )
    })

    it('should propagate errors from fetch functions', async () => {
      const chain = createChainableMock({ data: null, error: { message: 'DB error' } })
      vi.mocked(supabase.from).mockReturnValue(chain as never)

      await expect(exportarBI('2026-01-01', '2026-01-31')).rejects.toThrow(
        'Error cargando ventas: DB error'
      )

      expect(createMultiSheetExcel).not.toHaveBeenCalled()
    })
  })
})
