/**
 * Aviso de deuda previa en la tarjeta del pedido.
 *
 * POR QUE ESTE TEST EXISTE
 * ------------------------
 * El cálculo puro ya está cubierto en src/utils/deudaCliente.test.ts. Lo que se
 * verifica acá es el cableado, que es donde el error sería invisible: que la
 * card le pase `pedido` al util (sin eso, `clientes.saldo_cuenta` incluye lo
 * que ESTE pedido dejó impago y la tarjeta de cualquier pedido sin cobrar
 * diría "debe"), y que el gate por rol se evalúe contra el rol primario.
 *
 * Se monta la card entera a propósito: un test del util no habría atrapado
 * ninguna de las dos cosas.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

// Mock de supabase antes de importar el componente: la cadena de imports pide
// supabaseUrl al cargarse (mismo patrón que VincularTelegramButton.test.tsx).
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
import type { PedidoDB, RolUsuario } from '../../../types'

/** Pedido de 30.000 sin cobrar, del cliente `saldoCuenta`. */
function hacerPedido(saldoCuenta: number, montoPagado = 0): PedidoDB {
  return {
    id: '1',
    cliente_id: '10',
    estado: 'pendiente',
    estado_pago: montoPagado === 0 ? 'pendiente' : 'parcial',
    total: 30000,
    monto_pagado: montoPagado,
    fecha: '2026-09-08',
    cliente: {
      id: '10',
      nombre_fantasia: 'Kiosco Test',
      saldo_cuenta: saldoCuenta,
    },
  } as PedidoDB
}

function renderCard(
  pedido: PedidoDB,
  rol: RolUsuario,
  extra: { isOnline?: boolean; saldoActualizadoAt?: number } = {},
): void {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const auth = {
    user: { id: 'u1' },
    perfil: { id: 'u1', nombre: 'Test', email: 't@t.com', rol },
    authReady: true,
    isAdmin: rol === 'admin',
    isPreventista: rol === 'preventista',
    isTransportista: rol === 'transportista',
    isEncargado: rol === 'encargado',
    isAdminOrEncargado: rol === 'admin' || rol === 'encargado',
    rolesEfectivos: [rol],
    isOnline: extra.isOnline ?? true,
    logout: vi.fn(),
    currentSucursalId: 1,
    currentSucursalNombre: 'Test',
  } as AuthDataContextValue

  function Wrapper({ children }: { children: ReactNode }): ReactElement {
    return (
      <QueryClientProvider client={qc}>
        <AuthDataProvider value={auth}>{children}</AuthDataProvider>
      </QueryClientProvider>
    )
  }

  render(<PedidoCard pedido={pedido} saldoActualizadoAt={extra.saldoActualizadoAt} />, {
    wrapper: Wrapper,
  })
}

describe('PedidoCard — aviso de deuda previa', () => {
  it('NO avisa cuando toda la deuda es este mismo pedido', () => {
    // El trigger ya sumó los 30.000 impagos de este pedido al saldo del cliente.
    // Si la card no los descontara, todo pedido impago mostraría "debe".
    renderCard(hacerPedido(30000), 'preventista')
    expect(screen.queryByText(/Debe/)).not.toBeInTheDocument()
  })

  it('avisa sólo por lo anterior cuando además hay deuda vieja', () => {
    // Saldo 50.000 = 30.000 de este pedido + 20.000 de antes.
    renderCard(hacerPedido(50000), 'preventista')
    expect(screen.getByText(/Debe/)).toHaveTextContent('20.000')
  })

  // El badge NO dice "deuda previa": el monto es la deuda menos ESTE pedido, y
  // eso puede venir de uno posterior. Un cliente con dos impagos ve, en la
  // tarjeta del viejo, el saldo del nuevo.
  it('el badge dice que la deuda es por OTROS pedidos', () => {
    renderCard(hacerPedido(50000), 'preventista')
    expect(screen.getByText(/Debe/)).toHaveTextContent('por otros pedidos')
  })

  it('no avisa cuando el cliente está al día', () => {
    renderCard(hacerPedido(0), 'preventista')
    expect(screen.queryByText(/Debe/)).not.toBeInTheDocument()
  })

  it.each(['admin', 'encargado', 'preventista'] as const)('lo ve el rol %s', rol => {
    renderCard(hacerPedido(50000), rol)
    expect(screen.getByText(/Debe/)).toBeInTheDocument()
  })

  it.each(['transportista', 'deposito'] as const)('lo oculta al rol %s', rol => {
    renderCard(hacerPedido(50000), rol)
    expect(screen.queryByText(/Debe/)).not.toBeInTheDocument()
  })

  it('sin conexión habla en pasado y fecha el dato', () => {
    const alMediodia = new Date('2026-09-06T15:00:00Z').getTime()
    renderCard(hacerPedido(50000), 'preventista', {
      isOnline: false,
      saldoActualizadoAt: alMediodia,
    })
    // "Debía $20.000,00 al 6/9, 12:00" — el número solo sería una afirmación
    // sobre ahora que el teléfono no puede sostener.
    expect(screen.getByText(/Debía/)).toHaveTextContent('6/9')
  })
})
