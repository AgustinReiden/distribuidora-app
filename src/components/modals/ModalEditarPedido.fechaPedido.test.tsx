/**
 * El piso y el techo de la fecha del pedido en la edición (#1514, PAT-9-1).
 *
 * Quien no es admin (el encargado) mueve la fecha de hoy hasta los días hacia atrás de la
 * política, como en el alta; el server lo rechaza igual (mig 481). Sólo cuando la cambia: un
 * pedido más viejo que el piso se sigue editando sin tocarle la fecha. El admin no tiene piso
 * ni techo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { fechaLocalISO } from '../../utils/formatters'

const m = vi.hoisted(() => ({ diasAtras: undefined as number | undefined }))

vi.mock('../../hooks/supabase/useRendiciones', () => ({
  useRendiciones: () => ({ consultarControl: vi.fn(), controlCerrado: vi.fn() }),
}))
vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => ({ data: [], isLoading: false }),
  useFotosCombosPedidoQuery: () => ({ data: [] }),
  useNombresCombosQuery: () => ({ data: new Map() }),
}))
vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
}))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoCuposQuery: () => ({ data: undefined }),
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true, diasAtrasFechaPedido: m.diasAtras } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

const haceDias = (n: number) => {
  const d = new Date(fechaLocalISO() + 'T12:00:00')
  d.setDate(d.getDate() - n)
  return fechaLocalISO(d)
}

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' },
] as any[]

function pedidoDel(fecha: string) {
  return {
    id: 901,
    notas: '',
    estado: 'pendiente',
    fecha,
    total: 2500,
    cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
    items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
  } as any
}

const campoFechaPedido = () =>
  screen.getByText('Fecha del Pedido').closest('div')!.querySelector('input[type="date"]') as HTMLInputElement

function abrir({ fecha = haceDias(1), isAdmin = false } = {}) {
  const onSave = vi.fn().mockResolvedValue(undefined)
  render(
    <ModalEditarPedido
      productos={productos}
      pedido={pedidoDel(fecha)}
      isAdmin={isAdmin}
      canEditFechaPedido
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
    />,
  )
  return onSave
}

beforeEach(() => {
  vi.clearAllMocks()
  m.diasAtras = undefined
})

describe('ModalEditarPedido — piso y techo de la fecha del pedido', () => {
  it('el encargado tiene min en el piso (7 por defecto) y max en hoy; el admin, ninguno', async () => {
    abrir()
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    expect(campoFechaPedido()).toHaveAttribute('min', haceDias(7))
    expect(campoFechaPedido()).toHaveAttribute('max', fechaLocalISO())
  })

  it('el admin no tiene min ni max', async () => {
    abrir({ isAdmin: true })
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    expect(campoFechaPedido()).not.toHaveAttribute('min')
    expect(campoFechaPedido()).not.toHaveAttribute('max')
  })

  it('el encargado no puede mover la fecha antes del piso: avisa y no guarda', async () => {
    const onSave = abrir()
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    fireEvent.change(campoFechaPedido(), { target: { value: haceDias(8) } })

    expect(screen.getByRole('alert')).toHaveTextContent('hasta 7 días atrás')
    await user.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onSave).not.toHaveBeenCalled()
  })

  it('el encargado no puede mover la fecha a mañana', async () => {
    const onSave = abrir()
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    fireEvent.change(campoFechaPedido(), { target: { value: haceDias(-1) } })

    expect(screen.getByRole('alert')).toHaveTextContent('no puede ser posterior a hoy')
    await user.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onSave).not.toHaveBeenCalled()
  })

  it('dentro del rango guarda la fecha nueva', async () => {
    m.diasAtras = 2
    const onSave = abrir()
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    fireEvent.change(campoFechaPedido(), { target: { value: haceDias(2) } })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Guardar' }))
    await waitFor(() => expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ fecha: haceDias(2) })))
  })

  it('un pedido más viejo que el piso se sigue editando si no se le toca la fecha', async () => {
    const onSave = abrir({ fecha: haceDias(20) })
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Guardar' }))
    await waitFor(() => expect(onSave).toHaveBeenCalled())
  })

  it('el admin mueve la fecha antes del piso sin aviso', async () => {
    const onSave = abrir({ isAdmin: true })
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaPedido()).toBeInTheDocument())
    fireEvent.change(campoFechaPedido(), { target: { value: haceDias(30) } })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Guardar' }))
    await waitFor(() => expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ fecha: haceDias(30) })))
  })
})
