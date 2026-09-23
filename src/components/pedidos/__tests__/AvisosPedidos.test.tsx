/**
 * AvisosPedidos — los paneles de alerta de /pedidos plegados a una línea (#714).
 *
 * Lo que se fija: la línea sólo aparece cuando hay algo que avisar (nunca una
 * cabecera vacía), arranca plegada, y al desplegarse muestra los paneles de
 * siempre con su acción intacta. Los conteos salen de las mismas queries que
 * usan los paneles, con los mismos argumentos.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const usePedidosTrabadosQuery = vi.fn()
const usePedidosSinResolverQuery = vi.fn()

vi.mock('../../../hooks/queries/usePedidosTrabadosQuery', () => ({
  usePedidosTrabadosQuery: (...args: unknown[]) => usePedidosTrabadosQuery(...args),
}))
vi.mock('../../../hooks/queries', () => ({
  usePedidosSinResolverQuery: (...args: unknown[]) => usePedidosSinResolverQuery(...args),
}))

import AvisosPedidos, { type AvisosPedidosProps } from '../AvisosPedidos'

const trabados = [
  { id: '3001', fecha: '2026-06-24', total: 61600, clienteNombre: 'Kiosco villa amalia', transportistaId: 'chofer-1', diasTrabado: 56 },
  { id: '3002', fecha: '2026-07-02', total: 12000, clienteNombre: 'Despensa Mi angel', transportistaId: null, diasTrabado: 48 },
  { id: '3003', fecha: '2026-07-10', total: 9000, clienteNombre: 'Almacen Don Jose', transportistaId: 'chofer-2', diasTrabado: 40 },
  { id: '3004', fecha: '2026-07-11', total: 5000, clienteNombre: 'Maxikiosco', transportistaId: null, diasTrabado: 39 },
]

const sinResolver = [
  { pedidoId: '4001', clienteNombre: 'Almacen La Paz', fecha: '2026-09-18', total: 22800 },
]

function renderAvisos(props: Partial<AvisosPedidosProps> = {}) {
  return render(
    <MemoryRouter>
      <AvisosPedidos enabled={props.enabled ?? true} onVolverAPendiente={props.onVolverAPendiente ?? vi.fn()} />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  usePedidosTrabadosQuery.mockReset()
  usePedidosSinResolverQuery.mockReset()
})

describe('AvisosPedidos', () => {
  it('sin avisos no renderiza nada', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: [], isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: [], isLoading: false })

    const { container } = renderAvisos()

    expect(container).toBeEmptyDOMElement()
  })

  it('mientras carga cualquiera de las dos no renderiza nada', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: undefined, isLoading: true })
    usePedidosSinResolverQuery.mockReturnValue({ data: sinResolver, isLoading: false })
    const trabadosCargando = renderAvisos()
    expect(trabadosCargando.container).toBeEmptyDOMElement()
    trabadosCargando.unmount()

    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: undefined, isLoading: true })
    const noEntregadosCargando = renderAvisos()
    expect(noEntregadosCargando.container).toBeEmptyDOMElement()
  })

  it('con avisos muestra el resumen plegado y no los paneles', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: sinResolver, isLoading: false })

    renderAvisos()

    const resumen = screen.getByRole('button', {
      name: '2 avisos: 4 pedidos trabados en asignado · 1 no entregado',
    })
    expect(resumen).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText(/pedidos quedaron trabados/)).not.toBeInTheDocument()
    expect(screen.queryByText(/sigue sin resolver/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /volver a pendiente/i })).not.toBeInTheDocument()
  })

  it('al hacer clic se despliegan los paneles tal cual son', async () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: sinResolver, isLoading: false })

    renderAvisos()
    const resumen = screen.getByRole('button', { name: /2 avisos/ })
    await userEvent.click(resumen)

    expect(resumen).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText(/4 pedidos quedaron trabados/)).toBeInTheDocument()
    expect(screen.getByText(/no aparecen al armar la ruta/i)).toBeInTheDocument()
    expect(screen.getByText(/1 pedido tuyo sigue sin resolver/)).toBeInTheDocument()

    // aria-controls apunta al bloque que contiene los paneles.
    const bloque = document.getElementById(resumen.getAttribute('aria-controls') ?? '')
    expect(bloque).toContainElement(screen.getByText(/4 pedidos quedaron trabados/))
    expect(bloque).toContainElement(screen.getByText(/1 pedido tuyo sigue sin resolver/))

    await userEvent.click(resumen)
    expect(resumen).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText(/4 pedidos quedaron trabados/)).not.toBeInTheDocument()
  })

  it('el panel desplegado rescata el pedido con el handler recibido', async () => {
    const onVolverAPendiente = vi.fn()
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: [], isLoading: false })

    renderAvisos({ onVolverAPendiente })
    await userEvent.click(screen.getByRole('button', { name: '1 aviso: 4 pedidos trabados en asignado' }))
    await userEvent.click(screen.getAllByRole('button', { name: /volver a pendiente/i })[0])

    expect(onVolverAPendiente).toHaveBeenCalledWith({ id: '3001', transportista_id: 'chofer-1' })
    // Con la lista de no entregados vacía, su panel no deja cabecera.
    expect(screen.queryByText(/sin resolver/)).not.toBeInTheDocument()
  })

  it('con enabled=false los trabados no cuentan aunque la query tenga datos', async () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: sinResolver, isLoading: false })

    renderAvisos({ enabled: false })

    const resumen = screen.getByRole('button', { name: '1 aviso: 1 no entregado' })
    expect(screen.queryByText(/trabado/)).not.toBeInTheDocument()

    await userEvent.click(resumen)
    expect(screen.getByText(/1 pedido tuyo sigue sin resolver/)).toBeInTheDocument()
    expect(screen.queryByText(/quedaron trabados/)).not.toBeInTheDocument()
  })

  it('con enabled=false y sólo trabados no renderiza nada', () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: [], isLoading: false })

    const { container } = renderAvisos({ enabled: false })

    expect(container).toBeEmptyDOMElement()
  })

  // Misma query y mismos argumentos que los paneles => misma queryKey, así que
  // React Query las deduplica y el resumen no agrega requests.
  it('pide las queries con los mismos argumentos que los paneles', async () => {
    usePedidosTrabadosQuery.mockReturnValue({ data: trabados, isLoading: false })
    usePedidosSinResolverQuery.mockReturnValue({ data: sinResolver, isLoading: false })

    renderAvisos({ enabled: true })
    await userEvent.click(screen.getByRole('button', { name: /2 avisos/ }))

    // Resumen + panel desplegado: todas las llamadas son idénticas.
    expect(usePedidosTrabadosQuery.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(usePedidosTrabadosQuery.mock.calls.every(args => args.length === 1 && args[0] === true)).toBe(true)
    expect(usePedidosSinResolverQuery.mock.calls.length).toBeGreaterThanOrEqual(2)
    expect(usePedidosSinResolverQuery.mock.calls.every(args => args.length === 0)).toBe(true)
  })
})
