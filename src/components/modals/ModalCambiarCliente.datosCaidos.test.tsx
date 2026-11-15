/**
 * FRV-1 (#1559): el cambio de cliente reprecia el pedido con las escalas, promos, mínimos y
 * combos del cliente nuevo. Con una de esas consultas cargando o caída la cuenta sale a precio
 * de lista y el server la acepta (el techo es la lista de hoy). Sólo frenaba `isLoading`.
 * Además, un combo vencido cuya foto no cargó desaparece (FRV-2 en este modal).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PedidoDB, ProductoDB, ClienteDB } from '../../types'

type Q = { data?: unknown; isLoading?: boolean; isError?: boolean; isPaused?: boolean; refetch: () => unknown }

const { estado, refetch } = vi.hoisted(() => {
  const refetchFn = vi.fn()
  const ok = (data: unknown): Q => ({ data, isLoading: false, isError: false, isPaused: false, refetch: refetchFn })
  return {
    refetch: refetchFn,
    estado: { ok, pricing: ok(new Map()), promos: ok(new Map()), minimos: ok(new Map()), combos: ok([]), fotos: ok([]) },
  }
})

vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => estado.combos,
  useFotosCombosPedidoQuery: () => estado.fotos,
  useNombresCombosQuery: () => ({ data: new Map() }),
}))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({ usePricingMapQuery: () => estado.pricing }))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({ usePromoMapQuery: () => estado.promos }))
vi.mock('../../hooks/queries/useProductosQuery', () => ({ useMinimosVentaQuery: () => estado.minimos }))

import ModalCambiarCliente from './ModalCambiarCliente'

const productos = [{ id: 1, nombre: 'Producto 1', precio: 100, stock: 50, categoria: 'BEBIDAS' }] as unknown as ProductoDB[]
const clientes = [
  { id: 10, nombre_fantasia: 'Cliente Actual', direccion: 'Calle 1' },
  { id: 20, nombre_fantasia: 'Cliente Nuevo', direccion: 'Calle 2' },
] as unknown as ClienteDB[]
const pedido = {
  id: 123, cliente_id: 10, fecha: '2026-01-15', total: 1080, estado: 'pendiente', tipo_factura: 'ZZ',
  items: [{ producto_id: 1, cantidad: 12, precio_unitario: 90 }],
} as unknown as PedidoDB

const sinDatos = (extra: Partial<Q> = {}): Q => ({ data: undefined, isLoading: false, isError: false, isPaused: false, refetch, ...extra })

async function elegirNuevo() {
  const user = userEvent.setup()
  const onConfirmar = vi.fn()
  render(<ModalCambiarCliente pedido={pedido} productos={productos} clientes={clientes}
    guardando={false} onConfirmar={onConfirmar} onClose={vi.fn()} />)
  await user.type(screen.getByPlaceholderText(/Buscar por nombre/i), 'Nuevo')
  await user.click(await screen.findByText('Cliente Nuevo'))
  return { user, onConfirmar }
}

beforeEach(() => {
  refetch.mockClear()
  estado.pricing = estado.ok(new Map())
  estado.promos = estado.ok(new Map())
  estado.minimos = estado.ok(new Map())
  estado.combos = estado.ok([])
  estado.fotos = estado.ok([])
})

describe('ModalCambiarCliente — consultas caídas o sin cargar (FRV-1, #1559)', () => {
  it('con todo cargado el cambio se confirma', async () => {
    const { user, onConfirmar } = await elegirNuevo()
    const boton = screen.getByRole('button', { name: /Confirmar cambio/i })
    expect(boton).toBeEnabled()
    expect(screen.queryByText(/No se puede confirmar:/)).not.toBeInTheDocument()
    await user.click(boton)
    expect(onConfirmar).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['las escalas mayoristas', 'pricing'],
    ['los mínimos de venta', 'minimos'],
    ['los combos', 'combos'],
    ['los combos del pedido', 'fotos'],
  ] as const)('con %s en error, Confirmar queda bloqueado, dice por qué y no manda nada', async (nombre, consulta) => {
    estado[consulta] = sinDatos({ isError: true })
    const { user, onConfirmar } = await elegirNuevo()

    const boton = screen.getByRole('button', { name: /Confirmar cambio/i })
    expect(boton).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent(`No se pudieron cargar ${nombre}`)
    await user.click(boton)
    expect(onConfirmar).not.toHaveBeenCalled()
  })

  it('con las promos caídas (aunque haya un dato viejo) también bloquea', async () => {
    estado.promos = { ...estado.ok(new Map()), isError: true }
    const { onConfirmar } = await elegirNuevo()
    expect(screen.getByRole('button', { name: /Confirmar cambio/i })).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent('No se pudieron cargar las promociones')
    expect(onConfirmar).not.toHaveBeenCalled()
  })

  it('"Reintentar" vuelve a pedir lo que falló', async () => {
    estado.pricing = sinDatos({ isError: true })
    const { user } = await elegirNuevo()
    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(refetch).toHaveBeenCalled()
  })

  it('con la foto de combos todavía cargando bloquea, sin ofrecer Reintentar', async () => {
    estado.fotos = sinDatos({ isLoading: true })
    await elegirNuevo()
    expect(screen.getByRole('button', { name: /Confirmar cambio/i })).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent('Todavía se están cargando los combos del pedido')
    expect(screen.queryByRole('button', { name: 'Reintentar' })).not.toBeInTheDocument()
  })

  it('sin señal y sin la consulta de escalas tampoco se confirma: el cambio es online', async () => {
    estado.pricing = sinDatos({ isPaused: true })
    await elegirNuevo()
    expect(screen.getByRole('button', { name: /Confirmar cambio/i })).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent('Sin conexión')
  })
})
