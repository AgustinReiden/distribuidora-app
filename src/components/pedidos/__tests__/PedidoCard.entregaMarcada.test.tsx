/**
 * Quién marcó la entrega y cuándo, en la tarjeta del pedido.
 *
 * `entregado_at` es el instante en que se marcó (trigger del servidor), no
 * `fecha_entrega`, que es la fecha declarada. Un pedido sin registro (anterior
 * a la migración) o que no está entregado no muestra nada.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

// Mock de supabase antes de importar el componente: la cadena de imports pide
// supabaseUrl al cargarse (mismo patrón que PedidoCard.deuda.test.tsx).
vi.mock('../../../lib/supabase', () => ({
  supabase: {
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getUser: vi.fn(() => Promise.resolve({ data: { user: null } })),
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Test' }),
}))

import PedidoCard from '../PedidoCard'
import { AuthDataProvider, type AuthDataContextValue } from '../../../contexts/AuthDataContext'
import { NotificationProvider } from '../../../contexts/NotificationContext'
import type { PedidoDB } from '../../../types'

const JUAN = { id: 'e1', nombre: 'Juan', email: 'juan@x.com' }

const MARCADA = {
  entregado_por: 'e1',
  entregado_at: '2026-11-12T12:14:00Z', // 12/11 09:14 en Argentina
}

function hacerPedido(campos: Partial<PedidoDB> = {}): PedidoDB {
  return {
    id: '1',
    cliente_id: '10',
    estado: 'entregado',
    estado_pago: 'pagado',
    total: 30000,
    monto_pagado: 30000,
    fecha: '2026-11-10',
    fecha_entrega: '2026-11-10T15:00:00Z',
    cliente: { id: '10', nombre_fantasia: 'Kiosco Test', saldo_cuenta: 0 },
    ...campos,
  } as PedidoDB
}

function renderCard(pedido: PedidoDB): void {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const auth = {
    user: { id: 'u1' },
    perfil: { id: 'u1', nombre: 'Test', email: 't@t.com', rol: 'admin' },
    authReady: true,
    isAdmin: true,
    isPreventista: false,
    isTransportista: false,
    isEncargado: false,
    isDeposito: false,
    isAdminOrEncargado: true,
    rolesEfectivos: ['admin'],
    isOnline: true,
    logout: vi.fn(),
    currentSucursalId: 1,
    currentSucursalNombre: 'Test',
  } as AuthDataContextValue

  function Wrapper({ children }: { children: ReactNode }): ReactElement {
    return (
      <QueryClientProvider client={qc}>
        <NotificationProvider>
          <AuthDataProvider value={auth}>{children}</AuthDataProvider>
        </NotificationProvider>
      </QueryClientProvider>
    )
  }

  render(<PedidoCard pedido={pedido} />, { wrapper: Wrapper })
}

async function expandir(): Promise<void> {
  await userEvent.setup().click(screen.getByRole('button', { name: 'Ver detalle del pedido' }))
}

describe('PedidoCard — entrega marcada', () => {
  it('entregado con perfil: la línea 2 dice quién la marcó y cuándo', () => {
    renderCard(hacerPedido({ ...MARCADA, entregado_por_perfil: JUAN }))
    expect(screen.getByText(/marcó Juan, 12\/11 09:14/)).toBeInTheDocument()
  })

  it('entregado sin perfil: dice "marcado el" y no inventa un nombre', () => {
    renderCard(hacerPedido({ ...MARCADA }))
    expect(screen.getByText(/marcado el 12\/11 09:14/)).toBeInTheDocument()
    expect(screen.queryByText(/marcó /)).not.toBeInTheDocument()
  })

  it('entregado anterior al registro (sin entregado_at): no muestra nada', () => {
    renderCard(hacerPedido())
    expect(screen.queryByText(/marcó |marcado el/)).not.toBeInTheDocument()
  })

  it('un pedido pendiente no lo muestra', () => {
    renderCard(hacerPedido({ estado: 'pendiente', fecha_entrega: null, ...MARCADA, entregado_por_perfil: JUAN }))
    expect(screen.queryByText(/marcó |marcado el/)).not.toBeInTheDocument()
  })

  it('el detalle expandido dice "Entrega marcada por {quien} el {cuando}"', async () => {
    renderCard(hacerPedido({ ...MARCADA, entregado_por_perfil: JUAN }))
    await expandir()
    expect(screen.getByText(/Entrega marcada por Juan el 12\/11\/2026/)).toBeInTheDocument()
  })

  it('el detalle sin perfil dice "Entrega marcada el {cuando}"', async () => {
    renderCard(hacerPedido({ ...MARCADA }))
    await expandir()
    expect(screen.getByText(/Entrega marcada el 12\/11\/2026/)).toBeInTheDocument()
  })
})
