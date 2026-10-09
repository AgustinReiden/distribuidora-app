/**
 * #1052: Reportes Gerenciales arranca en la sucursal ACTIVA, no en la red.
 *
 * Antes, un usuario con varias sucursales caía en "Red (consolidado)" (id null)
 * apenas abría el reporte, mientras el resto de la app mostraba la sucursal
 * activa. La red sigue siendo una opción elegible del selector, y una URL que la
 * pide (`suc=red`) o que nombra una sucursal sigue mandando.
 *
 * La vista se mockea: acá se prueba qué sucursal le pide el container al reporte.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

const mockReporte = vi.fn()
let mockCtx: Record<string, unknown> = {}

vi.mock('../../hooks/queries', () => ({
  useReporteGerencialQuery: (...args: unknown[]) => {
    mockReporte(...args)
    return { data: undefined, isLoading: false, error: null }
  },
  useAnalisisMensualQuery: () => ({ data: undefined }),
  useMetasGerencialQuery: () => ({ data: undefined }),
  useGuardarMetaMutation: () => ({ mutate: vi.fn(), isPending: false }),
  useCalcularComisionesQuery: () => ({ data: undefined }),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => mockCtx,
}))

vi.mock('../vistas/VistaReportesGerenciales', () => ({
  default: () => <div>vista gerencial</div>,
}))

import ReportesGerencialesContainer from './ReportesGerencialesContainer'

const TUCUMAN = { id: 1, nombre: 'Tucumán' }
const TACO_POZO = { id: 2, nombre: 'Taco Pozo' }

function ctx(over: Record<string, unknown> = {}) {
  mockCtx = {
    sucursales: [TUCUMAN, TACO_POZO],
    hasMultipleSucursales: true,
    loading: false,
    currentSucursalId: 2,
    ...over,
  }
}

async function montar(url = '/reportes-gerenciales') {
  render(
    <MemoryRouter initialEntries={[url]}>
      <ReportesGerencialesContainer />
    </MemoryRouter>,
  )
  await screen.findByText('vista gerencial')
}

/** Las sucursales con las que se pidió el reporte YA habilitado (arg 6 = ready). */
function sucursalesPedidas(): Array<number | null> {
  return mockReporte.mock.calls.filter((c) => c[5] === true).map((c) => c[0] as number | null)
}

describe('ReportesGerencialesContainer › sucursal por defecto (#1052)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('con varias sucursales y sin sucursal en la URL, arranca en la activa y nunca en la red', async () => {
    ctx({ currentSucursalId: 2 })
    await montar()
    await waitFor(() => expect(sucursalesPedidas().length).toBeGreaterThan(0))
    expect(new Set(sucursalesPedidas())).toEqual(new Set([2]))
  })

  it('si la activa es otra, arranca en esa', async () => {
    ctx({ currentSucursalId: 1 })
    await montar()
    await waitFor(() => expect(sucursalesPedidas().length).toBeGreaterThan(0))
    expect(new Set(sucursalesPedidas())).toEqual(new Set([1]))
  })

  it('con la URL en red (suc=red) sigue mostrando la red', async () => {
    ctx({ currentSucursalId: 2 })
    await montar('/reportes-gerenciales?suc=red')
    await waitFor(() => expect(sucursalesPedidas().length).toBeGreaterThan(0))
    expect(new Set(sucursalesPedidas())).toEqual(new Set([null]))
  })

  it('con una sucursal en la URL, esa manda sobre la activa', async () => {
    ctx({ currentSucursalId: 2 })
    await montar('/reportes-gerenciales?suc=1')
    await waitFor(() => expect(sucursalesPedidas().length).toBeGreaterThan(0))
    expect(new Set(sucursalesPedidas())).toEqual(new Set([1]))
  })

  it('una sucursal ajena en la URL cae a la activa, no a la red', async () => {
    ctx({ currentSucursalId: 2 })
    await montar('/reportes-gerenciales?suc=99')
    await waitFor(() => expect(sucursalesPedidas().length).toBeGreaterThan(0))
    expect(new Set(sucursalesPedidas())).toEqual(new Set([2]))
  })

  it('mientras la activa no está resuelta no pide nada (null sería la red)', async () => {
    ctx({ currentSucursalId: null })
    await montar()
    await new Promise((r) => setTimeout(r, 20))
    expect(sucursalesPedidas()).toEqual([])
  })

  it('con una sola sucursal usa esa', async () => {
    ctx({ sucursales: [TACO_POZO], hasMultipleSucursales: false, currentSucursalId: 2 })
    await montar()
    await waitFor(() => expect(sucursalesPedidas().length).toBeGreaterThan(0))
    expect(new Set(sucursalesPedidas())).toEqual(new Set([2]))
  })
})
