/**
 * Aviso de deuda previa en la tarjeta del pedido.
 *
 * EL TEST QUE IMPORTA ES "no deriva la deuda de saldo_cuenta".
 * La primera version de este aviso (PR #530) la derivaba: tomaba el saldo del
 * cliente y le restaba la parte impaga de ESE pedido. `saldo_cuenta` es del
 * presente, asi que lo que quedaba incluia los pedidos POSTERIORES y cada
 * pedido nuevo inflaba el aviso de todas las tarjetas viejas del mismo cliente
 * -- 1.009 de 1.083 avisos eran falsos en produccion. Ahora el numero lo
 * calcula la base (`deuda_previa`, mig 215) y la card solo lo muestra. Si
 * alguien vuelve a mirar `saldo_cuenta` aca, ese test se pone rojo.
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

function hacerPedido(
  campos: { deuda_previa?: number; saldo_cuenta?: number } = {},
): PedidoDB {
  return {
    id: '1',
    cliente_id: '10',
    estado: 'pendiente',
    estado_pago: 'pendiente',
    total: 30000,
    monto_pagado: 0,
    fecha: '2026-09-09',
    deuda_previa: campos.deuda_previa,
    cliente: {
      id: '10',
      nombre_fantasia: 'Kiosco Test',
      saldo_cuenta: campos.saldo_cuenta ?? 0,
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
  it('NO deriva la deuda de saldo_cuenta', () => {
    // El cliente debe $80.000 HOY, pero antes de este pedido no debía nada.
    // Esta es la regresión del PR #530: si la card vuelve a mirar el saldo,
    // muestra deuda que nació después de este pedido.
    renderCard(hacerPedido({ deuda_previa: 0, saldo_cuenta: 80000 }), 'preventista')
    expect(screen.queryByText(/Debe/)).not.toBeInTheDocument()
  })

  it('muestra la deuda previa que calculó la base', () => {
    renderCard(hacerPedido({ deuda_previa: 20000, saldo_cuenta: 50000 }), 'preventista')
    // 20.000 (lo previo), no 50.000 (el saldo de hoy).
    expect(screen.getByText(/Debe/)).toHaveTextContent('20.000')
  })

  it('no avisa cuando la base no mandó el dato', () => {
    // Las queries que no piden la computed column (ruta, hoja de ruta) traen el
    // pedido sin `deuda_previa`. Ausente no es cero-con-aviso: es sin dato.
    renderCard(hacerPedido({ saldo_cuenta: 50000 }), 'preventista')
    expect(screen.queryByText(/Debe/)).not.toBeInTheDocument()
  })

  it.each(['admin', 'encargado', 'preventista'] as const)('lo ve el rol %s', rol => {
    renderCard(hacerPedido({ deuda_previa: 20000 }), rol)
    expect(screen.getByText(/Debe/)).toBeInTheDocument()
  })

  it.each(['transportista', 'deposito'] as const)('lo oculta al rol %s', rol => {
    renderCard(hacerPedido({ deuda_previa: 20000 }), rol)
    expect(screen.queryByText(/Debe/)).not.toBeInTheDocument()
  })

  it('sin conexión habla en pasado y fecha el dato', () => {
    renderCard(hacerPedido({ deuda_previa: 20000 }), 'preventista', {
      isOnline: false,
      saldoActualizadoAt: new Date('2026-09-06T15:00:00Z').getTime(),
    })
    expect(screen.getByText(/Debía/)).toHaveTextContent('6/9')
  })
})
