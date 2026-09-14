/**
 * Editar un pedido tiene que re-cotizar lo que se cotizó solo, y dejar quieto
 * lo que puso una persona.
 *
 * EL HUECO
 * --------
 * Al abrir, el modal marcaba `precioOverride` en todo ítem cuyo precio guardado
 * difiriera del `productos.precio` de hoy. Por construcción eso barría con TODO
 * lo vendido con escala mayorista o con descuento del cliente, y el override
 * tiene dos efectos que ahí no corresponden:
 *
 *   - `resolverPreciosMayorista` lo respeta y deja de re-resolver la escala, así
 *     que bajar de 50 fardos a 5 conservaba el precio de 50.
 *   - `construirOrigenPrecioItems` lo etiqueta 'manual' y
 *     `registrar_origen_precio_items` pisa el origen real: la venta pasa a
 *     comisionarse con otra regla.
 *
 * El dato correcto ya existía: `pedido_items.origen_precio` (mig 148).
 *
 * Se prueba contra el modal real —no contra el util— porque lo que fallaba era
 * el cableado de la apertura, no la matemática de las escalas.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
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

// Condición mayorista sobre el producto 1: a partir de 10 unidades, $200 (lista $250).
const escalaId = 'esc-1'
const pricingMap = new Map([
  ['1', [{
    grupoId: 'g1',
    grupoNombre: 'Fardo Producto 1',
    productoIds: ['1'],
    escalas: [{
      escalaId,
      cantidadMinima: 10,
      precioUnitario: 200,
      etiqueta: 'Fardo',
      minProductosDistintos: 1,
      minimosPorProducto: new Map(),
    }],
  }]],
])

vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: pricingMap, isLoading: false }),
}))

// Promos: el mapa vivo está VACÍO a propósito en el caso del pedido entregado
// (la promo que se aplicó ya se desactivó, y `fetchPromoMap` filtra activo=true).
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false }),
}))

// Mínimo de venta propio del producto 4 (mig 147): se vende de a 3.
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map([['4', 3]]), isLoading: false }),
}))

vi.mock('../../utils/formatters', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../utils/formatters')>()
  return { ...actual, formatPrecio: (v: number) => `$${Number(v).toFixed(2)}` }
})

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' },
  { id: '2', nombre: 'Producto 2', codigo: 'P002', precio: 500, stock: 50, categoria: 'Bebidas' },
  { id: '4', nombre: 'Producto 4', codigo: 'P004', precio: 100, stock: 60, categoria: 'Snacks' },
   
] as any[]

const baseProps = {
  productos,
  isAdmin: true,
  onSave: vi.fn(),
  onSaveItems: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

/** El "-" de cantidad: única clase rounded-l-lg del control. ModalBase usa portal. */
const botonesMenos = () => Array.from(document.body.querySelectorAll('button.rounded-l-lg'))

beforeEach(() => {
  vi.clearAllMocks()
})

describe('ModalEditarPedido — precios que se re-resuelven', () => {
  // 12 unidades a $200: la escala de 10 está activa, y así se guardó.
  const pedidoMayorista = {
    id: 501,
    notas: '',
    estado: 'preparado',
    total: 2400,
    cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
    items: [{
      producto_id: '1',
      cantidad: 12,
      precio_unitario: 200,
      origen_precio: 'mayorista',
      producto: { nombre: 'Producto 1' },
    }],
     
  } as any

  it('vuelve al precio de lista cuando la cantidad cae por debajo de la escala', async () => {
    const user = userEvent.setup()
    render(<ModalEditarPedido {...baseProps} pedido={pedidoMayorista} />)

    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    // Abre cotizado a la escala.
    expect(screen.getByText('$200.00 c/u')).toBeInTheDocument()
    // Y NO se lo trata como precio puesto a mano.
    expect(screen.queryByText('Manual')).not.toBeInTheDocument()

    // 12 → 9: por debajo del mínimo de la escala.
    const menos = botonesMenos()
    expect(menos.length).toBeGreaterThan(0)
    for (let i = 0; i < 3; i++) await user.click(menos[0])

    await waitFor(() => expect(screen.getByText('$250.00 c/u')).toBeInTheDocument())
    expect(screen.queryByText('$200.00 c/u')).not.toBeInTheDocument()
  })

  it('conserva el origen "mayorista" al guardar, en vez de pisarlo con "manual"', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...baseProps} pedido={pedidoMayorista} onSaveItems={onSaveItems} />)

    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    // 12 → 11: sigue arriba del mínimo, sigue siendo mayorista.
    await user.click(botonesMenos()[0])
    await waitFor(() => expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeEnabled())
    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))

    await waitFor(() => expect(onSaveItems).toHaveBeenCalled())
    const [items, origenes] = onSaveItems.mock.calls[0]
    expect(items[0]).toMatchObject({ productoId: '1', cantidad: 11, precioUnitario: 200 })
    expect(origenes).toEqual([
      expect.objectContaining({
        producto_id: '1',
        es_bonificacion: false,
        origen_precio: 'mayorista',
        grupo_precio_escala_id: escalaId,
      }),
    ])
  })

  it('respeta el precio tipeado a mano: origen "manual" no se re-resuelve', async () => {
    const pedidoManual = {
      ...pedidoMayorista,
      id: 502,
      items: [{
        producto_id: '1',
        cantidad: 12,
        precio_unitario: 180,
        origen_precio: 'manual',
        producto: { nombre: 'Producto 1' },
      }],
    }
    render(<ModalEditarPedido {...baseProps} pedido={pedidoManual} />)

    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    expect(screen.getByText('Manual')).toBeInTheDocument()
    // Ni lista ($250) ni escala ($200): el precio que puso la persona.
    expect(screen.getByText('$180.00 c/u')).toBeInTheDocument()
  })
})

describe('ModalEditarPedido — pedido entregado con promo ya desactivada', () => {
  // El pedido se entregó con un regalo de promo. La promo se desactivó después,
  // así que `fetchPromoMap` (activo=true) ya no la trae y las bonificaciones
  // recalculadas dan cero. Eso prendía `itemsModificados` y arrastraba una
  // llamada a `actualizar_pedido_items` que el server rechaza por entregado,
  // llevándose puesto el cambio de fecha que sí era legal.
  const pedidoEntregadoConRegaloHuerfano = {
    id: 777,
    notas: 'Entregado ok',
    estado: 'entregado',
    total: 3000,
    fecha_entrega: '2026-09-01T00:00:00',
    cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
    items: [
      { producto_id: '2', cantidad: 6, precio_unitario: 500, origen_precio: 'lista', producto: { nombre: 'Producto 2' } },
      { producto_id: '4', cantidad: 3, precio_unitario: 0, es_bonificacion: true, promocion_id: '77', producto: { nombre: 'Producto 4' } },
    ],
     
  } as any

  it('guarda la fecha de entrega sin tocar los items', async () => {
    const user = userEvent.setup()
    const onSave = vi.fn()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(
      <ModalEditarPedido
        {...baseProps}
        pedido={pedidoEntregadoConRegaloHuerfano}
        canEditFechaEntrega
        onSave={onSave}
        onSaveItems={onSaveItems}
      />,
    )

    await waitFor(() => expect(screen.getByText(/este pedido ya fue entregado/i)).toBeInTheDocument())

    // El botón no promete "Guardar Todo": no hay items que guardar.
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeInTheDocument()

    // El <label> del modal no está asociado al input (no hay `for`), así que se
    // lo ubica por el bloque que lo contiene.
    const bloqueFecha = screen.getByText('Fecha de Entrega').closest('div') as HTMLElement
    const inputFechaEntrega = within(bloqueFecha).getByDisplayValue('2026-09-01')
    await user.clear(inputFechaEntrega)
    await user.type(inputFechaEntrega, '2026-09-05')

    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0]).toMatchObject({ fechaEntrega: '2026-09-05' })
    // Lo que importa: nunca se intentó el UPDATE que el server rechaza.
    expect(onSaveItems).not.toHaveBeenCalled()
  })
})

describe('ModalEditarPedido — alta de un producto en la edición', () => {
  const pedidoSimple = {
    id: 601,
    notas: '',
    estado: 'preparado',
    total: 500,
    cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
    items: [{ producto_id: '2', cantidad: 1, precio_unitario: 500, origen_precio: 'lista', producto: { nombre: 'Producto 2' } }],
     
  } as any

  const agregarProducto4 = async (user: ReturnType<typeof userEvent.setup>) => {
    await user.click(screen.getByText('Agregar'))
    await user.type(screen.getByPlaceholderText(/buscar producto/i), 'Producto 4')
    await user.click(await screen.findByText('P004 - Stock: 60'))
  }

  it('entra con su mínimo de venta (3), no con cantidad 1', async () => {
    const user = userEvent.setup()
    render(<ModalEditarPedido {...baseProps} pedido={pedidoSimple} />)

    await waitFor(() => expect(screen.getByText('Producto 2')).toBeInTheDocument())
    await agregarProducto4(user)

    const fila = (await screen.findByText('Producto 4')).closest('.p-3') as HTMLElement
    await waitFor(() => {
      // NumberInput es un type="text" a propósito (ver su docstring).
      expect(within(fila).getByLabelText('Cantidad')).toHaveValue('3')
    })
    // Y no queda bloqueando el guardado por incumplir su propio mínimo.
    expect(screen.queryByText(/no cumplen el mínimo de compra/i)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeEnabled()
  })

  it('hereda el descuento del cliente en vez de entrar a precio de lista', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    const pedidoClienteConDescuento = {
      ...pedidoSimple,
      id: 602,
      cliente: {
        id: '9',
        nombre_fantasia: 'Kiosco Sur',
        direccion: 'Calle 1',
        descuento_porcentaje: 10,
        descuentos_categoria: [{ categoria: 'Snacks', descuento_porcentaje: 20 }],
      },
    }
    render(<ModalEditarPedido {...baseProps} pedido={pedidoClienteConDescuento} onSaveItems={onSaveItems} />)

    await waitFor(() => expect(screen.getByText('Producto 2')).toBeInTheDocument())
    await agregarProducto4(user)

    // Producto 4 es Snacks: manda el 20% de la categoría sobre el 10% general.
    await waitFor(() => expect(screen.getByText('$80.00 c/u')).toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalled())

    const [items, origenes] = onSaveItems.mock.calls[0]
    const nuevo = items.find((i: { productoId: string }) => i.productoId === '4')
    expect(nuevo).toMatchObject({ cantidad: 3, precioUnitario: 80 })
    // Y el descuento queda trazado como lo que es (mig 148), no como 'lista'.
    expect(origenes).toContainEqual(
      expect.objectContaining({ producto_id: '4', origen_precio: 'desc_categoria' }),
    )
    // El producto 2 (Bebidas, sin regla propia) cae al general del cliente.
    expect(origenes).toContainEqual(
      expect.objectContaining({ producto_id: '2', origen_precio: 'desc_cliente' }),
    )
  })
})
