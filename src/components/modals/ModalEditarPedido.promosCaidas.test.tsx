/**
 * VTA-2 (#1543): editar un pedido con la consulta de promos caída le borraba los regalos.
 *
 * `actualizar_pedido_items` borra y reinserta todas las líneas. Los regalos salen de
 * `bonificacionesCalculadas`, que sin el promoMap queda vacía: viajaban sólo las líneas de
 * venta y el pedido perdía sus regalos. Con la consulta cargando o caída, guardar ÍTEMS no se
 * manda (botón deshabilitado + corte en `doGuardar`); guardar sólo notas o fecha sí.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

const { promo13, estadoPromos, refetchPromos } = vi.hoisted(() => {
  const promo: PromocionActiva = {
    id: '13',
    nombre: 'Promo 10 + 2',
    tipo: 'bonificacion',
    productoIds: ['1'],
    reglas: { cantidad_compra: 10, cantidad_bonificacion: 2 },
    productoRegaloId: '81',
    prioridad: 0,
    regaloMueveStock: true,
    modoExclusion: 'acumulable',
  }
  return {
    promo13: promo,
    estadoPromos: { modo: 'cargadas' as 'cargadas' | 'error' | 'cargando' },
    refetchPromos: vi.fn(),
  }
})

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
  usePromoMapQuery: () => {
    if (estadoPromos.modo === 'error') {
      return { data: undefined, isLoading: false, isError: true, refetch: refetchPromos }
    }
    if (estadoPromos.modo === 'cargando') {
      return { data: undefined, isLoading: true, isError: false, refetch: refetchPromos }
    }
    return { data: new Map([['1', [promo13]]]) as PromoMap, isLoading: false, isError: false, refetch: refetchPromos }
  },
  usePromocionesListQuery: () => ({ data: [{ id: 13, nombre: 'Promo 10 + 2' }], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false, isFetching: false }),
  usePromoCuposQuery: () => ({ data: undefined }),
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
  { id: '81', nombre: 'Manaos 3L', codigo: 'P081', precio: 1000, stock: 500, categoria: 'Bebidas' },
] as any[]

// 10 unidades de la promo 13 (10 + 2) y su regalo guardado.
const pedido = {
  id: 601, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [
    { id: '10', producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } },
    {
      id: '11', producto_id: '81', cantidad: 2, precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
      descripcion_regalo: null, producto: { id: '81', nombre: 'Manaos 3L' },
    },
  ],
} as any

const onSave = vi.fn().mockResolvedValue(undefined)
const onSaveItems = vi.fn().mockResolvedValue(undefined)
const props = { productos, isAdmin: true, onSave, onSaveItems, onClose: vi.fn(), guardando: false }

const botonesMas = () => Array.from(document.body.querySelectorAll('button.rounded-r-lg')) as HTMLButtonElement[]

beforeEach(() => {
  estadoPromos.modo = 'cargadas'
  onSave.mockClear()
  onSaveItems.mockClear()
  refetchPromos.mockClear()
})

describe('ModalEditarPedido — promos caídas o sin cargar (VTA-2, #1543)', () => {
  it('con las promos en error, tocar una cantidad deja Guardar Todo deshabilitado, dice por qué y no manda nada', async () => {
    estadoPromos.modo = 'error'
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    await user.click(botonesMas()[0])

    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    expect(boton).toBeDisabled()
    expect(screen.getByText(/no se pudieron cargar las promociones/i)).toBeInTheDocument()
    await user.click(boton)
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('"Reintentar" vuelve a pedir las promos', async () => {
    estadoPromos.modo = 'error'
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(botonesMas()[0])

    await user.click(await screen.findByRole('button', { name: 'Reintentar' }))
    expect(refetchPromos).toHaveBeenCalledTimes(1)
  })

  it('con las promos todavía cargando tampoco se mandan los ítems', async () => {
    estadoPromos.modo = 'cargando'
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(botonesMas()[0])

    expect(await screen.findByRole('button', { name: 'Guardar Todo' })).toBeDisabled()
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('con las promos en error, guardar sólo una nota sigue funcionando (no toca los ítems)', async () => {
    estadoPromos.modo = 'error'
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    await user.type(screen.getByPlaceholderText(/Observaciones importantes/), 'Dejar con el encargado')
    const guardar = screen.getByRole('button', { name: 'Guardar' })
    expect(guardar).toBeEnabled()
    await user.click(guardar)

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('con las promos cargadas se guarda y el regalo viaja con la venta', async () => {
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    await user.click(botonesMas()[0]) // 11 unidades: la promo 10 + 2 sigue dando 2
    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    await waitFor(() => expect(boton).toBeEnabled())
    expect(screen.queryByText(/no se pudieron cargar las promociones/i)).not.toBeInTheDocument()
    await user.click(boton)

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    const enviados = onSaveItems.mock.calls[0][0] as Array<{ productoId: string; cantidad: number; esBonificacion?: boolean; promocionId?: string }>
    expect(enviados.find(i => !i.esBonificacion)).toMatchObject({ productoId: '1', cantidad: 11 })
    expect(enviados.find(i => i.esBonificacion)).toMatchObject({ productoId: '81', cantidad: 2 })
  })
})
