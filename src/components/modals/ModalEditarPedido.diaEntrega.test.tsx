/**
 * El día de la entrega es el argentino (#1344).
 *
 * El server corta el día de una entrega en hora argentina (mig 416b). El modal lo
 * cortaba en la 'T' del timestamptz, que es el día UTC: una entrega del lunes a
 * las 22:30 se mostraba como del martes y se consultaba el control del martes.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const rendiciones = vi.hoisted(() => ({
  consultarControl: vi.fn(),
  controlCerrado: vi.fn(),
}))

vi.mock('../../hooks/supabase/useRendiciones', () => ({
  useRendiciones: () => ({ consultarControl: rendiciones.consultarControl, controlCerrado: rendiciones.controlCerrado }),
}))

// #1191: los combos tienen su propia query (y su sucursal): acá no hay combos.
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
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' },
] as any[]

// Lunes 02/11/2026 a las 22:30 en Argentina: en UTC ya es el martes 03.
const pedido = {
  id: 801,
  notas: '',
  estado: 'entregado',
  total: 2500,
  transportista_id: 'tr-1',
  fecha_entrega: '2026-11-03T01:30:00+00:00',
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
} as any

const campoFechaEntrega = () =>
  screen.getByText(/determina el día de rendición/).closest('div')!.querySelector('input[type="date"]') as HTMLInputElement

function abrir(onSave = vi.fn().mockResolvedValue(undefined)) {
  render(
    <ModalEditarPedido
      productos={productos}
      pedido={pedido}
      isAdmin
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
    />,
  )
  return onSave
}

beforeEach(() => {
  vi.clearAllMocks()
  rendiciones.consultarControl.mockResolvedValue({ controlada: false, controlada_at: null, controlada_por_nombre: null })
  rendiciones.controlCerrado.mockResolvedValue(false)
})

describe('ModalEditarPedido — día de la entrega', () => {
  it('una entrega de las 22:30 es del día argentino, no del día UTC', async () => {
    abrir()
    await waitFor(() => expect(campoFechaEntrega()).toBeInTheDocument())
    expect(campoFechaEntrega().value).toBe('2026-11-02')
  })

  it('al cambiar la fecha consulta el control del día argentino de la entrega', async () => {
    const onSave = abrir()
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaEntrega()).toBeInTheDocument())
    fireEvent.change(campoFechaEntrega(), { target: { value: '2026-11-05' } })
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(rendiciones.consultarControl).toHaveBeenCalledWith('tr-1', '2026-11-02')
    expect(rendiciones.consultarControl).toHaveBeenCalledWith('tr-1', '2026-11-05')
    expect(rendiciones.consultarControl).not.toHaveBeenCalledWith('tr-1', '2026-11-03')
    expect(rendiciones.controlCerrado).toHaveBeenCalledWith('tr-1', '2026-11-02')
  })

  // #1342: reabrir un día es a propósito, desde Rendiciones. El modal ya no ofrece
  // "continuar y anular el control": avisa y no guarda.
  it('si el día de la entrega está controlado, avisa y no guarda', async () => {
    rendiciones.consultarControl.mockImplementation(async (_tr: string, fecha: string) =>
      fecha === '2026-11-02'
        ? { controlada: true, controlada_at: '2026-11-03T10:00:00Z', controlada_por_nombre: 'Ana' }
        : { controlada: false, controlada_at: null, controlada_por_nombre: null })
    rendiciones.controlCerrado.mockImplementation(async (_tr: string, fecha: string) => fecha === '2026-11-02')
    const onSave = abrir()
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaEntrega()).toBeInTheDocument())
    fireEvent.change(campoFechaEntrega(), { target: { value: '2026-11-05' } })
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    expect(await screen.findByText(/primero reabrí ese control desde Rendiciones/)).toBeInTheDocument()
    expect(screen.getByText(/La rendición del 2026-11-02 ya fue controlada por Ana/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Entendido' }))
    await waitFor(() => expect(screen.queryByText(/primero reabrí ese control/)).not.toBeInTheDocument())
    expect(onSave).not.toHaveBeenCalled()
  })

  // Un control en disconformidad no está cerrado: el server lo descarta al mover la
  // entrega, como siempre, y el modal lo avisa y deja seguir (en Rendiciones no hay
  // "Reabrir" para una disconformidad: se resuelve).
  it('si el día tiene un control en disconformidad, pide confirmar y guarda', async () => {
    rendiciones.consultarControl.mockImplementation(async (_tr: string, fecha: string) =>
      fecha === '2026-11-02'
        ? { controlada: true, controlada_at: '2026-11-03T10:00:00Z', controlada_por_nombre: 'Ana' }
        : { controlada: false, controlada_at: null, controlada_por_nombre: null })
    const onSave = abrir()
    const user = userEvent.setup()
    await waitFor(() => expect(campoFechaEntrega()).toBeInTheDocument())
    fireEvent.change(campoFechaEntrega(), { target: { value: '2026-11-05' } })
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    expect(await screen.findByText(/La rendición del 2026-11-02 tiene un control de Ana sin cerrar/)).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(onSave).toHaveBeenCalled())
  })
})
