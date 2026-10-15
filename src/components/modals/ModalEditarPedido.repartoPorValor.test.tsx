/**
 * Un reparto con una parte cambiada por valor sobrevive a la edición (#1090).
 *
 * La promo da 6 y se reparte en X×3 + Y×3. Después la parte Y pasa a Z (3 → 6,
 * por valor) y vuelve a Y (6 → 4). Las líneas suman 7 y la promo da 6: antes el
 * editor daba el reparto por perdido, prendía el guardado solo y mandaba el
 * regalo default ×6. Ahora el reparto se mide en cortes (3 + 3): se muestran las
 * líneas como están (X×3, Y×4), no hay nada que guardar y, si se guarda por otro
 * cambio, viajan X y Y con su corte (×3 cada una), que es lo que el server suma
 * para conservarlas.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

const estado = vi.hoisted(() => ({
  sustituciones: [] as Array<Record<string, unknown>>,
}))

// Compra 10 del producto 1, lleva 6 del regalo 81 (lineal: 20 → 12).
const { promoMap } = vi.hoisted(() => {
  const promo: PromocionActiva = {
    id: '13',
    nombre: 'Promo 10 + 6',
    tipo: 'bonificacion',
    productoIds: ['1'],
    reglas: { cantidad_compra: 10, cantidad_bonificacion: 6 },
    productoRegaloId: '81',
  }
  const map: PromoMap = new Map([['1', [promo]]])
  return { promoMap: map }
})

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
  usePromoMapQuery: () => ({ data: promoMap, isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({
    data: estado.sustituciones,
    isLoading: false,
    isFetching: false,
  }),
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
  { id: '125', nombre: 'Placer 500', codigo: 'P125', precio: 7000, stock: 500, categoria: 'PLACER' },
  { id: '200', nombre: 'Papas 100g', codigo: 'P200', precio: 900, stock: 500, categoria: 'Snacks' },
] as any[]

const itemVenta = {
  producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista',
  producto: { nombre: 'Producto 1' },
}

const KX = '11111111-1111-4111-8111-111111111111'
const KY = '22222222-2222-4222-8222-222222222222'
const REPARTO = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

// Orden DESC por id, como lo trae usePedidoSustitucionesQuery.
const sustitucionesDelIssue = [
  {
    id: 4, promocion_id: '13', producto_original_id: '200', producto_sustituto_id: '125',
    cantidad_original: 6, cantidad_sustituta: 4, reparto_id: null, cadena_id: KY,
    created_at: '2026-10-04T10:00:00Z',
  },
  {
    id: 3, promocion_id: '13', producto_original_id: '125', producto_sustituto_id: '200',
    cantidad_original: 3, cantidad_sustituta: 6, reparto_id: null, cadena_id: KY,
    created_at: '2026-10-03T10:00:00Z',
  },
  {
    id: 2, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '125',
    cantidad_original: 6, cantidad_sustituta: 3, reparto_id: REPARTO, cadena_id: KY,
    producto_raiz_id: '81', created_at: '2026-10-02T10:00:00Z',
  },
  {
    id: 1, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '81',
    cantidad_original: 6, cantidad_sustituta: 3, reparto_id: REPARTO, cadena_id: KX,
    producto_raiz_id: '81', created_at: '2026-10-02T10:00:00Z',
  },
]

const pedidoDelIssue = () => ({
  id: 701, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [
    itemVenta,
    {
      id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
      producto_id: '81', cantidad: 3, regalo_cadena_id: KX,
      descripcion_regalo: '1 Botella',
      producto: { nombre: 'Manaos 3L' },
    },
    {
      id: '78', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
      producto_id: '125', cantidad: 4, regalo_cadena_id: KY,
      descripcion_regalo: '1 Botella [Sustituido por: Placer 500]',
      producto: { nombre: 'Placer 500' },
    },
  ],
}) as any

const props = {
  productos,
  isAdmin: true,
  onSave: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

/** Las filas de regalo del modal como [nombre del producto, texto "REGALO xN ..."]. */
const filasRegalo = (): Array<[string, string]> =>
  screen.getAllByText(/^REGALO x/).map(el => {
    const fila = el.closest('.p-3') as HTMLElement
    return [fila.querySelector('p.font-medium')?.textContent ?? '', el.textContent ?? ''] as [string, string]
  })

/** Cambia la venta del producto 1 a `n` con el input de cantidad. */
const cambiarVentaA = (n: number): void => {
  const fila = screen.getByText('Producto 1').closest('.p-3') as HTMLElement
  const input = within(fila).getByLabelText('Cantidad')
  fireEvent.change(input, { target: { value: String(n) } })
  fireEvent.blur(input)
}

beforeEach(() => {
  vi.clearAllMocks()
  estado.sustituciones = sustitucionesDelIssue
})

describe('ModalEditarPedido — un reparto con una parte cambiada por valor (#1090)', () => {
  it('se muestra como está, sin aviso de reparto perdido y sin nada que guardar', async () => {
    render(<ModalEditarPedido {...props} pedido={pedidoDelIssue()} onSaveItems={vi.fn()} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    const filas = filasRegalo()
    expect.soft(filas).toHaveLength(2)
    expect.soft(filas.find(([n]) => n === 'Manaos 3L')?.[1]).toMatch(/^REGALO x3/)
    expect.soft(filas.find(([n]) => n === 'Placer 500')?.[1]).toMatch(/^REGALO x4/)

    expect.soft(screen.queryByText(/Cambió la cantidad de un regalo repartido en sabores/)).not.toBeInTheDocument()
    // bonifDifierenDeDB en false: el guardado no se prende solo.
    expect.soft(screen.queryByText('Modificado')).not.toBeInTheDocument()
  })

  it('al guardar por otro cambio, las dos partes viajan con su corte (X×3, Y×3)', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedidoDelIssue()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    // 11 unidades siguen dando 6 de regalo: el regalo no cambia, pero hay algo que guardar.
    cambiarVentaA(11)

    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))

    const enviados = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    const bonifs = enviados.filter(i => i.esBonificacion)
    expect(bonifs).toHaveLength(2)
    expect(bonifs).toEqual(expect.arrayContaining([
      expect.objectContaining({ productoId: '81', cantidad: 3, promocionId: '13' }),
      expect.objectContaining({ productoId: '125', cantidad: 3, promocionId: '13' }),
    ]))
  })

  it('si la promo cambia de verdad, el reparto se pierde y se avisa', async () => {
    render(<ModalEditarPedido {...props} pedido={pedidoDelIssue()} onSaveItems={vi.fn()} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    // 20 unidades dan 12 de regalo: 3 + 3 ya no cierra.
    cambiarVentaA(20)

    await waitFor(() =>
      expect(screen.getByText(/Cambió la cantidad de un regalo repartido en sabores/)).toBeInTheDocument())
    const filas = filasRegalo()
    expect(filas).toHaveLength(1)
    expect(filas[0][0]).toBe('Manaos 3L')
    expect(filas[0][1]).toMatch(/^REGALO x12/)
  })
})
