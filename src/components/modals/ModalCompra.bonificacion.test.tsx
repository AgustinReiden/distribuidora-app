/**
 * #908 en el modal: la promo del proveedor que la factura no descontó aparece
 * como sugerencia en "Cargos y prorrateo", y aplicarla agrega el cargo con su
 * alcance; descartarla la saca sin agregar nada; en 'ver' no se sugiere.
 *
 * Datos sintéticos (src/test/fixtures/compraTestigoEdicion): el repo es público.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { CompraDBExtended } from '../../types'
import type { PromocionProveedor } from '../../utils/sugerenciasBonificacion'

vi.mock('../../lib/supabase', () => ({
  supabase: {
    storage: { from: vi.fn() },
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../hooks/queries/useComprasQuery', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../hooks/queries/useComprasQuery')>()
  return {
    ...real,
    useCargosPlantillaProveedorQuery: () => ({ data: null }),
    useComprasMismaFacturaQuery: () => ({ data: [] }),
    useCostosAnterioresQuery: () => ({ data: undefined }),
  }
})
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  const conceptos = [{
    id: '4', nombre: 'Bonificación', signo: -1, condicionIva: 'gravado', enFactura: true,
    prorrateaAlCosto: true, baseProrrateo: 'monto', medidaId: null, activo: true,
  }]
  const medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
const promos: PromocionProveedor[] = [{
  id: '31', nombre: 'Promo sintética', tipo: 'monto_por_unidad', montoPorUnidad: 50, porcentaje: null,
  vigenteDesde: null, vigenteHasta: null, activo: true, productoIds: ['501'],
}]
vi.mock('../../hooks/queries/usePromocionesProveedorQuery', () => ({
  usePromocionesProveedorQuery: () => ({ data: promos }),
}))
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))

import ModalCompra from './ModalCompra'
import type { ActualizarCompraItemsInput } from '../../hooks/queries/useComprasQuery'
import { compraTestigoEdicion } from '../../test/fixtures/compraTestigoEdicion'

type Props = Parameters<typeof ModalCompra>[0]

/** 501 (100 u., en la promo) y 502 (10 u., afuera), sin cargos. */
function compraSinBonificar(): CompraDBExtended {
  const base = compraTestigoEdicion()
  return compraTestigoEdicion({
    cargos: [], no_gravado: 0, bonificaciones: 0, impuestos_internos: 0, percepcion_iva: 0,
    subtotal: 108000, iva: 22680, total: 130680,
    items: [
      { ...base.items![1], cantidad: 100, costo_unitario: 1000, subtotal: 100000, impuestos_internos: 0 },
      { ...base.items![3], cantidad: 10, costo_unitario: 800, bonificacion: 0, subtotal: 8000, impuestos_internos: 0 },
    ],
  })
}

function renderModal(modo: 'editar' | 'ver') {
  const onGuardarEdicion = vi.fn<(input: ActualizarCompraItemsInput) => Promise<void>>(() => Promise.resolve())
  const props: Props = {
    modo, compra: compraSinBonificar(), productos: [], proveedores: [], onClose: vi.fn(),
    onGuardarEdicion, onCambiarProveedor: vi.fn(), canCambiarProveedor: true,
    usuarioId: 'u1', sucursalId: 1, lotes: [],
  }
  render(<ModalCompra {...props} />)
  return { onGuardarEdicion, user: userEvent.setup() }
}

const banner = () => screen.getByRole('status', { name: 'Bonificaciones sugeridas' })
const aviso = /Promo sintética: el proveedor no descontó .*5\.000.* en 1 línea/

describe('ModalCompra · bonificación no descontada (#908)', () => {
  it('la sugiere y al aplicarla guarda el cargo negativo, en factura, sólo sobre la línea de la promo', async () => {
    const { user, onGuardarEdicion } = renderModal('editar')
    expect(screen.getByText(aviso)).toBeInTheDocument()
    await user.click(within(banner()).getByRole('button', { name: 'Aplicar' }))
    expect(screen.queryByText(aviso)).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /Guardar cambios/ }))
    expect(onGuardarEdicion).toHaveBeenCalledTimes(1)
    const { cargos } = onGuardarEdicion.mock.calls[0][0]
    expect(cargos).toEqual([expect.objectContaining({
      concepto: 'Bonificación', monto: -5000, enFactura: true, condicionIva: 'gravado',
      baseProrrateo: 'cantidad', pesos: { 0: 100, 1: 0 },
    })])
  })

  it('descartarla la saca sin agregar ningún cargo', async () => {
    const { user, onGuardarEdicion } = renderModal('editar')
    await user.click(within(banner()).getByRole('button', { name: 'Descartar' }))
    expect(screen.queryByText(aviso)).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Guardar cambios/ }))
    expect(onGuardarEdicion.mock.calls[0][0].cargos).toEqual([])
  })

  it("en 'ver' no se sugiere", () => {
    renderModal('ver')
    expect(screen.queryByText(aviso)).not.toBeInTheDocument()
  })
})
