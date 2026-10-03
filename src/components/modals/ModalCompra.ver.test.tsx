/**
 * ModalCompra en modo 'ver': la compra guardada en el mismo formulario de carga,
 * en sólo lectura.
 *
 * Reemplaza a ModalDetalleCompra, así que lo primero que fija es que no se
 * perdió nada de lo que aquél mostraba o hacía (estado, usuario, unidades,
 * stock antes → después, vencimientos, forma de pago histórica, totales
 * guardados, notas de crédito, notas, y los botones de nota de crédito y
 * anular). Después, lo nuevo: el reparto de cada cargo por línea, el costo
 * final GUARDADO y la variación contra la compra anterior.
 *
 * Datos sintéticos: el repo es público.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { CompraDBExtended } from '../../types'
import type { CostoAnterior } from '../../utils/costoAnterior'

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

const costosAnteriores = vi.fn<(ids: string[], ref: unknown) => { data: Map<string, CostoAnterior> | undefined }>()
vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
  useCostosAnterioresQuery: (ids: string[], ref: unknown) => costosAnteriores(ids, ref),
}))

// Catálogo de cargos y medidas (mig 278): vacío, como antes de la migración.
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  // Referencias estables: el modal sincroniza su estado cuando cambian.
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))

import ModalCompra from './ModalCompra'

function compraGuardada(over: Partial<CompraDBExtended> = {}): CompraDBExtended {
  return {
    id: '304',
    proveedor_id: '7',
    proveedor: { id: '7', nombre: 'Bebidas Testigo SA', cuit: '30-12345678-9' } as never,
    numero_factura: 'A0005-00012345',
    fecha_compra: '2026-09-12',
    created_at: '2026-09-12T15:30:00Z',
    tipo_factura: 'FC',
    forma_pago: 'cuenta_corriente',
    estado: 'recibida' as never,
    usuario: { id: 'u1', nombre: 'Ana Depósito' },
    notas: 'Llegó con un pallet roto',
    subtotal: 360000,
    iva: 75600,
    impuestos_internos: 12000,
    percepcion_iva: 1500,
    percepcion_iibb: 0,
    no_gravado: 0,
    bonificaciones: -6000,
    total: 443100,
    items: [
      {
        id: '12', compra_id: '304', producto_id: '502', producto: { nombre: 'Agua 2L' } as never,
        cantidad: 160, costo_unitario: 1500, bonificacion: 0, subtotal: 240000,
        porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 0,
        costo_real_unitario: 1555.5, stock_anterior: 10, stock_nuevo: 170,
      },
      {
        id: '11', compra_id: '304', producto_id: '501', producto: { nombre: 'Gaseosa 3L' } as never,
        cantidad: 60, costo_unitario: 2000, bonificacion: 5, subtotal: 114000,
        porcentaje_iva: null, condicion_iva: 'gravado', impuestos_internos: 10,
        costo_real_unitario: 2100, stock_anterior: 0, stock_nuevo: 60,
      },
    ],
    cargos: [{
      id: '90', orden: 0, concepto: 'Flete', monto: 9000,
      condicion_iva: 'no_gravado', en_factura: false, prorratea_al_costo: true,
      afecta_base_ii: false, base_prorrateo: 'cantidad',
      repartos: [{ compra_item_id: '12', peso: 4 }, { compra_item_id: '11', peso: 0.5 }],
    }],
    ...over,
  }
}

function renderVer(over: Partial<CompraDBExtended> = {}, props: Partial<Parameters<typeof ModalCompra>[0]> = {}) {
  const onAnular = vi.fn(() => Promise.resolve())
  const onNotaCredito = vi.fn()
  const onClose = vi.fn()
  render(
    <ModalCompra
      modo="ver"
      compra={compraGuardada(over)}
      productos={[]}
      proveedores={[]}
      onClose={onClose}
      onAnular={onAnular}
      onNotaCredito={onNotaCredito}
      lotes={[{ producto_id: 501, fecha_vencimiento: '2027-03-01', cantidad: 60 }]}
      notasCredito={[{ id: '5', numero_nota: 'NC-0001', fecha: '2026-09-20', total: 3000, motivo: 'Faltante', items: [] }]}
      {...props}
    />,
  )
  return { onAnular, onNotaCredito, onClose, user: userEvent.setup() }
}

beforeEach(() => {
  costosAnteriores.mockReset()
  costosAnteriores.mockReturnValue({ data: undefined })
})

describe("ModalCompra modo 'ver': lo que mostraba ModalDetalleCompra", () => {
  it('cabezal: número, estado, proveedor con CUIT, factura, forma de pago histórica, usuario y unidades', () => {
    renderVer()
    expect(screen.getByRole('heading', { name: 'Compra #304' })).toBeInTheDocument()
    expect(screen.getByText('Recibida')).toBeInTheDocument()
    expect(screen.getByText('Bebidas Testigo SA')).toBeInTheDocument()
    expect(screen.getByText('CUIT: 30-12345678-9')).toBeInTheDocument()
    expect(screen.getByDisplayValue('A0005-00012345')).toBeDisabled()
    // `cuenta_corriente` ya no se ofrece al cargar, pero sigue en compras viejas.
    expect(screen.getByDisplayValue('Cuenta Corriente')).toBeInTheDocument()
    expect(screen.getByText(/Registrado por: Ana Depósito/)).toBeInTheDocument()
    expect(screen.getByText(/220 unidades/)).toBeInTheDocument()
  })

  it('líneas: stock antes → después, IVA sin dato, vencimientos de la compra; nada editable', () => {
    renderVer()
    expect(screen.getAllByText('Stock: 10 → 170').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Stock: 0 → 60 · IVA s/d').length).toBeGreaterThan(0)
    expect(screen.getByText(/Vence: .*\(60 u\.\)/)).toBeInTheDocument()
    // El formulario entero está deshabilitado y no hay nada para cargar.
    const campos = [...screen.getAllByRole('textbox'), ...screen.getAllByRole('combobox'), ...screen.getAllByRole('checkbox')]
    expect(campos.length).toBeGreaterThan(5)
    for (const campo of campos) expect(campo).toBeDisabled()
    expect(screen.queryByPlaceholderText('Buscar producto por nombre o codigo...')).toBeNull()
    expect(screen.queryByRole('button', { name: /Agregar cargo/ })).toBeNull()
    expect(screen.queryByRole('button', { name: /Registrar Compra/ })).toBeNull()
  })

  it('totales GUARDADOS, notas de crédito y notas', () => {
    renderVer()
    const totales = screen.getByRole('heading', { name: 'Totales registrados' }).closest('div')!.parentElement!
    expect(within(totales).getByText('Bonificaciones de la factura:')).toBeInTheDocument()
    expect(within(totales).getByText('Percepción IVA:')).toBeInTheDocument()
    expect(within(totales).getByText(/443\.100/)).toBeInTheDocument()
    expect(screen.getByText('NC-0001')).toBeInTheDocument()
    expect(screen.getByText('Faltante')).toBeInTheDocument()
    expect(screen.getByText('Llegó con un pallet roto')).toBeInTheDocument()
  })

  it('"Anular Compra" pide confirmación ADENTRO del modal y recién ahí anula', async () => {
    const { onAnular, user } = renderVer()
    await user.click(screen.getByRole('button', { name: 'Anular Compra' }))
    const dialogo = await screen.findByRole('dialog', { name: 'Anular compra' })
    // userEvent respeta pointer-events: si la confirmación quedara detrás del
    // overlay del Dialog de la compra, este click no llegaría.
    await user.click(within(dialogo).getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(onAnular).toHaveBeenCalledWith('304'))
  })

  it('"Nota de Credito" llama con la compra', async () => {
    const { onNotaCredito, user } = renderVer()
    await user.click(screen.getByRole('button', { name: /Nota de Credito/ }))
    expect(onNotaCredito).toHaveBeenCalledWith(expect.objectContaining({ id: '304' }))
  })

  it('una compra cancelada no ofrece anular ni nota de crédito', () => {
    renderVer({ estado: 'cancelada' })
    expect(screen.getByText('Cancelada')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Anular Compra' })).toBeNull()
    expect(screen.queryByRole('button', { name: /Nota de Credito/ })).toBeNull()
  })
})

describe("ModalCompra modo 'ver': cargos, costo guardado y variación", () => {
  it('cada cargo muestra su reparto por línea con los pesos guardados', () => {
    renderVer()
    expect(screen.getByDisplayValue('Flete')).toBeDisabled()
    expect(screen.getByText('Reparto por línea')).toBeInTheDocument()
    // Los pesos tipeados (4 y 0,5), no las cantidades (160 y 60) que daría la base.
    expect(screen.getAllByDisplayValue('4').length).toBeGreaterThan(0)
    expect(screen.queryAllByDisplayValue('0,5').length + screen.queryAllByDisplayValue('0.5').length).toBeGreaterThan(0)
  })

  it('el costo final es el guardado, con la variación contra la anterior y su tooltip', () => {
    costosAnteriores.mockReturnValue({
      data: new Map<string, CostoAnterior>([
        ['502', { compraId: '250', fechaCompra: '2026-08-30', costoRealUnitario: 1500, tipoFactura: 'FC' }],
        ['501', { compraId: '251', fechaCompra: '2026-08-31', costoRealUnitario: 2190, tipoFactura: 'ZZ' }],
      ]),
    })
    renderVer()
    // La consulta va contra ESTA compra: estrictamente anterior y sin su factura.
    expect(costosAnteriores).toHaveBeenCalledWith(
      expect.arrayContaining(['501', '502']),
      { compraId: '304', fechaCompra: '2026-09-12', numeroFactura: 'A0005-00012345' },
    )
    const chips = screen.getAllByTestId('variacion-costo')
    const sube = chips.find(c => c.textContent === '+3,7%')!   // 1555,5 vs 1500
    const baja = chips.find(c => c.textContent === '−4,1%')! // 2100 vs 2190
    expect(sube).toHaveClass('text-red-600')
    expect(baja).toHaveClass('text-green-600')
    expect(sube).toHaveAttribute('title', expect.stringMatching(/^compra anterior #250 del 30\/08/))
    expect(baja.getAttribute('title')).toMatch(/compra anterior #251 del 31\/08.* \(en ZZ\)$/)
    // El guardado, no un recálculo.
    expect(screen.getAllByText(/1\.555,50/).length).toBeGreaterThan(0)
  })

  it('sin compra anterior no muestra nada', () => {
    renderVer()
    expect(screen.queryAllByTestId('variacion-costo')).toHaveLength(0)
  })

  it('sin líneas ni cargos (RLS) muestra una nota en vez de una tabla rota', () => {
    renderVer({ items: [], cargos: [] })
    expect(screen.getByText(/no tiene acceso a ese detalle/)).toBeInTheDocument()
    expect(screen.queryByText('Cargos y prorrateo')).toBeNull()
    // Los totales guardados siguen.
    expect(screen.getByRole('heading', { name: 'Totales registrados' })).toBeInTheDocument()
  })
})

describe("ModalCompra modo 'nueva': variación en la vista previa de costos", () => {
  it('compara el costo final que va a guardar contra la compra anterior del producto', async () => {
    costosAnteriores.mockReturnValue({
      data: new Map<string, CostoAnterior>([
        ['p1', { compraId: '300', fechaCompra: '2026-09-01', costoRealUnitario: 125, tipoFactura: 'FC' }],
      ]),
    })
    const user = userEvent.setup()
    render(
      <ModalCompra
        productos={[{ id: 'p1', nombre: 'Aceite 900', codigo: 'A9', stock: 3, costo_sin_iva: 100, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' } as never]}
        proveedores={[]}
        onSave={vi.fn(() => Promise.resolve())}
        onClose={vi.fn()}
      />,
    )
    await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
    await user.click(screen.getByRole('button', { name: /Aceite 900/ }))
    // Sin id propio: la referencia es la fecha de la carga.
    expect(costosAnteriores).toHaveBeenLastCalledWith(['p1'], expect.objectContaining({ compraId: null }))
    await user.click(screen.getByRole('button', { name: /Costo por producto/ }))
    // 100 (neto, sin II ni cargos) contra 125 de la anterior: −20,0%.
    const chip = screen.getAllByTestId('variacion-costo')[0]
    expect(chip).toHaveTextContent('−20,0%')
    expect(chip).toHaveClass('text-green-600')
  })
})
