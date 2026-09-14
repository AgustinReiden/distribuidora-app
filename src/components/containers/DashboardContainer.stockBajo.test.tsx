/**
 * `useProductosStockBajoQuery` (umbral fijo 10) no tenía ningún consumidor —
 * la pantalla de Productos usaba su propio cálculo con `stock_minimo` — y
 * `DashboardContainer` nunca le pasaba `productosStockBajo` a `VistaDashboard`,
 * así que la alerta que ya estaba armada en la vista nunca se veía.
 *
 * Este test fija que el dashboard calcula el stock bajo con el MISMO criterio
 * que `ProductosContainer` (`stock < (stock_minimo || 10)`) y se lo pasa a la
 * vista.
 */
import React from 'react'
import { describe, it, expect, beforeEach } from 'vitest'
import { render } from '@testing-library/react'
import { vi } from 'vitest'

const capturarProps = vi.hoisted(() => vi.fn())

const PRODUCTOS = [
  { id: '1', nombre: 'Bajo con mínimo propio', stock: 3, stock_minimo: 5 },
  { id: '2', nombre: 'Bajo con default 10', stock: 8, stock_minimo: null },
  { id: '3', nombre: 'Justo en el mínimo (no es bajo)', stock: 10, stock_minimo: 10 },
  { id: '4', nombre: 'Stock ok', stock: 50, stock_minimo: 10 },
]

vi.mock('../../hooks/queries', () => ({
  useMetricasQuery: () => ({ data: undefined, isLoading: false, refetch: vi.fn() }),
  useClientesQuery: () => ({ data: [] }),
  useAvanceMetasQuery: () => ({ data: undefined }),
  useProductosQuery: () => ({ data: PRODUCTOS }),
  periodoMensual: () => '2026-09',
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    user: { id: 'u1' },
    isAdmin: true,
    isPreventista: false,
    isEncargado: false,
    authReady: true,
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn() }),
}))

vi.mock('../../hooks/supabase', () => ({
  useBackup: () => ({ exportando: false, descargarJSON: vi.fn() }),
}))

vi.mock('../vistas/VistaDashboard', () => ({
  default: (props: unknown) => {
    capturarProps(props)
    return <div data-testid="vista-dashboard" />
  },
}))

import DashboardContainer from './DashboardContainer'

describe('DashboardContainer › alerta de stock bajo', () => {
  beforeEach(() => {
    capturarProps.mockClear()
  })

  it('calcula productosStockBajo con el mismo criterio que ProductosContainer y se lo pasa a la vista', async () => {
    render(<DashboardContainer />)

    await vi.waitFor(() => expect(capturarProps).toHaveBeenCalled())
    const props = capturarProps.mock.calls[capturarProps.mock.calls.length - 1][0] as {
      productosStockBajo: Array<{ id: string }>
    }

    expect(props.productosStockBajo.map(p => p.id).sort()).toEqual(['1', '2'])
  })
})
