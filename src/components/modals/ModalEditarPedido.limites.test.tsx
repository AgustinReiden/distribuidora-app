/**
 * B23 de #1603 (decisión del dueño, 18/11): la cantidad de una línea fuera de su límite queda en
 * rojo, con su motivo, y la edición no se guarda. Antes el blur del toque en «Guardar Todo» la
 * recortaba (al mínimo de venta, o al stock disponible) y se guardaba el recorte; vacío guardaba el
 * mínimo de venta.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
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
// El producto se vende de a 6 como mínimo.
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map([['1', 6]]), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

// Stock 20 en góndola + 10 que ya tiene el pedido: 30 disponibles para esta línea.
const productos = [
  { id: '1', nombre: 'Producto de prueba', codigo: 'P001', precio: 250, stock: 20, categoria: 'Snacks' },
] as any[]

const pedido = {
  id: 601,
  notas: '',
  estado: 'en_preparacion',
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco de prueba', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto de prueba' } }],
} as any

const onSaveItems = vi.fn()

async function abrir() {
  const user = userEvent.setup()
  render(
    <ModalEditarPedido productos={productos} pedido={pedido} isAdmin onSave={vi.fn().mockResolvedValue(undefined)}
      onSaveItems={onSaveItems} onClose={vi.fn()} guardando={false} />,
  )
  await waitFor(() => expect(screen.getByText('Producto de prueba')).toBeInTheDocument())
  return user
}

beforeEach(() => {
  vi.clearAllMocks()
  onSaveItems.mockResolvedValue(undefined)
})

describe('ModalEditarPedido — la cantidad fuera de su límite (B23)', () => {
  it.each([
    ['2, con mínimo de venta 6', '2', 'El mínimo de venta es 6'],
    ['50, con 30 disponibles', '50', 'Hay 30 disponibles'],
    ['vacío', '', 'Poné una cantidad'],
  ])('%s: queda en rojo con su motivo y no se guarda', async (_caso, texto, motivo) => {
    const user = await abrir()
    const input = screen.getByLabelText('Cantidad')

    await user.clear(input)
    if (texto) await user.type(input, texto)
    await user.click(screen.getByRole('button', { name: /^Guardar( Todo)?$/ }))

    expect(input).toHaveValue(texto)
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(motivo)
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Guardar( Todo)?$/ })).toBeDisabled()
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('dentro del límite guarda lo tipeado, sin salir antes del campo', async () => {
    const user = await abrir()
    const input = screen.getByLabelText('Cantidad')

    await user.clear(input)
    await user.type(input, '30')
    await user.click(screen.getByRole('button', { name: /^Guardar( Todo)?$/ }))

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(JSON.stringify(onSaveItems.mock.calls[0])).toContain('"cantidad":30')
  })
})
