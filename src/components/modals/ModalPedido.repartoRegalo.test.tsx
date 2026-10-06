/**
 * ModalPedido — repartir el regalo de una promo en varios sabores al CREAR.
 *
 * Caso real: la promo de Manaos 3L bonifica 24 de naranja y el cliente quiere
 * 12 naranja + 12 manzana. El alta manda N líneas de bonificación de la misma
 * promo (`crear_pedido_completo` las acepta, migs 096/242).
 *
 * A diferencia del smoke, acá el hook de precios es el REAL: el reparto lo
 * aplica `orquestarPrecios`, y lo que se asevera es qué ítems de bonificación
 * quedan armados cuando el modal pide guardar. Sólo se mockean las queries que
 * alimentan al hook (promos, escalas, mínimos). El harness reproduce el
 * cableado de `PedidosContainer`: el estado `regalosOverride`, su handler y el
 * `usePromocionPedido` del que salen los ítems que se persisten.
 */
import { useCallback, useState } from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({
    politicas: {
      montoMinimoPedido: 0,
      comisionPctPreventista: 2,
      comisionPctOtros: 0,
      diasAlertaVencimiento: 60,
      diasCriticoVencimiento: 15,
      mostrarSinStock: true,
    },
  }),
}))

vi.mock('../../hooks/queries/useUsuariosQuery', () => ({
  usePreventistasAsignablesQuery: () => ({ data: [] }),
}))

const googleMapsCaido = {
  isLoaded: false,
  isLoading: false,
  error: 'Google Maps no se carga en tests',
  load: async (): Promise<void> => {},
}
vi.mock('../../hooks/useGoogleMaps', () => ({
  useGoogleMaps: () => googleMapsCaido,
  default: () => googleMapsCaido,
  loadGoogleMapsAPI: async (): Promise<void> => {},
}))

// Compra 24 Manaos 3L (cualquier sabor), lleva 12: con 48 de naranja, 24 de regalo.
// `vi.mock` se hoistea: lo que usan las factories se arma en `vi.hoisted`.
const { promoMap } = vi.hoisted(() => {
  const promo: PromocionActiva = {
    id: 'promo-24',
    nombre: 'Manaos 3L 24+12',
    tipo: 'bonificacion',
    productoIds: ['1', '2', '3', '4'],
    reglas: { cantidad_compra: 24, cantidad_bonificacion: 12 },
    productoRegaloId: '1',
  }
  const map: PromoMap = new Map(promo.productoIds.map(id => [id, [promo]]))
  return { promoMap: map }
})

vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: promoMap, isLoading: false }),
}))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: undefined }),
}))

import ModalPedido, { type NuevoPedidoState } from './ModalPedido'
import { usePromocionPedido, type RegaloOverride } from '../../hooks/usePromocionPedido'
import type { ParteReparto } from '../../utils/repartoRegalo'
import { fechaLocalISO } from '../../utils/formatters'
import type { ClienteDB, ProductoDB } from '../../types'

const PRODUCTOS: ProductoDB[] = [
  { id: '1', nombre: 'Manaos Naranja 3L', precio: 1000, stock: 200, categoria: 'Bebidas', categoria_id: 'cat-beb', subcategoria_id: 'sub-3l' },
  { id: '2', nombre: 'Manaos Manzana 3L', precio: 1000, stock: 200, categoria: 'Bebidas', categoria_id: 'cat-beb', subcategoria_id: 'sub-3l' },
  { id: '3', nombre: 'Manaos Pomelo 3L', precio: 1000, stock: 200, categoria: 'Bebidas', categoria_id: 'cat-beb', subcategoria_id: 'sub-3l' },
  // Misma categoría y subcategoría pero desactivado: no se puede regalar.
  { id: '4', nombre: 'Manaos Uva 3L', precio: 1000, stock: 200, categoria: 'Bebidas', categoria_id: 'cat-beb', subcategoria_id: 'sub-3l', activo: false },
  // Misma categoría y subcategoría, fuera de `productoIds` de la promo: la regla
  // es por categoría, no por pertenecer a la promo (#950).
  { id: '5', nombre: 'Manaos Limon 3L', precio: 1000, stock: 200, categoria: 'Bebidas', categoria_id: 'cat-beb', subcategoria_id: 'sub-3l' },
  // Misma categoría, OTRA subcategoría (otro empaque): no se ofrece.
  { id: '8', nombre: 'Manaos Naranja 500cc', precio: 400, stock: 200, categoria: 'Bebidas', categoria_id: 'cat-beb', subcategoria_id: 'sub-500' },
  // Otra categoría: no se ofrece.
  { id: '9', nombre: 'Papas Fritas 100g', precio: 500, stock: 200, categoria: 'Snacks', categoria_id: 'cat-snk' },
]

const CLIENTES: ClienteDB[] = [
  {
    id: '10',
    nombre_fantasia: 'Kiosco El Sol',
    razon_social: 'El Sol SRL',
    direccion: 'San Martin 100',
    horarios_atencion: '08:00-18:00',
  },
]

interface ItemGuardado {
  productoId: string
  cantidad: number
  precioUnitario: number
  esBonificacion?: boolean
  promoId?: string
}

function Harness({ isAdmin, onGuardarSpy }: { isAdmin: boolean; onGuardarSpy: (items: ItemGuardado[]) => void }) {
  const [pedido] = useState<NuevoPedidoState>({
    clienteId: '10',
    items: [{ productoId: '1', cantidad: 48, precioUnitario: 1000 }],
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0,
    fecha: fechaLocalISO(),
    tipoFactura: 'ZZ',
  })
  // Copia del estado y del handler de PedidosContainer.
  const [regalosOverride, setRegalosOverride] = useState<Record<string, RegaloOverride>>({})
  const onCambiarRegalo = useCallback((promoId: string, partes: ParteReparto[]) => {
    setRegalosOverride(prev => ({
      ...prev,
      [String(promoId)]: {
        partes: partes.map(parte => ({
          productoId: String(parte.productoId ?? ''),
          cantidad: Number(parte.cantidad),
          descripcionRegalo: PRODUCTOS.find(p => String(p.id) === String(parte.productoId))?.nombre,
        })),
      },
    }))
  }, [])
  // De acá salen los ítems que el container persiste (`itemsParaCrear`).
  const { itemsConDescuentoCliente } = usePromocionPedido(
    pedido.items,
    undefined,
    regalosOverride,
    undefined,
    { cliente: CLIENTES[0], productos: PRODUCTOS },
  )

  return (
    <ModalPedido
      productos={PRODUCTOS}
      clientes={CLIENTES}
      categorias={['Bebidas', 'Snacks']}
      nuevoPedido={pedido}
      guardando={false}
      isAdmin={isAdmin}
      isPreventista={!isAdmin}
      currentUserId="u-1"
      regalosOverride={regalosOverride}
      onCambiarRegaloCreacion={onCambiarRegalo}
      onClose={() => {}}
      onGuardar={() => onGuardarSpy(itemsConDescuentoCliente as ItemGuardado[])}
      onClienteChange={() => {}}
      onAgregarItem={() => {}}
      onActualizarCantidad={() => {}}
      onCrearCliente={async () => ({ id: '99' })}
    />
  )
}

function montar(isAdmin = true) {
  const onGuardarSpy = vi.fn()
  render(<Harness isAdmin={isAdmin} onGuardarSpy={onGuardarSpy} />)
  // El cajón del carrito está tapado con aria-hidden hasta abrirlo.
  fireEvent.click(screen.getByRole('button', { name: /unidad|unidades/i }))
  return { onGuardarSpy }
}

const botonConfirmar = () => screen.getByRole('button', { name: 'Confirmar' })

// Las opciones de la lista del combobox (no las de los <select> del cajón).
const opcionesDe = (combo: HTMLElement) => {
  fireEvent.focus(combo)
  return within(screen.getByRole('listbox')).getAllByRole('option').map(o => o.textContent ?? '')
}

const elegir = (combo: HTMLElement, nombre: string) => {
  fireEvent.focus(combo)
  const opcion = within(screen.getByRole('listbox')).getAllByRole('option').find(o => (o.textContent ?? '').startsWith(nombre))
  if (!opcion) throw new Error(`no hay opción para ${nombre}`)
  fireEvent.click(opcion)
}

const cantidad = (n: number, valor: number) =>
  fireEvent.change(screen.getByLabelText(`Cantidad del regalo ${n}`), { target: { value: String(valor) } })

describe('ModalPedido — reparto del regalo en sabores', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('el selector del regalo sólo ofrece operativos de la misma categoría y subcategoría que el regalo original', () => {
    montar()
    const combo = screen.getByRole('combobox', { name: 'Cambiar el producto del regalo' })
    expect(combo).toHaveValue('Manaos Naranja 3L')

    const opciones = opcionesDe(combo)
    expect(opciones).toEqual(['Manaos Limon 3L', 'Manaos Manzana 3L', 'Manaos Naranja 3L', 'Manaos Pomelo 3L'])
    // Otra categoría, otra subcategoría y desactivado: fuera.
    expect(opciones.some(o => o.startsWith('Papas'))).toBe(false)
    expect(opciones.some(o => o.includes('500cc'))).toBe(false)
    expect(screen.getByText(/Sólo productos de la misma categoría \(y subcategoría\)/)).toBeInTheDocument()
    expect(opciones.some(o => o.startsWith('Manaos Uva'))).toBe(false)
  })

  it('repartir 24 en 12 naranja + 12 manzana manda dos líneas de bonificación de la misma promo', () => {
    const { onGuardarSpy } = montar()

    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    // Abrir el reparto ya pide completarlo: no se puede confirmar con una fila vacía.
    expect(botonConfirmar()).toBeDisabled()

    cantidad(1, 12)
    elegir(screen.getByRole('combobox', { name: 'Producto del regalo 2' }), 'Manaos Manzana 3L')
    cantidad(2, 12)

    expect(screen.getByText('Asignado 24 de 24')).toBeInTheDocument()
    expect(botonConfirmar()).toBeEnabled()

    fireEvent.click(botonConfirmar())

    expect(onGuardarSpy).toHaveBeenCalledTimes(1)
    const items = onGuardarSpy.mock.calls[0][0] as ItemGuardado[]
    expect(items.filter(i => !i.esBonificacion)).toEqual([
      expect.objectContaining({ productoId: '1', cantidad: 48 }),
    ])
    expect(items.filter(i => i.esBonificacion).map(i => ({
      productoId: i.productoId, cantidad: i.cantidad, precioUnitario: i.precioUnitario, promoId: i.promoId,
    }))).toEqual([
      { productoId: '1', cantidad: 12, precioUnitario: 0, promoId: 'promo-24' },
      { productoId: '2', cantidad: 12, precioUnitario: 0, promoId: 'promo-24' },
    ])
  })

  it('un reparto que no suma la bonificación no deja confirmar y dice cuánto falta', () => {
    const { onGuardarSpy } = montar()

    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    cantidad(1, 12)
    elegir(screen.getByRole('combobox', { name: 'Producto del regalo 2' }), 'Manaos Manzana 3L')
    cantidad(2, 10)

    expect(screen.getByText(/Asignado 22 de 24/)).toBeInTheDocument()
    const alerta = screen.getAllByRole('alert').find(a => /reparto del regalo/i.test(a.textContent ?? ''))
    expect(alerta).toBeDefined()
    expect(within(alerta!).getByText(/Faltan asignar 2 de 24/)).toBeInTheDocument()
    expect(botonConfirmar()).toBeDisabled()

    fireEvent.click(botonConfirmar())
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  it('quitar la segunda fila vuelve al regalo de un solo producto, con la cantidad de la promo', () => {
    const { onGuardarSpy } = montar()

    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    cantidad(1, 5)
    fireEvent.click(screen.getByRole('button', { name: 'Quitar sabor 2' }))

    expect(screen.queryByText(/Asignado/)).not.toBeInTheDocument()
    expect(botonConfirmar()).toBeEnabled()
    fireEvent.click(botonConfirmar())
    const bonifs = (onGuardarSpy.mock.calls[0][0] as ItemGuardado[]).filter(i => i.esBonificacion)
    expect(bonifs).toEqual([expect.objectContaining({ productoId: '1', cantidad: 24, promoId: 'promo-24' })])
  })

  it('sin ser admin no se puede cambiar ni repartir el regalo', () => {
    montar(false)
    expect(screen.queryByRole('combobox', { name: 'Cambiar el producto del regalo' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /repartir en otro sabor/i })).not.toBeInTheDocument()
    expect(screen.getByText('GRATIS')).toBeInTheDocument()
  })
})
