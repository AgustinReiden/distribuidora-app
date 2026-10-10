/**
 * La cadena de sustituciones es POR LÍNEA de regalo (#1057).
 *
 *  a. Una promo repartida en dos líneas, y después cada línea cambió de sabor
 *     con el del otro (X→Y la primera, Y→X la segunda): el editor muestra las
 *     dos líneas tal como están y las envía tal como están.
 *  b. Una sola línea A→P (por valor, 6→19) con su clave, más un eslabón viejo de
 *     OTRA clave que parte del mismo original: el editor muestra P×19 y envía
 *     la raíz A×6.
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
  { id: '126', nombre: 'Placer 1L', codigo: 'P126', precio: 9000, stock: 500, categoria: 'PLACER' },
] as any[]

const itemVenta = {
  producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista',
  producto: { nombre: 'Producto 1' },
}

const K1 = '11111111-1111-4111-8111-111111111111'
const K2 = '22222222-2222-4222-8222-222222222222'
const K9 = '99999999-9999-4999-8999-999999999999'
const REPARTO = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

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

/** Sube la venta del producto 1 a `n` con el input de cantidad. */
const cambiarVentaA = (n: number): void => {
  const fila = screen.getByText('Producto 1').closest('.p-3') as HTMLElement
  const input = within(fila).getByLabelText('Cantidad')
  fireEvent.change(input, { target: { value: String(n) } })
  fireEvent.blur(input)
}

beforeEach(() => {
  vi.clearAllMocks()
  estado.sustituciones = []
})

describe('ModalEditarPedido — la cadena es por línea (#1057)', () => {
  it('dos líneas repartidas que se cambiaron entre sí (X→Y, Y→X) se muestran y se guardan como están', async () => {
    // Regalo de 6 repartido en 125 ×4 (línea 1) y 126 ×2 (línea 2); después la
    // línea 1 pasó 125→126 y la línea 2 pasó 126→125. Hoy: 126 ×4 y 125 ×2.
    // Orden DESC por id.
    estado.sustituciones = [
      {
        id: 4, promocion_id: '13', producto_original_id: '126', producto_sustituto_id: '125',
        cantidad_original: 2, cantidad_sustituta: 2, reparto_id: null, cadena_id: K2,
        created_at: '2026-10-04T10:00:00Z',
      },
      {
        id: 3, promocion_id: '13', producto_original_id: '125', producto_sustituto_id: '126',
        cantidad_original: 4, cantidad_sustituta: 4, reparto_id: null, cadena_id: K1,
        created_at: '2026-10-03T10:00:00Z',
      },
      {
        id: 2, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '126',
        cantidad_original: 2, cantidad_sustituta: 2, reparto_id: REPARTO, cadena_id: K2,
        producto_raiz_id: '81', created_at: '2026-10-02T10:00:00Z',
      },
      {
        id: 1, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '125',
        cantidad_original: 4, cantidad_sustituta: 4, reparto_id: REPARTO, cadena_id: K1,
        producto_raiz_id: '81', created_at: '2026-10-02T10:00:00Z',
      },
    ]
    const pedido = {
      id: 601, notas: '', estado: 'en_preparacion', total: 2500,
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
      items: [
        itemVenta,
        {
          id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
          producto_id: '126', cantidad: 4, regalo_cadena_id: K1,
          descripcion_regalo: '1 Botella [Sustituido por: Placer 1L]',
          producto: { nombre: 'Placer 1L' },
        },
        {
          id: '78', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
          producto_id: '125', cantidad: 2, regalo_cadena_id: K2,
          descripcion_regalo: '1 Botella [Sustituido por: Placer 500]',
          producto: { nombre: 'Placer 500' },
        },
      ],
    } as any
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    // Las dos líneas, una Y y una X, con sus cantidades.
    const filas = filasRegalo()
    expect.soft(filas).toHaveLength(2)
    expect.soft(filas.map(([n]) => n).sort()).toEqual(['Placer 1L', 'Placer 500'])
    expect.soft(filas.find(([n]) => n === 'Placer 1L')?.[1]).toMatch(/^REGALO x4/)
    expect.soft(filas.find(([n]) => n === 'Placer 500')?.[1]).toMatch(/^REGALO x2/)

    // Sin tocar nada no está modificado.
    expect.soft(screen.queryByText('Modificado')).not.toBeInTheDocument()

    // 11 unidades siguen dando 6 de regalo: el regalo no cambia, pero hay algo que
    // guardar. Las líneas viajan como están.
    cambiarVentaA(11)

    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))

    const enviados = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    const bonifs = enviados.filter(i => i.esBonificacion)
    expect(bonifs).toHaveLength(2)
    expect(bonifs).toEqual(expect.arrayContaining([
      expect.objectContaining({ productoId: '126', cantidad: 4, promocionId: '13' }),
      expect.objectContaining({ productoId: '125', cantidad: 2, promocionId: '13' }),
    ]))
    expect(bonifs.filter(i => i.productoId === '125')).toHaveLength(1)
  })

  it('una línea A→P (6→19) ignora un eslabón viejo de otra clave: muestra P×19 y envía la raíz A×6', async () => {
    // El eslabón K9 (A→Q) es el más nuevo de la promo, pero no es de esta línea.
    estado.sustituciones = [
      {
        id: 9, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '126',
        cantidad_original: 6, cantidad_sustituta: 10, reparto_id: null, cadena_id: K9,
        created_at: '2026-10-09T10:00:00Z',
      },
      {
        id: 1, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '125',
        cantidad_original: 6, cantidad_sustituta: 19, reparto_id: null, cadena_id: K1,
        created_at: '2026-10-01T10:00:00Z',
      },
    ]
    const pedido = {
      id: 602, notas: '', estado: 'en_preparacion', total: 2500,
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
      items: [
        itemVenta,
        {
          id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
          producto_id: '125', cantidad: 19, regalo_cadena_id: K1,
          descripcion_regalo: '2 Botellas [Sustituido por: Placer 500]',
          producto: { nombre: 'Placer 500' },
        },
      ],
    } as any
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    const filas = filasRegalo()
    expect.soft(filas).toHaveLength(1)
    expect.soft(filas[0][0]).toBe('Placer 500')
    expect.soft(filas[0][1]).toMatch(/^REGALO x19/)
    expect.soft(screen.queryByText('Modificado')).not.toBeInTheDocument()

    // 11 unidades siguen dando 6 de regalo: hay algo que guardar y el regalo no cambia.
    cambiarVentaA(11)

    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))

    const enviados = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    const bonifs = enviados.filter(i => i.esBonificacion)
    expect(bonifs).toHaveLength(1)
    expect(bonifs[0]).toEqual(expect.objectContaining({
      productoId: '81', cantidad: 6, esBonificacion: true, promocionId: '13',
    }))
    expect(bonifs.some(i => i.productoId === '126')).toBe(false)
  })
})
