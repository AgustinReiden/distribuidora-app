/**
 * No se guarda un pedido mientras cargan sus sustituciones de regalo (#950).
 *
 * `usePedidoSustitucionesQuery` arranca con `[]`: sin sustituciones, las
 * bonificaciones se recalculan con el producto y la cantidad ORIGINALES, y
 * `bonifDifierenDeDB` marcaba el pedido como modificado porque lo guardado tiene
 * el sustituto. Guardar en ese momento reinsertaba el regalo sin la sustitución
 * (un regalo cambiado por valor, 6 botellas de 3L por 19 de Placer, volvía a 6).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const estado = vi.hoisted(() => ({ cargando: true }))

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
  usePedidoSustitucionesQuery: () => ({ data: undefined, isLoading: estado.cargando, isFetching: estado.cargando }),
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
  { id: '125', nombre: 'Placer 500', codigo: 'P125', precio: 7000, stock: 100, categoria: 'PLACER' },
] as any[]

// El regalo guardado es el sustituto (19 de Placer). Sin promos en el mapa, las
// bonificaciones recalculadas no lo incluyen: difieren de lo guardado.
const pedido = {
  id: 601,
  notas: '',
  estado: 'preparado',
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [
    { producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } },
    { id: '77', producto_id: '125', cantidad: 19, precio_unitario: 0, es_bonificacion: true, promocion_id: '13', producto: { nombre: 'Placer 500' } },
  ],
} as any

const props = {
  productos,
  pedido,
  isAdmin: true,
  onSave: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

beforeEach(() => {
  vi.clearAllMocks()
  estado.cargando = true
})

describe('ModalEditarPedido — sustituciones de regalo cargando (#950)', () => {
  it('mientras cargan, no marca el pedido como modificado ni deja guardar', async () => {
    const onSaveItems = vi.fn()
    render(<ModalEditarPedido {...props} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    const boton = screen.getByRole('button', { name: 'Guardar' })
    expect(boton).toBeDisabled()
    boton.click()
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(props.onSave).not.toHaveBeenCalled()
  })

  it('cuando cargaron, se puede guardar', async () => {
    estado.cargando = false
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    const boton = await screen.findByRole('button', { name: /^Guardar/ })
    await waitFor(() => expect(boton).toBeEnabled())
    await user.click(boton)
    await waitFor(() => expect(props.onSave).toHaveBeenCalledTimes(1))
  })
})
