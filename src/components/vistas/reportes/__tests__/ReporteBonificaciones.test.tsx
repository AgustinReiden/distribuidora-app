/**
 * Reporte de bonificaciones. Los fixtures son la respuesta del RPC
 * `reporte_bonificaciones`: lo que se fija es que la pantalla muestre esos
 * números sin re-derivarlos, que cada corte se vea, que los filtros del detalle
 * no muevan los totales y que el Excel baje todos los cortes.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockUseReporte = vi.fn()
const mockFetch = vi.fn()
const mockCrearExcel = vi.fn()

vi.mock('../../../../hooks/queries/useBonificacionesReporteQuery', () => ({
  useBonificacionesReporteQuery: (suc: unknown, desde: string, hasta: string) => mockUseReporte(suc, desde, hasta),
  fetchReporteBonificaciones: (...args: unknown[]) => mockFetch(...args),
}))

vi.mock('../../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: unknown[], filename: string) => mockCrearExcel(hojas, filename),
}))

vi.mock('../../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ sucursales: [{ id: 1, nombre: 'Tucumán' }], hasMultipleSucursales: false, currentSucursalId: 1 }),
}))

vi.mock('../../../../utils/periodosReporte', () => ({
  presetsVentas: () => [{ id: 'mes-2026-10', label: 'Octubre 2026', desde: '2026-10-01', hasta: '2026-10-31' }],
}))

import { ReporteBonificaciones } from '../ReporteBonificaciones'

const formatPrecio = (v: number): string => `$${Math.round(v).toLocaleString('es-AR')}`

const lineaBase = {
  sucursal_nombre: 'Tucumán', cliente_activo: true, producto_codigo: null, sin_costo: false,
}

const datos = {
  meta: { sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-10-01', hasta: '2026-10-31', generado_at: '', criterio: 'Pedidos entregados…' },
  totales: {
    lineas: 3, pedidos_con_bonif: 2, clientes_con_bonif: 2, pedidos_entregados: 40,
    unidades: 13, bultos: 3, costo: 30000, valor_venta: 50000,
    venta: 1000000, venta_pedidos_con_bonif: 200000, filas_sin_costo: 0,
  },
  por_promocion: [
    { promocion_id: 13, nombre: 'Promo Manaos 6 + 2', activo: true, fecha_inicio: '2026-05-12', fecha_fin: null, pedidos: 1, clientes: 1, unidades: 12, bultos: 2, costo: 20000, valor_venta: 35000, filas_sin_costo: 0 },
    { promocion_id: 19, nombre: 'Promo Placer 12 + 1', activo: false, fecha_inicio: '2026-09-01', fecha_fin: null, pedidos: 1, clientes: 1, unidades: 1, bultos: 1, costo: 10000, valor_venta: 15000, filas_sin_costo: 0 },
  ],
  por_producto: [
    { producto_id: 78, nombre: 'Manaos Cola 3 L', codigo: '100101', es_fraccion: true, pedidos: 1, unidades: 12, bultos: 2, costo: 20000, valor_venta: 35000, filas_sin_costo: 0 },
    { producto_id: 5, nombre: 'Placer 500', codigo: null, es_fraccion: false, pedidos: 1, unidades: 1, bultos: 1, costo: 10000, valor_venta: 15000, filas_sin_costo: 0 },
  ],
  por_promocion_producto: [
    { promocion_id: 13, promocion: 'Promo Manaos 6 + 2', producto_id: 78, producto: 'Manaos Cola 3 L', es_fraccion: true, unidades: 12, bultos: 2, costo: 20000, valor_venta: 35000 },
    { promocion_id: 19, promocion: 'Promo Placer 12 + 1', producto_id: 5, producto: 'Placer 500', es_fraccion: false, unidades: 1, bultos: 1, costo: 10000, valor_venta: 15000 },
  ],
  por_vendedor: [
    { usuario_id: 'u1', nombre: 'Marcelo', pedidos_entregados: 30, pedidos_con_bonif: 1, venta: 800000, bultos: 2, costo: 20000, valor_venta: 35000 },
    { usuario_id: 'u2', nombre: 'Virginia', pedidos_entregados: 10, pedidos_con_bonif: 1, venta: 200000, bultos: 1, costo: 10000, valor_venta: 15000 },
  ],
  por_cliente: [
    { cliente_id: 10, nombre: 'Almacén Doña Rosa', codigo: 'A10', activo: false, pedidos_entregados: 3, pedidos_con_bonif: 1, venta: 100000, bultos: 2, costo: 20000, valor_venta: 35000 },
  ],
  detalle: [
    { ...lineaBase, pedido_id: 100, fecha: '2026-10-20', cliente_id: 10, cliente_nombre: 'Almacén Doña Rosa', usuario_id: 'u1', vendedor_nombre: 'Marcelo', promocion_id: 13, promocion_nombre: 'Promo Manaos 6 + 2', producto_id: 78, producto_nombre: 'Manaos Cola 3 L', cantidad: 12, es_fraccion: true, factor: 6, bultos: 2, costo_unitario: 1666.67, costo: 20000, valor_venta: 35000 },
    { ...lineaBase, pedido_id: 101, fecha: '2026-10-21', cliente_id: 11, cliente_nombre: 'Kiosco Ana', usuario_id: 'u2', vendedor_nombre: 'Virginia', promocion_id: 19, promocion_nombre: 'Promo Placer 12 + 1', producto_id: 5, producto_nombre: 'Placer 500', cantidad: 1, es_fraccion: false, factor: 1, bultos: 1, costo_unitario: 10000, costo: 10000, valor_venta: 15000 },
  ],
  detalle_total: 2,
  detalle_limite: 5000,
  detalle_truncado: false,
}

function renderTab(data: unknown = datos) {
  mockUseReporte.mockReturnValue({ data, isLoading: false, error: null })
  mockFetch.mockResolvedValue(data)
  return render(<ReporteBonificaciones formatPrecio={formatPrecio} />)
}

describe('ReporteBonificaciones', () => {
  beforeEach(() => vi.clearAllMocks())

  it('pide el período default de la sucursal activa', () => {
    renderTab()
    expect(mockUseReporte).toHaveBeenCalledWith(1, '2026-10-01', '2026-10-31')
  })

  it('las tarjetas muestran los totales del RPC', () => {
    renderTab()
    expect(screen.getByTestId('kpi-costo')).toHaveTextContent('$30.000')
    expect(screen.getByTestId('kpi-valor-venta')).toHaveTextContent('$50.000')
    expect(screen.getByTestId('kpi-bultos')).toHaveTextContent('3')
    expect(screen.getByTestId('kpi-pedidos')).toHaveTextContent('2 de 40')
    // 30.000 sobre 1.000.000 de venta.
    expect(screen.getByText(/3,0 % de la venta del período/)).toBeInTheDocument()
  })

  it('aclara que no es la merma de promociones', () => {
    renderTab()
    expect(screen.getByText(/día de carga/i)).toBeInTheDocument()
  })

  it('por promoción: cada promo con su peso y la inactiva marcada', () => {
    renderTab()
    const tabla = screen.getByRole('table', { name: 'Por promoción' })
    const fila = within(tabla).getByText('Promo Manaos 6 + 2').closest('tr') as HTMLElement
    expect(within(fila).getByText('$20.000')).toBeInTheDocument()
    expect(within(fila).getByText('66,7 %')).toBeInTheDocument()
    expect(within(tabla).getByText('inactiva')).toBeInTheDocument()
  })

  it('cada corte se puede ver', async () => {
    renderTab()
    await userEvent.click(screen.getByRole('tab', { name: 'Por producto' }))
    expect(within(screen.getByRole('table', { name: 'Por producto' })).getByText('(100101)')).toBeInTheDocument()

    await userEvent.click(screen.getByRole('tab', { name: 'Promoción × producto' }))
    const cruce = screen.getByRole('table', { name: 'Promoción por producto' })
    expect(within(cruce).getByText('Placer 500')).toBeInTheDocument()

    await userEvent.click(screen.getByRole('tab', { name: 'Por vendedor' }))
    const vend = screen.getByRole('table', { name: 'Por vendedor' })
    const marcelo = within(vend).getByText('Marcelo').closest('tr') as HTMLElement
    // 20.000 sobre 800.000 de su venta.
    expect(within(marcelo).getByText('2,5 %')).toBeInTheDocument()

    await userEvent.click(screen.getByRole('tab', { name: 'Por cliente' }))
    const cli = screen.getByRole('table', { name: 'Por cliente' })
    expect(within(cli).getByText('inactivo')).toBeInTheDocument()
  })

  it('el filtro del detalle achica la lista y no mueve las tarjetas', async () => {
    renderTab()
    const detalle = screen.getByRole('table', { name: 'Detalle de bonificaciones' })
    expect(within(detalle).getAllByRole('row')).toHaveLength(3)

    await userEvent.selectOptions(screen.getByLabelText('Vendedor'), 'u2')
    expect(within(screen.getByRole('table', { name: 'Detalle de bonificaciones' })).getAllByRole('row')).toHaveLength(2)
    expect(screen.getByTestId('resumen-detalle')).toHaveTextContent(/Lo filtrado: 1 líneas/)
    expect(screen.getByTestId('kpi-costo')).toHaveTextContent('$30.000')
  })

  it('sin regalos en el período lo dice', () => {
    renderTab({
      ...datos,
      totales: { ...datos.totales, lineas: 0, pedidos_con_bonif: 0, clientes_con_bonif: 0, unidades: 0, bultos: 0, costo: 0, valor_venta: 0 },
      por_promocion: [], por_producto: [], por_promocion_producto: [], por_vendedor: [], por_cliente: [],
      detalle: [], detalle_total: 0,
    })
    expect(screen.getByText('No hubo regalos en el período.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Exportar a Excel/i })).toBeDisabled()
  })

  it('el Excel baja todos los cortes y el detalle', async () => {
    renderTab()
    await userEvent.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
    expect(mockFetch).toHaveBeenCalledWith(1, '2026-10-01', '2026-10-31')
    const [hojas, archivo] = mockCrearExcel.mock.calls[0] as [{ name: string; data: unknown[] }[], string]
    expect(hojas.map((h) => h.name)).toEqual([
      'Info', 'Por promoción', 'Por producto', 'Promoción × producto', 'Por vendedor', 'Por cliente', 'Detalle',
    ])
    expect(hojas.find((h) => h.name === 'Detalle')?.data).toHaveLength(2)
    expect(archivo).toBe('bonificaciones-Tucumán-2026-10-01_2026-10-31')
  })
})
