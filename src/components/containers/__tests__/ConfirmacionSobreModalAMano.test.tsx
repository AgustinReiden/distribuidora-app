/**
 * La confirmación que se dispara DESDE ADENTRO de un modal hecho a mano.
 *
 * EL RIESGO DE LA MIGRACIÓN
 * -------------------------
 * CLAUDE.md lo tiene escrito: "una confirmación disparada desde un modal Radix
 * tiene que renderizarse DENTRO del modal. Como hermano en el container queda
 * detrás del overlay y falla en silencio". Ya pasó en
 * `ModalActualizacionMasivaPrecios` (ver su test).
 *
 * Hoy `ComprasContainer` renderiza `ModalConfirmacion` como HERMANO de los
 * modales, y funciona porque ninguno de ellos es un Dialog de Radix: son
 * `<div className="fixed inset-0">` a mano, sin `aria-hidden` sobre los
 * hermanos ni `pointer-events: none` en el body.
 *
 * Hay UN flujo real en el que las dos cosas conviven: "Anular Compra" desde el
 * detalle de una compra, que abre la confirmación **sin cerrar el detalle**.
 * Este test fija que el botón "Confirmar" de esa confirmación es alcanzable con
 * `userEvent` —que respeta `pointer-events` y `aria-hidden`— y que produce su
 * efecto.
 *
 * ACTUALIZACIÓN (compras, entrega B1): el detalle ya no es el
 * `ModalDetalleCompra` hecho a mano sino `ModalCompra` en modo 'ver', que SÍ es
 * un Dialog de Radix (`ModalBase`). Pasó exactamente lo que este test anticipaba
 * y por eso la confirmación se mudó ADENTRO del modal: la renderiza ModalCompra,
 * no el container. El test sigue igual de vigente —ahora prueba que la mudanza
 * se hizo— y se pone ROJO si alguien la vuelve a sacar como hermana.
 *
 * PARA LOS OTROS TRES MODALES DE ESTA TANDA, EL FLUJO NO EXISTE
 * ------------------------------------------------------------
 * Se revisó cada disparo de confirmación de los tres containers. Todos salen de
 * la vista de fondo o de un panel, nunca de adentro de un modal, así que no hay
 * test que escribir —inventarlo sería fijar un flujo que la app no tiene—:
 *
 *  - ModalCompra (ComprasContainer.tsx:374-384): el único disparo del container
 *    es `handleAnularCompra` (ComprasContainer.tsx:167-181). ModalCompra no lo
 *    recibe; le llega a VistaCompras (:365) y a ModalDetalleCompra (:395).
 *
 *  - ModalMermaStock (ProductosContainer.tsx:450-457): el único disparo del
 *    container es `handleEliminarProducto` (ProductosContainer.tsx:181-194), y
 *    sólo lo recibe VistaProductos (`onEliminarProducto`,
 *    ProductosContainer.tsx:401). El modal de merma sólo recibe onSave/onClose.
 *
 *  - ModalEntregaConSalvedad (PedidosContainer.tsx:2293-2298): los seis disparos
 *    del container —`handleMarcarEntregado` cambio/devolución
 *    (PedidosContainer.tsx:488) y pedido pagado (:505),
 *    `handleDesmarcarEntregado` (:531), `handleMarcarEnPreparacion` (:548),
 *    `handleVolverAPendiente` (:562) y `handleCancelarPedido` con cobros (:652)—
 *    se cablean a VistaPedidos (:2002-2007) y a PanelPedidosTrabados (:1959).
 *    El modal de salvedad sólo recibe onSave / onMarcarEntregado / onClose.
 *
 * Corolario para el reseño: migrar ESTOS tres a `ModalBase` no arrastra el
 * problema del overlay. El que hay que mirar es `ModalDetalleCompra`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const anularCompra = vi.fn()
const notifySuccess = vi.fn()
const notifyError = vi.fn()

const COMPRA = {
  id: '77',
  estado: 'recibida' as const,
  proveedor_nombre: 'Manaos SA',
  created_at: '2026-09-15T12:00:00Z',
  fecha_compra: '2026-09-15',
  numero_factura: '0001-00012345',
  forma_pago: 'efectivo' as const,
  subtotal: 10000,
  iva: 2100,
  total: 12100,
  tipo_factura: 'FC' as const,
  items: [
    {
      producto_id: 'p1',
      cantidad: 4,
      costo_unitario: 2500,
      subtotal: 10000,
      producto: { nombre: 'Aceite Girasol 900ml' },
    },
  ],
}

vi.mock('../../../hooks/queries', () => ({
  useComprasQuery: () => ({ data: [COMPRA], isLoading: false, isError: false, refetch: vi.fn() }),
  useCompraQuery: () => ({ data: undefined }),
  useProveedoresQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useNotasCreditoByCompraQuery: () => ({ data: [] }),
  useNotasCreditoResumenQuery: () => ({ data: [] }),
  useRegistrarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useAnularCompraMutation: () => ({ mutateAsync: anularCompra, isPending: false }),
  useCambiarProveedorCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProveedorMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRegistrarNotaCreditoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCategoriasQuery: () => ({ data: [] }),
  useMarcasQuery: () => ({ data: [] }),
  useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
}))

// ModalCompra en 'ver' va REAL; lo que consulta por su cuenta, stubbeado.
vi.mock('../../../lib/supabase', () => ({
  supabase: { storage: { from: vi.fn() }, rpc: vi.fn(), from: vi.fn() },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
  useCostosAnterioresQuery: () => ({ data: undefined }),
}))
// Catálogo de cargos y medidas (mig 278): vacío, como antes de la migración.
vi.mock('../../../hooks/queries/useCargosCatalogoQuery', () => {
  // Referencias estables: el modal sincroniza su estado cuando cambian.
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
vi.mock('../../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))

vi.mock('../../../hooks/queries/useLotesQuery', () => ({
  useLotesCompraQuery: () => ({ data: [] }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true, isEncargado: false, user: { id: 'u1' } }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({
    error: notifyError,
    success: notifySuccess,
    warning: vi.fn(),
    info: vi.fn(),
  }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

vi.mock('../../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))

// La vista de fondo sólo tiene que poder abrir el detalle de la compra. El
// modal de detalle y el de confirmación van REALES: son los dos que tienen que
// convivir.
vi.mock('../../vistas/VistaCompras', () => ({
  default: ({ onVerDetalle }: { onVerDetalle?: (c: unknown) => void }) => (
    <button type="button" onClick={() => onVerDetalle?.(COMPRA)}>
      Ver detalle
    </button>
  ),
}))

import ComprasContainer from '../ComprasContainer'

beforeEach(() => {
  vi.clearAllMocks()
  anularCompra.mockResolvedValue(undefined)
})

describe('ModalConfirmacion como hermano de un modal a mano (ComprasContainer)', () => {
  it('"Anular Compra" desde el detalle abre una confirmación clickeable que anula', async () => {
    const user = userEvent.setup()
    render(<ComprasContainer />)

    // La vista y los modales son chunks lazy.
    await user.click(await screen.findByRole('button', { name: 'Ver detalle' }))
    await user.click(await screen.findByRole('button', { name: 'Anular Compra' }, { timeout: 5000 }))

    // El detalle SIGUE montado: abrir la confirmación no lo cierra. `hidden: true` porque, desde que la confirmación es un
    // Dialog de Radix (WP-28), con ella abierta el resto de la página queda
    // `aria-hidden` —es lo correcto— y sin la opción esta consulta sólo pasaba
    // si el chunk lazy de la confirmación todavía no había cargado. Lo que se
    // asevera no cambia: que el detalle sigue en el documento.
    expect(screen.getByRole('heading', { name: 'Compra #77', hidden: true })).toBeInTheDocument()

    const confirmacion = await screen.findByRole('dialog', { name: 'Anular compra' })
    expect(confirmacion).toBeVisible()
    expect(
      screen.getByText('¿Anular esta compra? Se revertirá el stock de los productos.'),
    ).toBeVisible()

    // `userEvent.click` respeta pointer-events y aria-hidden: si la
    // confirmación quedara detrás del overlay de un Dialog de Radix, esto
    // falla en vez de pasar en silencio.
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(anularCompra).toHaveBeenCalledWith('77'))
    await waitFor(() => expect(notifySuccess).toHaveBeenCalledWith('Compra anulada'))
    expect(notifyError).not.toHaveBeenCalled()
  })

  it('Cancelar cierra la confirmación, deja el detalle abierto y no anula nada', async () => {
    const user = userEvent.setup()
    render(<ComprasContainer />)

    await user.click(await screen.findByRole('button', { name: 'Ver detalle' }))
    await user.click(await screen.findByRole('button', { name: 'Anular Compra' }, { timeout: 5000 }))
    await user.click(await screen.findByRole('button', { name: 'Cancelar' }))

    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Anular compra' })).toBeNull())
    expect(screen.getByRole('heading', { name: 'Compra #77' })).toBeInTheDocument()
    expect(anularCompra).not.toHaveBeenCalled()
  })
})
