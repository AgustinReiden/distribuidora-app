/**
 * Regalo sustituido por valor al EDITAR un pedido (#965).
 *
 * Una promo (10 del producto 1 → 6 del regalo A) fue sustituida por el admin:
 * A (81) → Placer 500 (125), cantidad_original 6, cantidad_sustituta 19. La línea
 * guardada es `125 ×19`. El server (trigger) aplica la sustitución cuando recibe
 * el regalo con el producto ORIGINAL y la cantidad de la promo (en unidades del
 * original); si la cantidad cambió, escala por sustituta/original.
 *
 * Contrato esperado:
 *  - el modal MUESTRA (y compara contra la DB) el producto final y su cantidad
 *    convertida;
 *  - el modal ENVÍA el regalo como lo calcula la promo: producto RAÍZ de la
 *    cadena de sustituciones y cantidad de la promo (6 o 12).
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
  { id: '90', nombre: 'Manaos Uva 3L', codigo: 'P090', precio: 1000, stock: 500, categoria: 'Bebidas' },
] as any[]

const itemVenta = {
  producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista',
  producto: { nombre: 'Producto 1' },
}

const pedidoConRegalo = (regalo: Record<string, unknown>) => ({
  id: 601,
  notas: '',
  estado: 'preparado',
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [itemVenta, { id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13', ...regalo }],
}) as any

// Regalo guardado: Placer 500 ×19 (sustituto de A por valor).
const pedidoSustituido = () => pedidoConRegalo({
  producto_id: '125', cantidad: 19,
  descripcion_regalo: '2 Botellas [Sustituido por: Placer 500]',
  producto: { nombre: 'Placer 500' },
})

const sustA_P = {
  id: 1, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '125',
  cantidad_original: 6, cantidad_sustituta: 19, reparto_id: null,
  created_at: '2026-10-01T10:00:00Z',
}

const props = {
  productos,
  isAdmin: true,
  onSave: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

/**
 * Lo que dice la fila del regalo sobre cuánto se regala, p. ej. "REGALO x19 · Promo 10 + 6".
 * Se busca por el texto "REGALO" y no por el nombre: si el modal muestra otro producto,
 * la aserción falla con el valor real en vez de no encontrar la fila.
 */
const textoRegalo = (): string => {
  const filas = screen.getAllByText(/^REGALO x/)
  expect(filas).toHaveLength(1)
  return filas[0].textContent ?? ''
}
/** Nombre del producto que muestra la fila del regalo. */
const nombreRegalo = (): string => {
  const fila = screen.getAllByText(/^REGALO x/)[0].closest('.p-3') as HTMLElement
  return fila.querySelector('p.font-medium')?.textContent ?? ''
}

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

describe('ModalEditarPedido — regalo sustituido por valor (#965)', () => {
  it('un regalo cambiado por valor se muestra con su cantidad y no se marca modificado', async () => {
    estado.sustituciones = [sustA_P]
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedidoSustituido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    // La fila del regalo muestra 19 de Placer 500, no 6.
    expect.soft(nombreRegalo()).toBe('Placer 500')
    expect.soft(textoRegalo()).toMatch(/^REGALO x19/)

    // Sin tocar nada no hay nada que guardar en items.
    expect.soft(screen.queryByText('Modificado')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /^Guardar/ }))
    await waitFor(() => expect(props.onSave).toHaveBeenCalledTimes(1))
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('al cambiar la venta, el regalo sustituido acompaña a la promo y viaja con el producto original', async () => {
    estado.sustituciones = [sustA_P]
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedidoSustituido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    cambiarVentaA(20)

    // 12 * 19 / 6 = 38 de Placer 500 en pantalla.
    expect.soft(nombreRegalo()).toBe('Placer 500')
    expect.soft(textoRegalo()).toMatch(/^REGALO x38/)

    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))

    const enviados = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    const bonifs = enviados.filter(i => i.esBonificacion)
    expect(bonifs).toHaveLength(1)
    expect(bonifs[0]).toEqual(expect.objectContaining({
      productoId: '81', cantidad: 12, esBonificacion: true, promocionId: '13',
    }))
    expect(bonifs.some(i => i.productoId === '125')).toBe(false)
  })

  it('una cadena A→P→Q viaja con la raíz', async () => {
    // Orden DESC por id (#1051): la más nueva primero.
    estado.sustituciones = [
      {
        id: 2, promocion_id: '13', producto_original_id: '125', producto_sustituto_id: '126',
        cantidad_original: 19, cantidad_sustituta: 19, reparto_id: null,
        created_at: '2026-10-02T10:00:00Z',
      },
      sustA_P,
    ]
    const pedido = pedidoConRegalo({
      producto_id: '126', cantidad: 19,
      descripcion_regalo: '2 Botellas [Sustituido por: Placer 1L]',
      producto: { nombre: 'Placer 1L' },
    })
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    cambiarVentaA(20)

    expect.soft(nombreRegalo()).toBe('Placer 1L')
    expect.soft(textoRegalo()).toMatch(/^REGALO x38/)

    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))

    const enviados = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    const bonifs = enviados.filter(i => i.esBonificacion)
    expect(bonifs).toHaveLength(1)
    expect(bonifs[0]).toEqual(expect.objectContaining({
      productoId: '81', cantidad: 12, esBonificacion: true, promocionId: '13',
    }))
    expect(bonifs.some(i => i.productoId === '125' || i.productoId === '126')).toBe(false)
  })

  it('guarda de regresión: un regalo elegido al crear (sin sustituciones) conserva el producto y sigue la cantidad de la promo', async () => {
    estado.sustituciones = []
    const pedido = pedidoConRegalo({
      producto_id: '90', cantidad: 6,
      descripcion_regalo: null,
      producto: { nombre: 'Manaos Uva 3L' },
    })
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    cambiarVentaA(20)

    expect(nombreRegalo()).toBe('Manaos Uva 3L')
    expect(textoRegalo()).toMatch(/^REGALO x12/)

    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))

    const enviados = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    const bonifs = enviados.filter(i => i.esBonificacion)
    expect(bonifs).toHaveLength(1)
    expect(bonifs[0]).toEqual(expect.objectContaining({
      productoId: '90', cantidad: 12, esBonificacion: true, promocionId: '13',
    }))
  })
})
