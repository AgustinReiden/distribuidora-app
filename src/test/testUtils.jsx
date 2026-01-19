import { render } from '@testing-library/react'
import { vi } from 'vitest'

/**
 * Mock de Supabase para tests
 */
export const createSupabaseMock = () => ({
  auth: {
    getSession: vi.fn().mockResolvedValue({ data: { session: null } }),
    signInWithPassword: vi.fn(),
    signOut: vi.fn().mockResolvedValue({ error: null }),
    onAuthStateChange: vi.fn().mockReturnValue({
      data: { subscription: { unsubscribe: vi.fn() } }
    })
  },
  from: vi.fn().mockReturnValue({
    select: vi.fn().mockReturnValue({
      eq: vi.fn().mockReturnValue({
        maybeSingle: vi.fn().mockResolvedValue({ data: null }),
        single: vi.fn().mockResolvedValue({ data: null }),
        order: vi.fn().mockReturnValue({
          limit: vi.fn().mockResolvedValue({ data: [], error: null })
        })
      }),
      order: vi.fn().mockReturnValue({
        limit: vi.fn().mockResolvedValue({ data: [], error: null })
      }),
      in: vi.fn().mockResolvedValue({ data: [], error: null })
    }),
    insert: vi.fn().mockResolvedValue({ data: null, error: null }),
    update: vi.fn().mockReturnValue({
      eq: vi.fn().mockResolvedValue({ data: null, error: null })
    }),
    delete: vi.fn().mockReturnValue({
      eq: vi.fn().mockResolvedValue({ data: null, error: null })
    })
  }),
  rpc: vi.fn().mockResolvedValue({ data: null, error: null }),
  channel: vi.fn().mockReturnValue({
    on: vi.fn().mockReturnThis(),
    subscribe: vi.fn().mockReturnValue({ unsubscribe: vi.fn() })
  })
})

/**
 * Wrapper para renderizar componentes con providers necesarios
 */
export function renderWithProviders(ui, options = {}) {
  const Wrapper = ({ children }) => {
    return children
  }

  return render(ui, { wrapper: Wrapper, ...options })
}

/**
 * Helper para esperar resolución de promesas en tests
 */
export const waitForPromises = () => new Promise(resolve => setTimeout(resolve, 0))

/**
 * Mock de datos comunes para tests
 */
export const mockData = {
  user: {
    id: 'user-123',
    email: 'test@example.com'
  },
  perfil: {
    id: 'user-123',
    nombre: 'Usuario Test',
    email: 'test@example.com',
    rol: 'admin',
    zona: 'norte'
  },
  cliente: {
    id: 'cliente-123',
    nombre: 'Cliente Test',
    nombre_fantasia: 'Negocio Test',
    direccion: 'Calle Test 123',
    telefono: '1122334455',
    email: 'cliente@test.com',
    cuit: '20123456789',
    tipo: 'minorista',
    zona: 'norte',
    limite_credito: 50000,
    saldo_cuenta: 0
  },
  producto: {
    id: 'prod-123',
    nombre: 'Producto Test',
    codigo: 'PROD001',
    precio: 1000,
    costo: 600,
    stock: 100,
    stock_minimo: 10,
    unidad: 'unidad',
    categoria: 'bebidas'
  },
  pedido: {
    id: 'pedido-123',
    numero_pedido: 1001,
    cliente_id: 'cliente-123',
    usuario_id: 'user-123',
    estado: 'pendiente',
    estado_pago: 'pendiente',
    total: 5000,
    monto_pagado: 0,
    forma_pago: 'efectivo',
    items: [
      { producto_id: 'prod-123', cantidad: 5, precio_unitario: 1000, subtotal: 5000 }
    ],
    created_at: '2024-06-15T10:00:00Z'
  }
}

/**
 * Helper para simular errores de Supabase
 */
export const createSupabaseError = (message, code = 'PGRST301') => ({
  message,
  code,
  details: null,
  hint: null
})
