/**
 * H1 de la revisión de B23 (#1603): la política rige el alta, y un pedido viejo se sigue editando.
 * Un renglón que el pedido ya tenía debajo de un mínimo de venta que subió después no se pone en
 * rojo mientras no baje de lo que tenía: el piso del campo sale de `moqQueBloqueaLaEdicion`, la
 * regla que frena el Guardar (y la del server). Un renglón nuevo en la edición cumple el mínimo de
 * hoy.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

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
// Hoy la Yerba y el Té se venden de a 6; el Azúcar no tiene mínimo.
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map([['1', 6], ['3', 6]]), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  { id: '1', nombre: 'Yerba de prueba', codigo: 'Y1', precio: 100, stock: 50, categoria: 'Almacén' },
  { id: '2', nombre: 'Azúcar de prueba', codigo: 'A1', precio: 80, stock: 50, categoria: 'Almacén' },
  { id: '3', nombre: 'Té de prueba', codigo: 'T1', precio: 60, stock: 50, categoria: 'Almacén' },
] as any[]

// La Yerba se cargó con 3 cuando no tenía mínimo.
const pedido = {
  id: 700,
  notas: '',
  estado: 'en_preparacion',
  total: 1100,
  cliente: { id: '9', nombre_fantasia: 'Kiosco de prueba', direccion: 'Calle 1' },
  items: [
    { producto_id: '1', cantidad: 3, precio_unitario: 100, origen_precio: 'lista', producto: { nombre: 'Yerba de prueba' } },
    { producto_id: '2', cantidad: 10, precio_unitario: 80, origen_precio: 'lista', producto: { nombre: 'Azúcar de prueba' } },
  ],
} as any

const onSaveItems = vi.fn()

async function abrir() {
  const user = userEvent.setup()
  render(
    <ModalEditarPedido productos={productos} pedido={pedido} isAdmin onSave={vi.fn().mockResolvedValue(undefined)}
      onSaveItems={onSaveItems} onClose={vi.fn()} guardando={false} />,
  )
  await waitFor(() => expect(screen.getByText('Yerba de prueba')).toBeInTheDocument())
  return user
}

const cantidadDe = (nombre: string): HTMLElement => {
  const fila = screen.getByText(nombre).closest('div.p-3') as HTMLElement
  return within(fila).getByLabelText('Cantidad')
}
const guardar = (): HTMLElement => screen.getByRole('button', { name: /^Guardar( Todo)?$/ })
const cantidadesGuardadas = (): string => JSON.stringify(onSaveItems.mock.calls[0])

beforeEach(() => {
  vi.clearAllMocks()
  onSaveItems.mockResolvedValue(undefined)
})

describe('ModalEditarPedido — un renglón viejo debajo del mínimo de hoy (H1 de B23)', () => {
  it.each(['3', '4', '5', '6'])('la Yerba (tenía 3, mínimo 6 hoy) con %s se guarda', async texto => {
    const user = await abrir()
    const input = cantidadDe('Yerba de prueba')

    await user.clear(input)
    await user.type(input, texto)
    // Además se cambia otro renglón, para que haya algo que guardar aunque la Yerba quede igual.
    await user.clear(cantidadDe('Azúcar de prueba'))
    await user.type(cantidadDe('Azúcar de prueba'), '12')
    await user.click(guardar())

    expect(input).not.toHaveAttribute('aria-invalid', 'true')
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(cantidadesGuardadas()).toMatch(new RegExp(`"productoId":"1"[^}]*"cantidad":${texto}\\b|"cantidad":${texto}[^}]*"productoId":"1"`))
  })

  it('la Yerba con 2 (menos de lo que tenía) queda en rojo con su motivo y no se guarda', async () => {
    const user = await abrir()
    const input = cantidadDe('Yerba de prueba')

    await user.clear(input)
    await user.type(input, '2')
    await user.click(guardar())

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('El mínimo de venta es 6; este pedido ya tenía 3')
    expect(guardar()).toBeDisabled()
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('un cambio en otro renglón se guarda con la Yerba como estaba', async () => {
    const user = await abrir()

    await user.clear(cantidadDe('Azúcar de prueba'))
    await user.type(cantidadDe('Azúcar de prueba'), '12')
    await user.click(guardar())

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(cantidadesGuardadas()).toContain('"cantidad":3')
    expect(cantidadesGuardadas()).toContain('"cantidad":12')
  })

  it('el «−» de la Yerba baja hasta lo que tenía y el «+» sube de a uno', async () => {
    const user = await abrir()
    const input = cantidadDe('Yerba de prueba')
    const fila = screen.getByText('Yerba de prueba').closest('div.p-3') as HTMLElement
    const [menos] = within(fila).getAllByRole('button').filter(b => b.classList.contains('rounded-l-lg'))

    expect(menos).toBeDisabled()
    await user.click(menos.parentElement!.querySelector('button.rounded-r-lg') as HTMLElement)
    expect(input).toHaveValue('4')
    expect(menos).toBeEnabled()
    await user.click(menos)
    expect(input).toHaveValue('3')
  })

  it('un renglón nuevo en la edición cumple el mínimo de hoy', async () => {
    const user = await abrir()
    await user.click(screen.getByText('Agregar'))
    await user.type(screen.getByPlaceholderText(/buscar producto/i), 'Té')
    await user.click(screen.getByText('Té de prueba'))
    await waitFor(() => expect(screen.queryByPlaceholderText(/buscar producto/i)).not.toBeInTheDocument())
    const input = cantidadDe('Té de prueba')

    await user.clear(input)
    await user.type(input, '3')
    await user.click(guardar())

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(/^El mínimo de venta es 6$/)
    expect(onSaveItems).not.toHaveBeenCalled()
  })
})
