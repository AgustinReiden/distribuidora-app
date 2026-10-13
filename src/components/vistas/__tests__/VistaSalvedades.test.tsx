/**
 * VistaSalvedades: paginación y filtros en el servidor.
 *
 * Antes la vista traía TODAS las salvedades y filtraba en el cliente, con la
 * fecha comparada en UTC y los KPIs sobre la lista entera cargada. Ahora:
 *  - la lista es una página (20) que pide `useSalvedadesQuery(filtros, pagina)`;
 *  - cambiar cualquier filtro vuelve a la página 1;
 *  - los KPIs salen de `useEstadisticasSalvedadesQuery(filtros)` —la lista
 *    filtrada entera—, no de la página que se mira;
 *  - el encargado ve y resuelve (la RLS de la mig 346 le da toda la sucursal),
 *    pero no anula.
 *
 * Se mockea la capa de datos: lo que se fija es qué filtros y qué página le
 * pide la vista, y qué muestra con lo que vuelve. Los filtros en el builder de
 * PostgREST los fija `useSalvedadesQuery.test.ts`.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { SalvedadItemDBExtended, EstadisticasSalvedades } from '../../../types'
import type { SalvedadesFiltros } from '../../../hooks/queries'
import { fechaLocalISO } from '../../../utils/formatters'

const llamadasLista: Array<{ filtros: SalvedadesFiltros; pagina: number }> = []
const llamadasKpi: SalvedadesFiltros[] = []
const estado: {
  salvedades: SalvedadItemDBExtended[]
  total: number
  kpis: EstadisticasSalvedades | undefined
  kpisError: boolean
  rol: string
  sucursal: number
} = { salvedades: [], total: 0, kpis: undefined, kpisError: false, rol: 'admin', sucursal: 1 }

vi.mock('../../../hooks/queries', () => ({
  SALVEDADES_PAGE_SIZE: 20,
  useSalvedadesQuery: (filtros: SalvedadesFiltros, pagina: number) => {
    llamadasLista.push({ filtros, pagina })
    return {
      data: estado.salvedades,
      total: estado.total,
      isLoading: false,
      isFetching: false,
      isError: false,
      isSuccess: true,
      isPlaceholderData: false,
      error: null,
      refetch: vi.fn(),
    }
  },
  useEstadisticasSalvedadesQuery: (filtros: SalvedadesFiltros) => {
    llamadasKpi.push(filtros)
    return estado.kpisError
      ? { data: undefined, isError: true, error: new Error('Sin conexión: no se pudieron cargar las salvedades.'), isFetching: false, refetch: vi.fn() }
      : { data: estado.kpis, isError: false, error: null, isFetching: false, refetch: vi.fn() }
  },
  useTransportistasQuery: () => ({
    data: [
      { id: 'uuid-t1', nombre: 'Juan Reparto' },
      { id: 'uuid-t2', nombre: 'Pedro Camión' },
    ],
  }),
  useResolverSalvedadMutation: () => ({ mutateAsync: vi.fn() }),
  useAnularSalvedadMutation: () => ({ mutateAsync: vi.fn() }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { id: 'u1', rol: estado.rol } }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: estado.sucursal }),
}))

vi.mock('../../modals/ModalResolverSalvedad', () => ({ default: () => null }))
vi.mock('../../modals/ModalAnularSalvedad', () => ({ default: () => null }))

import VistaSalvedades from '../VistaSalvedades'

function salvedad(n: number, extra: Partial<SalvedadItemDBExtended> = {}): SalvedadItemDBExtended {
  return {
    id: String(n),
    pedido_id: String(1000 + n),
    producto_nombre: `Producto ${n}`,
    cliente_nombre: `Cliente ${n}`,
    transportista_nombre: 'Juan Reparto',
    motivo: 'faltante_stock',
    estado_resolucion: 'pendiente',
    cantidad_original: 10,
    cantidad_afectada: 2,
    cantidad_entregada: 8,
    monto_afectado: 100,
    created_at: '2026-10-10T12:00:00Z',
    ...extra,
  } as unknown as SalvedadItemDBExtended
}

const ultima = () => llamadasLista[llamadasLista.length - 1]
const ultimoKpi = () => llamadasKpi[llamadasKpi.length - 1]

beforeEach(() => {
  llamadasLista.length = 0
  llamadasKpi.length = 0
  estado.salvedades = Array.from({ length: 20 }, (_, i) => salvedad(i + 1))
  estado.total = 57
  estado.kpis = {
    total: 57, pendientes: 50, resueltas: 5, anuladas: 2,
    monto_total_afectado: 5700, monto_pendiente: 5000,
  }
  estado.kpisError = false
  estado.rol = 'admin'
  estado.sucursal = 1
})

describe('VistaSalvedades — paginación server-side', () => {
  it('arranca en la página 1 con sólo pendientes y muestra el paginador con el total', () => {
    render(<VistaSalvedades />)

    expect(ultima().pagina).toBe(1)
    expect(ultima().filtros).toMatchObject({ estado: 'pendientes', motivo: 'todos', transportistaId: null })
    expect(screen.getAllByText(/^Producto \d+$/)).toHaveLength(20)
    // 57 salvedades de a 20 → 3 páginas.
    expect(screen.getByRole('button', { name: 'Página 3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página 4' })).not.toBeInTheDocument()
    expect(screen.getByText('57 salvedades')).toBeInTheDocument()
  })

  it('pasar de página le pide esa página al servidor, con los mismos filtros', async () => {
    render(<VistaSalvedades />)
    const antes = ultima().filtros

    await userEvent.click(screen.getByRole('button', { name: 'Página 2' }))

    expect(ultima().pagina).toBe(2)
    expect(ultima().filtros).toEqual(antes)
  })

  it('una página que dejó de existir (se resolvió lo último) retrocede a la última que existe', async () => {
    const { rerender } = render(<VistaSalvedades />)
    await userEvent.click(screen.getByRole('button', { name: 'Página 3' }))
    expect(ultima().pagina).toBe(3)

    // Quedaron 40: la página 3 ya no existe.
    estado.total = 40
    estado.salvedades = []
    rerender(<VistaSalvedades />)

    expect(ultima().pagina).toBe(2)
  })
})

describe('VistaSalvedades — cambiar un filtro vuelve a la página 1', () => {
  async function irAPagina3() {
    render(<VistaSalvedades />)
    await userEvent.click(screen.getByRole('button', { name: 'Página 3' }))
    expect(ultima().pagina).toBe(3)
  }

  it('motivo', async () => {
    await irAPagina3()
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Motivo' }), 'producto_danado')
    expect(ultima()).toMatchObject({ pagina: 1, filtros: { motivo: 'producto_danado' } })
  })

  it('estado', async () => {
    await irAPagina3()
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Estado' }), 'todas')
    expect(ultima()).toMatchObject({ pagina: 1, filtros: { estado: 'todas' } })
  })

  it('transportista: el selector lista los transportistas y filtra por el id del pedido', async () => {
    await irAPagina3()
    const selector = screen.getByRole('combobox', { name: 'Transportista' })
    expect(within(selector).getByRole('option', { name: 'Pedro Camión' })).toBeInTheDocument()

    await userEvent.selectOptions(selector, 'uuid-t2')
    expect(ultima()).toMatchObject({ pagina: 1, filtros: { transportistaId: 'uuid-t2' } })

    await userEvent.selectOptions(selector, '')
    expect(ultima().filtros.transportistaId).toBeNull()
  })

  it('período: un preset y una fecha escrita a mano', async () => {
    await irAPagina3()
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Estado' }), 'todas')
    await userEvent.click(screen.getByRole('button', { name: 'Página 2' }))
    expect(ultima().pagina).toBe(2)

    await userEvent.click(screen.getByRole('button', { name: 'Hoy' }))
    const hoy = fechaLocalISO()
    expect(ultima()).toMatchObject({ pagina: 1, filtros: { desde: hoy, hasta: hoy } })
    expect(screen.getByRole('button', { name: 'Hoy' })).toHaveAttribute('aria-pressed', 'true')

    await userEvent.click(screen.getByRole('button', { name: 'Página 2' }))
    fireEvent.change(screen.getByLabelText('Desde'), { target: { value: '2026-09-01' } })
    expect(ultima()).toMatchObject({ pagina: 1, filtros: { desde: '2026-09-01' } })
    // Una fecha a mano ya no es ningún preset.
    expect(screen.getByRole('button', { name: 'Hoy' })).toHaveAttribute('aria-pressed', 'false')
  })
})

describe('VistaSalvedades — período', () => {
  it('con "Solo pendientes" no hay selector de período (una pendiente vieja no se esconde)', () => {
    render(<VistaSalvedades />)
    expect(screen.queryByRole('group', { name: 'Período' })).not.toBeInTheDocument()
  })

  it('con "Todas" aparece con los presets hoy / 7 días / 30 días / este mes; arranca en 7 días', async () => {
    render(<VistaSalvedades />)
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Estado' }), 'todas')

    const grupo = screen.getByRole('group', { name: 'Período' })
    expect(within(grupo).getAllByRole('button').map(b => b.textContent)).toEqual(['Hoy', '7 días', '30 días', 'Este mes'])
    expect(within(grupo).getByRole('button', { name: '7 días' })).toHaveAttribute('aria-pressed', 'true')
    expect(ultima().filtros.hasta).toBe(fechaLocalISO())
  })

  it('"Este mes" va del 1 del mes argentino a hoy', async () => {
    render(<VistaSalvedades />)
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Estado' }), 'todas')
    await userEvent.click(screen.getByRole('button', { name: 'Este mes' }))
    const hoy = fechaLocalISO()
    expect(ultima().filtros).toMatchObject({ desde: `${hoy.slice(0, 8)}01`, hasta: hoy })
  })
})

describe('VistaSalvedades — KPIs', () => {
  it('salen de la consulta agregada (toda la lista filtrada), no de la página', () => {
    // La página trae 20 salvedades de 100 = 2.000; los KPIs dicen 57 y 5.700.
    render(<VistaSalvedades />)
    expect(screen.getByTestId('kpi-total')).toHaveTextContent('57')
    expect(screen.getByTestId('kpi-pendientes')).toHaveTextContent('50')
    expect(screen.getByTestId('kpi-resueltas')).toHaveTextContent('5')
    expect(screen.getByTestId('kpi-monto-total')).toHaveTextContent('5.700')
    expect(screen.getByTestId('kpi-monto-pendiente')).toHaveTextContent('5.000')
  })

  it('llevan los mismos filtros que la lista, y la página no cambia los KPIs', async () => {
    render(<VistaSalvedades />)
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Motivo' }), 'otro')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Transportista' }), 'uuid-t1')
    expect(ultimoKpi()).toEqual(ultima().filtros)

    const kpiAntes = ultimoKpi()
    await userEvent.click(screen.getByRole('button', { name: 'Página 2' }))
    expect(ultimoKpi()).toEqual(kpiAntes)
  })
})

describe('VistaSalvedades — por rol', () => {
  async function expandirPrimera() {
    render(<VistaSalvedades />)
    await userEvent.click(screen.getByText('Producto 1'))
  }

  it('encargado: ve las salvedades que le da el servidor, con el nombre del transportista, y puede resolver pero no anular', async () => {
    estado.rol = 'encargado'
    await expandirPrimera()

    // La vista no filtra por rol: muestra lo que devuelve la RLS (mig 346).
    expect(screen.getAllByText(/^Producto \d+$/)).toHaveLength(20)
    expect(screen.getAllByText('Juan Reparto').length).toBeGreaterThan(0)
    expect(screen.getByRole('button', { name: /Resolver Salvedad/ })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Anular salvedad/ })).not.toBeInTheDocument()
  })

  it('admin: resuelve y anula', async () => {
    estado.rol = 'admin'
    await expandirPrimera()
    expect(screen.getByRole('button', { name: /Resolver Salvedad/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Anular salvedad/ })).toBeInTheDocument()
  })
})

describe('VistaSalvedades — cambio de sucursal', () => {
  // Los transportistas son por sucursal: el de la sucursal vieja no está en el
  // selector de la nueva, que mostraría "Todos" mientras la consulta sigue
  // filtrando por él (lista vacía, KPIs en 0, sin filtro a la vista).
  it('suelta el transportista y vuelve a la página 1; el resto de los filtros queda', async () => {
    const { rerender } = render(<VistaSalvedades />)
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Motivo' }), 'otro')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Transportista' }), 'uuid-t1')
    await userEvent.click(screen.getByRole('button', { name: 'Página 2' }))
    expect(ultima()).toMatchObject({ pagina: 2, filtros: { transportistaId: 'uuid-t1', motivo: 'otro' } })

    estado.sucursal = 2
    rerender(<VistaSalvedades />)

    expect(ultima()).toMatchObject({ pagina: 1, filtros: { transportistaId: null, motivo: 'otro' } })
    expect(ultimoKpi().transportistaId).toBeNull()
  })
})

describe('VistaSalvedades — KPIs que fallan', () => {
  it('si la consulta de KPIs falla, se avisa en lugar de las tarjetas (y la lista sigue)', () => {
    estado.kpisError = true
    render(<VistaSalvedades />)
    expect(screen.queryByTestId('kpi-total')).not.toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent(/No se pudo calcular el resumen/)
    expect(screen.getAllByText(/^Producto \d+$/)).toHaveLength(20)
  })
})
