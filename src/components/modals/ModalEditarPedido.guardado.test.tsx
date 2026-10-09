/**
 * Guardar Todo no se puede disparar dos veces (#826).
 *
 * EL HUECO
 * --------
 * `guardando` (prop) recién se prendía en `handleGuardarEdicion`, después de
 * `await onSaveItems`. Durante la RPC de items el botón seguía habilitado: el
 * pedido 6414 registró 3 llamadas a `actualizar_pedido_items` en 2 s por un solo
 * guardado. El guard vive en el modal (ref + estado) desde el click.
 *
 * Sobre "Anterior muestra el total nuevo": no se reprodujo. `Anterior` sale de
 * `pedido.total` y el container no reemplaza `pedidoEditando` al guardar items
 * (es un snapshot), así que con el modal abierto muestra el total viejo. El
 * último test fija ese comportamiento y que un pedido sin tocar no lo muestre.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

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

vi.mock('../../utils/formatters', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../utils/formatters')>()
  return { ...actual, formatPrecio: (v: number) => `$${Number(v).toFixed(2)}` }
})

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' },
] as any[]

const pedido = {
  id: 601,
  notas: '',
  estado: 'en_preparacion',
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
} as any

const botonesMenos = () => Array.from(document.body.querySelectorAll('button.rounded-l-lg'))

const baseProps = {
  productos,
  pedido,
  isAdmin: true,
  onSave: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

beforeEach(() => vi.clearAllMocks())

describe('ModalEditarPedido — guardado', () => {
  it('dos clicks rápidos en Guardar Todo disparan UNA sola llamada y el botón se bloquea desde el click', async () => {
    const user = userEvent.setup()
    let liberar!: () => void
    const onSaveItems = vi.fn(() => new Promise<void>(res => { liberar = res }))
    const onSave = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...baseProps} onSave={onSave} onSaveItems={onSaveItems} />)

    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(botonesMenos()[0])
    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    await waitFor(() => expect(boton).toBeEnabled())

    // Dos clicks en el mismo tick, con la RPC de items todavía en vuelo.
    boton.click()
    boton.click()

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    // `guardando` (prop) sigue en false: el bloqueo es del modal, no del container.
    await waitFor(() => expect(boton).toBeDisabled())
    boton.click()
    expect(onSaveItems).toHaveBeenCalledTimes(1)

    liberar()
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(boton).toBeEnabled())
  })

  it('si el guardado falla, el botón se libera para reintentar', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockRejectedValue(new Error('boom'))
    render(<ModalEditarPedido {...baseProps} onSaveItems={onSaveItems} />)

    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(botonesMenos()[0])
    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    await user.click(boton)

    await waitFor(() => expect(screen.getByText('boom')).toBeInTheDocument())
    await waitFor(() => expect(boton).toBeEnabled())
  })

  it('un pedido sin tocar no muestra "Anterior"; tocado, muestra el total guardado (el viejo)', async () => {
    const user = userEvent.setup()
    render(<ModalEditarPedido {...baseProps} onSaveItems={vi.fn()} />)

    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    expect(screen.queryByText(/Anterior:/)).not.toBeInTheDocument()

    await user.click(botonesMenos()[0])
    await waitFor(() => expect(screen.getByText('Anterior: $2500.00')).toBeInTheDocument())
  })
})
