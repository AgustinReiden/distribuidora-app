/**
 * H1 de la revisión de C7: la edición «guardada a medias». Los renglones se guardan (10 → 25), las fechas
 * o las notas fallan, el modal queda abierto con su error y el container invalidó `productos`: el stock
 * vuelve ya descontado por lo que ESTE pedido acaba de tomar (20 → 5). El modal calculaba el disponible
 * con lo que el pedido tenía AL ABRIR (10) y no con lo ya guardado (25): 5 + 10 = 15, y desde que el rojo
 * mira el límite que cambia (H5), el 25 ya guardado quedaba en rojo con un disponible falso y Guardar
 * deshabilitado: para reintentar había que ACHICAR un pedido que ya tiene 25 guardados.
 * Lo guardado pasa a ser lo «original» del modal: el disponible, el piso de venta, el aviso de cambios y
 * el «Anterior» se miden contra eso.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'

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
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({ usePricingMapQuery: () => ({ data: new Map(), isLoading: false }) }))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoCuposQuery: () => ({ data: undefined }),
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({ useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }) }))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({ usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }) }))

import ModalEditarPedido from './ModalEditarPedido'

const prod = (stock: number) => [{ id: '1', nombre: 'Producto de prueba', codigo: 'P001', precio: 250, stock, categoria: 'Snacks' }] as never[]
// El pedido que tiene el container (`pedidoEditando` es una foto: no se refresca al guardar los renglones).
const pedido = {
  id: 601, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco de prueba', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto de prueba' } }],
} as never
const onSaveItems = vi.fn()
const onSave = vi.fn()
const guardarBtn = () => screen.getByRole('button', { name: /^Guardar( Todo)?$/ }) as HTMLButtonElement
const cant = () => screen.getByLabelText('Cantidad') as HTMLInputElement
const el = (productos: never[]) => (
  <ModalEditarPedido productos={productos} pedido={pedido} isAdmin onSave={onSave}
    onSaveItems={onSaveItems} onClose={vi.fn()} guardando={false} />
)

beforeEach(() => {
  cleanup()
  vi.clearAllMocks()
  onSaveItems.mockResolvedValue(undefined)
})

describe('ModalEditarPedido · edición guardada a medias (H1 de la revisión de C7)', () => {
  it('con los renglones guardados y las fechas rechazadas, el refetch del stock no pone en rojo lo ya guardado y se puede reintentar', async () => {
    onSave.mockRejectedValueOnce(new Error('La fecha del pedido no puede ser de hace más de 7 días')).mockResolvedValue(undefined)
    const user = userEvent.setup()
    const { rerender } = render(el(prod(20)))
    await waitFor(() => screen.getByText('Producto de prueba'))
    await user.clear(cant())
    await user.type(cant(), '25')
    await user.tab()
    await user.click(guardarBtn())

    // Los renglones se guardaron y lo de las fechas falló: el modal sigue abierto con su error.
    await screen.findByText(/más de 7 días/)
    expect(onSaveItems).toHaveBeenCalledTimes(1)
    expect(onSaveItems.mock.calls[0][0].map((i: { cantidad: number }) => i.cantidad)).toEqual([25])

    // El container invalidó ['productos']: el server ya descontó los 15 de más que tomó este pedido.
    rerender(el(prod(5)))

    expect(cant().value).toBe('25')
    expect(cant()).not.toHaveAttribute('aria-invalid', 'true')
    expect(screen.queryByText(/Hay 15 disponibles/)).not.toBeInTheDocument()
    expect(guardarBtn()).toBeEnabled()
    // Lo guardado ya no es un cambio: la fila no queda marcada en amarillo.
    expect(cant().closest('.bg-yellow-50')).toBeNull()

    // El reintento guarda lo que falló (fechas y notas); los renglones ya están guardados.
    await user.click(guardarBtn())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(2))
    expect(onSaveItems).toHaveBeenCalledTimes(1)
  })

  it('lo guardado es el piso: el disponible es el stock de ahora más lo ya guardado (5 + 25), no más lo que había al abrir', async () => {
    onSave.mockRejectedValueOnce(new Error('La fecha del pedido no puede ser de hace más de 7 días'))
    const user = userEvent.setup()
    const { rerender } = render(el(prod(20)))
    await waitFor(() => screen.getByText('Producto de prueba'))
    await user.clear(cant())
    await user.type(cant(), '25')
    await user.tab()
    await user.click(guardarBtn())
    await screen.findByText(/más de 7 días/)
    rerender(el(prod(5)))

    // Con 5 en stock y 25 ya guardados se pueden pedir hasta 30, no 15.
    await user.clear(cant())
    await user.type(cant(), '30')
    await user.tab()
    expect(cant()).not.toHaveAttribute('aria-invalid', 'true')
    await user.clear(cant())
    await user.type(cant(), '31')
    await user.tab()
    expect(cant()).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Hay 30 disponibles')
  })

  it('sin guardado a medias, el stock que baja de fondo sigue poniendo en rojo el valor cargado (H5)', async () => {
    const user = userEvent.setup()
    const { rerender } = render(el(prod(20)))
    await waitFor(() => screen.getByText('Producto de prueba'))
    await user.clear(cant())
    await user.type(cant(), '25')
    await user.tab()
    expect(cant()).not.toHaveAttribute('aria-invalid', 'true')

    rerender(el(prod(5)))
    expect(cant()).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Hay 15 disponibles')
    expect(guardarBtn()).toBeDisabled()
    expect(onSaveItems).not.toHaveBeenCalled()
  })
})
