/**
 * Cambiar el cliente conserva el regalo del pedido y no inventa uno (#1513, PRM-1 y PRM-2 de #1515).
 *
 * - El regalo del pedido nuevo es el del pedido original TAL CUAL: las líneas `es_bonificacion`
 *   de `pedido.items`, en orden de id, con su producto (aunque no sea el default de la promo), su
 *   cantidad y su promocion_id. Lo que recalcule `usePromocionPedido` no se muestra ni se manda.
 * - Una promo de la que el pedido no tiene regalo (alguien la quitó) no vuelve: se le pasa a
 *   `usePromocionPedido` como excluida (4º argumento).
 * - VTA-05: un producto sin precio de lista hoy entra con el precio de la línea del pedido y
 *   `precioOverride: true`.
 *
 * `usePromocionPedido` se mockea para ver con qué se lo llama y para que devuelva un regalo
 * "recalculado" distinto del del pedido: lo que el modal no debe usar.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PedidoDB, ProductoDB, ClienteDB } from '../../types'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

const { estado, usePromocionPedidoMock } = vi.hoisted(() => {
  const estado = {
    promoMap: new Map() as unknown,
    /** Regalo que el hook "recalcularía" y que el modal no tiene que usar. */
    regaloRecalculado: null as null | { productoId: string; cantidad: number; promoId: string },
  }
  const usePromocionPedidoMock = vi.fn((items: Array<Record<string, unknown>>, ..._resto: unknown[]) => {
    const itemsFinales = [
      ...items,
      ...(estado.regaloRecalculado
        ? [{ ...estado.regaloRecalculado, precioUnitario: 0, esBonificacion: true }]
        : []),
    ]
    return {
      itemsFinales,
      isLoading: false,
      promoResolucion: { bonificaciones: [], productosConPromo: new Set<string>() },
      pricingMap: undefined,
      combos: [],
    }
  })
  return { estado, usePromocionPedidoMock }
})

vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: usePromocionPedidoMock,
}))
vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useFotosCombosPedidoQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: estado.promoMap, isLoading: false }),
}))
vi.mock('../../utils/formatters', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../utils/formatters')>()),
  formatPrecio: (v: number) => `$${Number(v).toFixed(2)}`,
}))

import ModalCambiarCliente from './ModalCambiarCliente'

const productos = [
  { id: 1, nombre: 'Jugo Uno', precio: 300, stock: 50 },
  { id: 2, nombre: 'Gaseosa B', precio: 100, stock: 50 },
  { id: 3, nombre: 'Gaseosa A', precio: 100, stock: 50 },
] as unknown as ProductoDB[]

const clientes = [
  { id: 10, nombre_fantasia: 'Cliente Actual' },
  { id: 20, nombre_fantasia: 'Cliente Nuevo' },
] as unknown as ClienteDB[]

const venta = { producto_id: 1, cantidad: 6, precio_unitario: 300 }

function pedidoCon(items: unknown[]): PedidoDB {
  return {
    id: 123, cliente_id: 10, fecha: '2026-01-15', total: 1800, estado: 'pendiente', tipo_factura: 'ZZ', items,
  } as unknown as PedidoDB
}

async function elegirClienteNuevo(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByPlaceholderText(/Buscar por nombre/i), 'Nuevo')
  await user.click(await screen.findByText('Cliente Nuevo'))
}

async function montarYConfirmar(items: unknown[], prods: ProductoDB[] = productos) {
  const user = userEvent.setup()
  const onConfirmar = vi.fn()
  render(
    <ModalCambiarCliente pedido={pedidoCon(items)} productos={prods} clientes={clientes}
      guardando={false} onConfirmar={onConfirmar} onClose={vi.fn()} />,
  )
  await elegirClienteNuevo(user)
  await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))
  expect(onConfirmar).toHaveBeenCalledTimes(1)
  return onConfirmar.mock.calls[0][0] as { items: Array<Record<string, unknown>>; total: number }
}

const excluidasDelHook = (): string[] => {
  const set = usePromocionPedidoMock.mock.lastCall?.[3] as ReadonlySet<string> | undefined
  return [...(set ?? [])]
}

beforeEach(() => {
  usePromocionPedidoMock.mockClear()
  estado.promoMap = new Map()
  estado.regaloRecalculado = null
})

describe('ModalCambiarCliente: el regalo es el del pedido (PRM-1, #1513)', () => {
  it('manda el regalo del pedido (producto B, su cantidad y su promo) y no el recalculado (producto A)', async () => {
    // El hook recalcularía el default de la promo 5 (Gaseosa A, 2); el pedido tiene Gaseosa B x3.
    estado.regaloRecalculado = { productoId: '3', cantidad: 2, promoId: '5' }
    const payload = await montarYConfirmar([
      venta,
      { id: 11, producto_id: 2, cantidad: 3, precio_unitario: 0, es_bonificacion: true, promocion_id: 5 },
    ])

    const regalos = payload.items.filter(i => i.esBonificacion)
    expect(regalos).toEqual([
      expect.objectContaining({ productoId: '2', cantidad: 3, precioUnitario: 0, esBonificacion: true, promocionId: '5' }),
    ])
    // La venta sigue siendo una sola línea y el total no suma el regalo.
    expect(payload.items.filter(i => !i.esBonificacion)).toHaveLength(1)
    expect(payload.total).toBe(1800)
  })

  it('en pantalla se ve el regalo del pedido con "N × Regalo" y no el recalculado', async () => {
    estado.regaloRecalculado = { productoId: '3', cantidad: 2, promoId: '5' }
    const user = userEvent.setup()
    render(
      <ModalCambiarCliente
        pedido={pedidoCon([
          venta,
          { id: 11, producto_id: 2, cantidad: 3, precio_unitario: 0, es_bonificacion: true, promocion_id: 5 },
        ])}
        productos={productos} clientes={clientes} guardando={false} onConfirmar={vi.fn()} onClose={vi.fn()} />,
    )
    await elegirClienteNuevo(user)

    expect(screen.getByText('Gaseosa B')).toBeInTheDocument()
    expect(screen.getByText('3 × Regalo')).toBeInTheDocument()
    expect(screen.queryByText('Gaseosa A')).not.toBeInTheDocument()
    expect(screen.queryByText('2 × Regalo')).not.toBeInTheDocument()
    expect(screen.getByText('La venta sigue siendo de quien la cargó, y el regalo es el mismo.')).toBeInTheDocument()
  })

  it('un reparto de dos líneas de la misma promo viaja en dos líneas, en orden de id (no de texto)', async () => {
    const payload = await montarYConfirmar([
      venta,
      // Fuera de orden a propósito: ordenado como texto, "10" iría antes que "9".
      { id: 10, producto_id: 3, cantidad: 1, precio_unitario: 0, es_bonificacion: true, promocion_id: 5 },
      { id: 9, producto_id: 2, cantidad: 2, precio_unitario: 0, es_bonificacion: true, promocion_id: 5 },
    ])

    const regalos = payload.items.filter(i => i.esBonificacion)
    expect(regalos.map(r => [r.productoId, r.cantidad, r.promocionId])).toEqual([
      ['2', 2, '5'],
      ['3', 1, '5'],
    ])
  })

  it('un regalo sin promocion_id viaja sin promocionId', async () => {
    const payload = await montarYConfirmar([
      venta,
      { id: 11, producto_id: 2, cantidad: 1, precio_unitario: 0, es_bonificacion: true, promocion_id: null },
    ])
    const regalo = payload.items.find(i => i.esBonificacion)
    expect(regalo).toMatchObject({ productoId: '2', cantidad: 1 })
    expect(regalo).not.toHaveProperty('promocionId')
  })
})

describe('ModalCambiarCliente: una promo que el pedido no tenía no vuelve (PRM-2, #1515)', () => {
  const promo13: PromocionActiva = {
    id: '13', nombre: 'Promo 6 + 2', tipo: 'bonificacion', productoIds: ['1'],
    reglas: { cantidad_compra: 6, cantidad_bonificacion: 2 }, productoRegaloId: '3',
    prioridad: 0, regaloMueveStock: true, modoExclusion: 'acumulable',
  }

  it('le pasa a usePromocionPedido la promo sin regalo como excluida y no manda regalo', async () => {
    estado.promoMap = new Map([['1', [promo13]]]) as PromoMap
    // El hook (que acá ignora las excluidas) devolvería el regalo: igual no tiene que viajar.
    estado.regaloRecalculado = { productoId: '3', cantidad: 2, promoId: '13' }
    const payload = await montarYConfirmar([venta])

    expect(usePromocionPedidoMock.mock.lastCall?.[3]).toBeInstanceOf(Set)
    expect(excluidasDelHook()).toEqual(['13'])
    expect(payload.items.some(i => i.esBonificacion)).toBe(false)
    // Ni tampoco una línea del regalo recalculado (producto 3) disfrazada de venta.
    expect(payload.items.map(i => i.productoId)).toEqual(['1'])
  })

  it('si el pedido sí tiene el regalo de esa promo, no la excluye', async () => {
    estado.promoMap = new Map([['1', [promo13]]]) as PromoMap
    const payload = await montarYConfirmar([
      venta,
      { id: 11, producto_id: 3, cantidad: 2, precio_unitario: 0, es_bonificacion: true, promocion_id: 13 },
    ])

    expect(excluidasDelHook()).toEqual([])
    expect(payload.items.filter(i => i.esBonificacion)).toHaveLength(1)
  })

  it('una promo que no llega a disparar con las líneas del pedido no se excluye', async () => {
    estado.promoMap = new Map([['1', [promo13]]]) as PromoMap
    await montarYConfirmar([{ producto_id: 1, cantidad: 5, precio_unitario: 300 }])

    expect(excluidasDelHook()).toEqual([])
  })
})

describe('ModalCambiarCliente: producto sin precio de lista hoy (VTA-05, #1513)', () => {
  it('con precio de lista 0 o null entra con el precio de la línea y precioOverride; con lista, a lista', async () => {
    const sinLista = [
      { id: 1, nombre: 'Jugo Uno', precio: 0, stock: 50 },
      { id: 2, nombre: 'Gaseosa B', precio: null, stock: 50 },
      { id: 3, nombre: 'Gaseosa A', precio: 300, stock: 50 },
    ] as unknown as ProductoDB[]
    const payload = await montarYConfirmar([
      { producto_id: 1, cantidad: 2, precio_unitario: 123 },
      { producto_id: 2, cantidad: 3, precio_unitario: 45 },
      { producto_id: 3, cantidad: 1, precio_unitario: 250 },
    ], sinLista)

    expect(usePromocionPedidoMock.mock.lastCall?.[0]).toEqual([
      { productoId: '1', cantidad: 2, precioUnitario: 123, precioOverride: true },
      { productoId: '2', cantidad: 3, precioUnitario: 45, precioOverride: true },
      { productoId: '3', cantidad: 1, precioUnitario: 300 },
    ])
    // Y lo que viaja es ese precio, no 0.
    expect(payload.items.map(i => [i.productoId, i.precioUnitario])).toEqual([['1', 123], ['2', 45], ['3', 300]])
    expect(payload.total).toBe(2 * 123 + 3 * 45 + 300)
  })

  it('una línea de combo sin precio de lista entra con el precio sin combo', async () => {
    const sinLista = [{ id: 1, nombre: 'Jugo Uno', precio: 0, stock: 50 }] as unknown as ProductoDB[]
    await montarYConfirmar([
      { producto_id: 1, cantidad: 2, precio_unitario: 80, combo_id: 7, precio_sin_combo_unitario: 100 },
    ], sinLista)

    expect(usePromocionPedidoMock.mock.lastCall?.[0]).toEqual([
      { productoId: '1', cantidad: 2, precioUnitario: 100, precioOverride: true },
    ])
  })
})
