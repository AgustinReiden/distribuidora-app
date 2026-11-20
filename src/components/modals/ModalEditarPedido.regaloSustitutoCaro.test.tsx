/**
 * H1 de la revisión de C2 (#1592), decisión del dueño del 19/11: «No deja guardar así: o vuelve
 * al regalo original (R) o el pedido queda como está. Este bloqueo no es silencioso sino que se
 * avisa».
 *
 * Promo 2 V → 1 R (mueve stock por línea), R a $ 100. Un admin cambió R×10 por X×1 (X a
 * $ 1.000, otro rubro). Quien no es admin baja la venta de V×20 a V×2: la promo da R×1 ($ 100)
 * y X×1 vale más. El modal lo avisa antes de guardar, con dos salidas: volver el regalo a R
 * (viaja como `regaloOriginal`) o dejar el pedido como estaba (cierra sin guardar). Si el aviso
 * no se pudo dar antes, el rechazo del server (`regalo_sustituto_sobre_tope`) lo muestra igual.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'
import { RechazoDeNegocioError } from '../../utils/rechazoDeNegocio'

// `corte`: lo que contesta `regalo_corte_de_linea` (null: no se pudo leer). `sustError`: la consulta
// de sustituciones falló. `stockR`: el stock del regalo de la promo.
const estado = vi.hoisted(() => ({ mueveStock: true, corte: 10 as number | null, sustError: false, stockR: 500 }))

const { promoMap } = vi.hoisted(() => {
  const promo: PromocionActiva = {
    id: '13',
    nombre: 'Promo 2V1R',
    tipo: 'bonificacion',
    productoIds: ['1'],
    reglas: { cantidad_compra: 2, cantidad_bonificacion: 1 },
    productoRegaloId: '81',
  }
  const map: PromoMap = new Map([['1', [promo]]])
  return { promoMap: map }
})

vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => ({ data: [], isLoading: false }),
  useFotosCombosPedidoQuery: () => ({ data: [] }),
  useNombresCombosQuery: () => ({ data: new Map() }),
}))
vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    rpc: vi.fn(async (fn: string) => (fn === 'regalo_corte_de_linea'
      ? (estado.corte == null ? { data: null, error: { message: 'sin permiso' } } : { data: estado.corte, error: null })
      : { data: null, error: null })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
}))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
const CADENA = '11111111-1111-4111-8111-111111111111'
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoCuposQuery: () => ({ data: undefined }),
  usePromoMapQuery: () => ({ data: promoMap, isLoading: false }),
  usePromocionesListQuery: () => ({
    data: [{ id: 13, nombre: 'Promo 2V1R', regalo_mueve_stock: estado.mueveStock, producto_regalo_id: 81 }],
    isLoading: false,
  }),
  usePedidoSustitucionesQuery: () => (estado.sustError
    ? { data: undefined, isLoading: false, isFetching: false, isError: true, refetch: vi.fn() }
    : {
        data: [{
          id: 1, promocion_id: '13', producto_original_id: '81', producto_sustituto_id: '200',
          cantidad_original: 10, cantidad_sustituta: 1, reparto_id: null,
          cadena_id: '11111111-1111-4111-8111-111111111111', created_at: '2026-11-18T10:00:00Z',
        }],
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

const productosCon = (stockR: number) => [
  { id: '1', nombre: 'Venta V', codigo: 'P001', precio: 250, stock: 100, categoria: 'Almacén' },
  { id: '81', nombre: 'Regalo R', codigo: 'P081', precio: 100, stock: stockR, categoria: 'Bebidas' },
  { id: '200', nombre: 'Sustituto X', codigo: 'P200', precio: 1000, stock: 500, categoria: 'Snacks' },
] as any[]
const productos = productosCon(500)

const pedido = () => ({
  id: 801, notas: '', estado: 'en_preparacion', total: 5000,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [
    { producto_id: '1', cantidad: 20, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Venta V' } },
    {
      id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13', producto_id: '200', cantidad: 1,
      regalo_cadena_id: CADENA, descripcion_regalo: '1 Regalo R [Sustituido por: Sustituto X]',
      producto: { nombre: 'Sustituto X' },
    },
  ],
}) as any

const onClose = vi.fn()
const onSave = vi.fn().mockResolvedValue(undefined)
// Quien no es admin pero puede editar los ítems (el encargado).
const props = { productos, isAdmin: false, canEditItems: true, onSave, onClose, guardando: false }

const bajarVentaA = (n: number): void => {
  const fila = screen.getByText('Venta V').closest('.p-3') as HTMLElement
  const input = within(fila).getByLabelText('Cantidad')
  fireEvent.change(input, { target: { value: String(n) } })
  fireEvent.blur(input)
}

beforeEach(() => {
  vi.clearAllMocks()
  estado.corte = 10
  estado.sustError = false
  estado.stockR = 500
  estado.mueveStock = true
})

describe('ModalEditarPedido — el regalo cambiado no puede valer más que lo que da la promo (H1, decisión del 19/11)', () => {
  it('al bajar la venta lo avisa antes de guardar, con las dos salidas, y Guardar queda frenado', async () => {
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())

    bajarVentaA(2)

    const aviso = await screen.findByRole('alert', { name: 'Regalo cambiado' })
    expect(aviso).toHaveTextContent('el regalo «Sustituto X» × 1 vale más, a precio de lista, que lo que da la promo «Promo 2V1R» ahora («Regalo R» × 1)')
    expect(within(aviso).getByRole('button', { name: 'Volver al regalo original' })).toBeEnabled()
    expect(within(aviso).getByRole('button', { name: 'Dejar el pedido como estaba' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeDisabled()
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('«Volver al regalo original» deja el regalo de la promo con lo que da ahora, y se guarda', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)

    await user.click(await screen.findByRole('button', { name: 'Volver al regalo original' }))
    expect(screen.queryByRole('alert', { name: 'Regalo cambiado' })).not.toBeInTheDocument()
    expect(onSaveItems).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    const bonifs = (onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>).filter(i => i.esBonificacion)
    expect(bonifs).toEqual([expect.objectContaining({
      productoId: '81', cantidad: 1, esBonificacion: true, promocionId: '13', regaloOriginal: true,
    })])
  })

  it('«Dejar el pedido como estaba» cierra sin guardar nada', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)

    await user.click(await screen.findByRole('button', { name: 'Dejar el pedido como estaba' }))
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('si no se pudo avisar antes, el rechazo del server muestra el mismo aviso y la salida guarda', async () => {
    // Promo de fracción: la pantalla no hace la cuenta y lo decide el server.
    estado.mueveStock = false
    const user = userEvent.setup()
    const mensaje = 'Con este cambio, el regalo «Sustituto X» × 1 vale más, a precio de lista, que lo que da la promo «Promo 2V1R» ahora («Regalo R» × 1). Volvé el regalo a su producto o dejá el pedido como estaba; para dejarlo así, el pedido lo tiene que editar un admin. El pedido no se modificó.'
    const onSaveItems = vi.fn()
      .mockRejectedValueOnce(new RechazoDeNegocioError(mensaje, 'regalo_sustituto_sobre_tope', { promociones: [13] }))
      .mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)

    expect(screen.queryByRole('alert', { name: 'Regalo cambiado' })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    const aviso = await screen.findByRole('alert', { name: 'Regalo cambiado' })
    expect(aviso).toHaveTextContent(mensaje)
    expect(onSave).not.toHaveBeenCalled()

    await user.click(within(aviso).getByRole('button', { name: 'Volver al regalo original' }))
    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(2))
    const bonifs = (onSaveItems.mock.calls[1][0] as Array<Record<string, unknown>>).filter(i => i.esBonificacion)
    expect(bonifs).toEqual([expect.objectContaining({ productoId: '81', cantidad: 1, regaloOriginal: true })])
  })

  it('sin bajar lo que da la promo no avisa nada (lo que armó un admin se conserva)', async () => {
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(30)
    expect(screen.queryByRole('alert', { name: 'Regalo cambiado' })).not.toBeInTheDocument()
  })

  it('el admin no tiene tope: no avisa', async () => {
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} isAdmin pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)
    expect(screen.queryByRole('alert', { name: 'Regalo cambiado' })).not.toBeInTheDocument()
  })
})

describe('ModalEditarPedido — segunda revisión de C2 (H2, H1 en dos guardados, H4 y la nota)', () => {
  // H2: el admin ya había bajado la venta a V×10: la línea es X×1 con corte 5 (el eslabón dice 10 → 1).
  const pedidoV10 = () => ({ ...pedido(), items: [{ ...pedido().items[0], cantidad: 10 }, pedido().items[1]] }) as any

  it('H2: con el corte guardado en 5, subir la venta (R×7) no avisa ni frena: decide el server', async () => {
    estado.corte = 5
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedidoV10()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(14)
    await user.click(await screen.findByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(screen.queryByRole('alert', { name: 'Regalo cambiado' })).not.toBeInTheDocument()
  })

  it('H2: sin poder leer el corte guardado no avisa antes ni frena Guardar (decide el server)', async () => {
    estado.corte = null
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)
    expect(screen.queryByRole('alert', { name: 'Regalo cambiado' })).not.toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeEnabled())
  })

  it('H1: si el regalo se cayó (V×1) y vuelve con la cadena, avisa y frena aunque no haya línea guardada', async () => {
    const sinRegalo = { ...pedido(), items: [{ ...pedido().items[0], cantidad: 1 }] } as any
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={sinRegalo} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)
    const aviso = await screen.findByRole('alert', { name: 'Regalo cambiado' })
    expect(aviso).toHaveTextContent('el regalo «Sustituto X» × 1 vale más')
    expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeDisabled()
  })

  it('H4: «Volver al regalo original» sin stock de R lo dice y sólo deja dejar el pedido como estaba', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} productos={productosCon(0)} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)
    await user.click(await screen.findByRole('button', { name: 'Volver al regalo original' }))
    const aviso = screen.getByRole('alert', { name: 'Regalo cambiado' })
    expect(aviso).toHaveTextContent('«Regalo R» no tiene stock para volver al regalo original (hay 0 y hacen falta 1)')
    expect(aviso).toHaveTextContent('Si no hay stock no se regala: dejá el pedido como estaba.')
    expect(within(aviso).queryByRole('button', { name: 'Volver al regalo original' })).not.toBeInTheDocument()
    expect(within(aviso).getByRole('button', { name: 'Dejar el pedido como estaba' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeDisabled()
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('H4: si el server rechaza la vuelta al original (sin stock), el aviso sigue con el motivo', async () => {
    estado.mueveStock = false // la pantalla no hace la cuenta del stock: lo dice el server
    const user = userEvent.setup()
    const onSaveItems = vi.fn()
      .mockRejectedValueOnce(new RechazoDeNegocioError('El regalo cambiado vale más. El pedido no se modificó.', 'regalo_sustituto_sobre_tope', { promociones: [13] }))
      .mockRejectedValueOnce(new Error('«Regalo R»: stock insuficiente (disponible: 0, adicional: 1).'))
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    bajarVentaA(2)
    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await user.click(await screen.findByRole('button', { name: 'Volver al regalo original' }))
    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    const aviso = await screen.findByRole('alert', { name: 'Regalo cambiado' })
    await waitFor(() => expect(aviso).toHaveTextContent('No se pudo volver al regalo original: «Regalo R»: stock insuficiente'))
    expect(within(aviso).getByRole('button', { name: 'Dejar el pedido como estaba' })).toBeEnabled()
    expect(onSaveItems).toHaveBeenCalledTimes(2)
  })

  it('con las sustituciones caídas y el regalo ya sustituido, guardar sólo una nota guarda la nota', async () => {
    estado.sustError = true
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarPedido {...props} pedido={pedido()} onSaveItems={onSaveItems} />)
    await waitFor(() => expect(screen.getByText('Venta V')).toBeInTheDocument())
    await user.type(screen.getByPlaceholderText(/Observaciones importantes/), 'Dejar con el encargado')
    const guardar = screen.getByRole('button', { name: 'Guardar' })
    expect(guardar).toBeEnabled()
    await user.click(guardar)
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSaveItems).not.toHaveBeenCalled()
  })
})
