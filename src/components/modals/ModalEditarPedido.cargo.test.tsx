/**
 * El cargo de envío en la edición (cargo_2_edicion, §1 del diseño).
 *
 * El cargo se reconsidera sólo si la edición CRUZA la franja (debajo / arriba
 * del umbral de envío gratis, con la política vigente). El preventista no
 * decide: el modal le muestra lo que va a pasar y el server lo aplica. El admin
 * y el encargado deciden en un diálogo que se renderiza DENTRO del modal Radix
 * (como hermano en el container quedaría detrás del overlay y fallaría en
 * silencio), y su respuesta viaja como tercer argumento de `onSaveItems`. Si el
 * server igual pide una decisión (la política cambió mientras el modal estaba
 * abierto), el rechazo `requiere_decision_envio` abre el mismo diálogo y se
 * reintenta. Una sucursal que no cobra envío no ve ni el diálogo ni la palabra
 * "Envío", y un pedido sin `cargo_envio_estado` (antes de la migración) es
 * `no_aplica`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { politicasActuales } = vi.hoisted(() => ({
  politicasActuales: { valor: {} as Record<string, unknown> },
}))

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
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: politicasActuales.valor }),
}))
vi.mock('../../utils/formatters', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../utils/formatters')>()
  return { ...actual, formatPrecio: (v: number) => `$${Number(v).toFixed(2)}` }
})

import ModalEditarPedido from './ModalEditarPedido'
import { RechazoDeNegocioError, CODIGO_REQUIERE_DECISION_ENVIO } from '../../utils/rechazoDeNegocio'

const ESCALAS = {
  mostrarSinStock: true,
  modoMinimoPedido: 'escalas',
  montoMinimoPedido: 5000,
  montoEnvioGratis: 15000,
  cargoEnvioPedido: 500,
}
const BLOQUEAR = {
  mostrarSinStock: true,
  modoMinimoPedido: 'bloquear',
  montoMinimoPedido: 0,
  montoEnvioGratis: 0,
  cargoEnvioPedido: 0,
}

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 1000, stock: 100, categoria: 'Snacks' },
] as any[]

/** Un pedido de `cantidad` unidades a $1.000, con su cargo y su estado. */
function pedidoDe(cantidad: number, cargo: number, estado?: string) {
  return {
    id: 601,
    notas: '',
    estado: 'en_preparacion',
    total: cantidad * 1000 + cargo,
    cargo_envio: cargo,
    ...(estado ? { cargo_envio_estado: estado } : {}),
    tipo_factura: 'ZZ',
    cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
    items: [{ producto_id: '1', cantidad, precio_unitario: 1000, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
  } as any
}

/** El renglón "Total del Pedido" (el subtotal de la línea repite el número). */
const totalMostrado = () => screen.getByText('Total del Pedido').parentElement!.textContent ?? ''
const menos = () => Array.from(document.body.querySelectorAll('button.rounded-l-lg'))[0] as HTMLElement
const mas = () => Array.from(document.body.querySelectorAll('button.rounded-r-lg'))[0] as HTMLElement

function renderModal(pedido: any, opciones: { admin: boolean; onSaveItems?: any; onSave?: any; onClose?: any }) {
  const onSaveItems = opciones.onSaveItems ?? vi.fn().mockResolvedValue(undefined)
  const onSave = opciones.onSave ?? vi.fn().mockResolvedValue(undefined)
  const onClose = opciones.onClose ?? vi.fn()
  render(
    <ModalEditarPedido
      productos={productos}
      pedido={pedido}
      canEditItems
      isAdmin={opciones.admin}
      esPreventista={!opciones.admin}
      onSave={onSave}
      onSaveItems={onSaveItems}
      onClose={onClose}
      guardando={false}
    />,
  )
  return { onSaveItems, onSave, onClose }
}

async function guardar(user: ReturnType<typeof userEvent.setup>) {
  const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
  await waitFor(() => expect(boton).toBeEnabled())
  await user.click(boton)
}

beforeEach(() => {
  vi.clearAllMocks()
  politicasActuales.valor = ESCALAS
})

describe('ModalEditarPedido — desglose del envío', () => {
  it('el preventista que baja de la franja ve Productos / Envío / Total con el envío que se va a cobrar', async () => {
    const user = userEvent.setup()
    renderModal(pedidoDe(15, 0, 'gratis'), { admin: false })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    // Antes: 15.000 es "arriba", sin envío.
    expect(screen.queryByText(/Envío/)).not.toBeInTheDocument()
    expect(totalMostrado()).toContain('$15000.00')

    await user.click(menos())
    const desglose = await screen.findByTestId('desglose-envio')
    expect(within(desglose).getByText('Productos')).toBeInTheDocument()
    expect(within(desglose).getByText('$14000.00')).toBeInTheDocument()
    expect(within(desglose).getByText('Envío')).toBeInTheDocument()
    expect(within(desglose).getByText('$500.00')).toBeInTheDocument()
    expect(totalMostrado()).toContain('$14500.00')
  })

  it('un pedido con envío lo muestra desglosado antes de editar; el preventista que sube de la franja lo saca', async () => {
    const user = userEvent.setup()
    renderModal(pedidoDe(14, 500, 'cobrado'), { admin: false })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    const antes = screen.getByTestId('desglose-envio')
    expect(within(antes).getByText('$14000.00')).toBeInTheDocument()
    expect(within(antes).getByText('$500.00')).toBeInTheDocument()
    expect(totalMostrado()).toContain('$14500.00')

    await user.click(mas())
    await waitFor(() => expect(totalMostrado()).toContain('$15000.00'))
    const despues = screen.getByTestId('desglose-envio')
    // El envío que tenía se va: queda en $0 (la fila se ve porque el pedido lo tenía).
    expect(within(despues).getByText('$0.00')).toBeInTheDocument()
  })
})

describe('ModalEditarPedido — decisión del envío', () => {
  it('el admin que cruza hacia abajo ve el diálogo DENTRO del modal y su respuesta viaja', async () => {
    const user = userEvent.setup()
    const { onSaveItems, onSave, onClose } = renderModal(pedidoDe(15, 0, 'gratis'), { admin: true })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(menos())
    await guardar(user)

    const dialogo = await screen.findByRole('dialog', { name: 'Cargo de envío' })
    expect(within(dialogo).getByText('El pedido quedó en $14000.00. ¿Agregar envío de $500.00?')).toBeInTheDocument()
    expect(onSaveItems).not.toHaveBeenCalled()

    // Anidado en el modal: Escape cierra sólo el diálogo, no el modal, y no guarda.
    await user.keyboard('{Escape}')
    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Cargo de envío' })).not.toBeInTheDocument())
    expect(onClose).not.toHaveBeenCalled()
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: /Editar Pedido/ })).toBeInTheDocument()

    await guardar(user)
    const otraVez = await screen.findByRole('dialog', { name: 'Cargo de envío' })
    await user.click(within(otraVez).getByRole('button', { name: 'Agregar envío' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(onSaveItems.mock.calls[0][2]).toBe('cobrar')
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
  })

  it('el admin que cruza hacia arriba responde "Sacar envío" y viaja no_cobrar', async () => {
    const user = userEvent.setup()
    const { onSaveItems } = renderModal(pedidoDe(14, 500, 'cobrado'), { admin: true })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(mas())
    await guardar(user)

    const dialogo = await screen.findByRole('dialog', { name: 'Cargo de envío' })
    expect(within(dialogo).getByText('El pedido quedó en $15000.00. ¿Sacar el envío de $500.00?')).toBeInTheDocument()
    await user.click(within(dialogo).getByRole('button', { name: 'Sacar envío' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(onSaveItems.mock.calls[0][2]).toBe('no_cobrar')
  })

  it('el preventista que cruza no ve diálogo y guarda sin decisión', async () => {
    const user = userEvent.setup()
    const { onSaveItems, onSave } = renderModal(pedidoDe(15, 0, 'gratis'), { admin: false })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(menos())
    await guardar(user)

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(onSaveItems.mock.calls[0][2]).toBeUndefined()
    expect(screen.queryByRole('dialog', { name: 'Cargo de envío' })).not.toBeInTheDocument()
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
  })

  it('el rechazo requiere_decision_envio del server abre el diálogo y reintenta con la respuesta', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn()
      .mockRejectedValueOnce(new RechazoDeNegocioError(
        'El pedido quedó en $15.000,00. ¿Agregar envío de $700,00?',
        CODIGO_REQUIERE_DECISION_ENVIO,
        { cargo: 700, franja: 'debajo', total_productos: 15000 },
      ))
      .mockResolvedValueOnce(undefined)
    // 16 -> 15 no cruza con la política que conoce el modal: el que pide es el server.
    const { onSave } = renderModal(pedidoDe(16, 0, 'gratis'), { admin: true, onSaveItems })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(menos())
    await guardar(user)

    const dialogo = await screen.findByRole('dialog', { name: 'Cargo de envío' })
    expect(within(dialogo).getByText('El pedido quedó en $15000.00. ¿Agregar envío de $700.00?')).toBeInTheDocument()
    expect(onSave).not.toHaveBeenCalled()
    await user.click(within(dialogo).getByRole('button', { name: 'No cobrar' }))

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(2))
    expect(onSaveItems.mock.calls[0][2]).toBeUndefined()
    expect(onSaveItems.mock.calls[1][2]).toBe('no_cobrar')
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    // El rechazo no quedó como error en pantalla.
    expect(screen.queryByText(/¿Agregar envío de \$700,00\?/)).not.toBeInTheDocument()
  })

  it('una sucursal en bloquear: ni diálogo ni "Envío"', async () => {
    politicasActuales.valor = BLOQUEAR
    const user = userEvent.setup()
    const { onSaveItems } = renderModal(pedidoDe(15, 0, 'gratis'), { admin: true })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(menos())
    expect(screen.queryByText(/Envío/)).not.toBeInTheDocument()
    await guardar(user)

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(onSaveItems.mock.calls[0][2]).toBeUndefined()
    expect(screen.queryByRole('dialog', { name: 'Cargo de envío' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Envío/)).not.toBeInTheDocument()
  })

  it('un pedido sin cargo_envio_estado (antes de la migración) es no_aplica: ni diálogo ni "Envío"', async () => {
    const user = userEvent.setup()
    const { onSaveItems } = renderModal(pedidoDe(15, 0), { admin: true })
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(menos())
    expect(screen.queryByText(/Envío/)).not.toBeInTheDocument()
    await guardar(user)

    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    expect(onSaveItems.mock.calls[0][2]).toBeUndefined()
    expect(screen.queryByRole('dialog', { name: 'Cargo de envío' })).not.toBeInTheDocument()
  })
})
