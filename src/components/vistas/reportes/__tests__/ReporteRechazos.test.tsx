/**
 * Reporte de rechazos (#1198). Los fixtures son la respuesta del RPC
 * `reporte_rechazos`: lo que se fija es que la pantalla muestre esos números
 * sin re-derivarlos, que los filtros del detalle no muevan los totales, y que
 * el reporte hable de causas y no de culpables.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockUseReporte = vi.fn()
const mockEnabled = vi.fn()

vi.mock('../../../../hooks/queries/useRechazosReporteQuery', () => ({
  useRechazosReporteQuery: (suc: unknown, desde: string, hasta: string, enabled?: boolean) => {
    mockEnabled(enabled)
    return mockUseReporte(suc, desde, hasta)
  },
  fetchReporteRechazos: vi.fn(),
}))

let mockCtx: Record<string, unknown> = { sucursales: [{ id: 1, nombre: 'Tucumán' }], hasMultipleSucursales: false, currentSucursalId: 1 }
vi.mock('../../../../contexts/SucursalContext', () => ({ useSucursal: () => mockCtx }))

vi.mock('../../../../utils/periodosReporte', () => ({
  presetsVentas: () => [
    { id: 'mes-2026-09', label: 'Septiembre 2026', desde: '2026-09-01', hasta: '2026-09-30' },
  ],
}))

import { ReporteRechazos } from '../ReporteRechazos'

const formatPrecio = (v: number): string => `$${Math.round(v).toLocaleString('es-AR')}`

const filaBase = {
  sucursal_id: 1, sucursal_nombre: 'Tucumán', cliente_activo: true, descripcion: null,
  producto_codigo: null, mermas_sin_costo: 0, estado_resolucion: null,
}

const datos = {
  meta: { sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-09-01', hasta: '2026-09-30', generado_at: '', motivos_administrativos: [], criterio: '' },
  totales: {
    pedidos_salieron: 897, pedidos_entregados: 863, rechazos_totales: 34, pedidos_con_salvedad: 49,
    lineas_salvedad: 61, salvedades_pendientes: 61, monto: 1390930, venta_perdida: 1268640,
    venta_perdida_total: 890210, venta_perdida_parcial: 378430, perdida_real: 48954.62,
    monto_mermado: 62250, monto_sin_movimiento: 60040, mermas_sin_costo: 0,
    tasa_rechazo: 0.0925, tasa_rechazo_total: 0.0379, tasa_con_salvedad: 0.0546,
  },
  por_motivo: [
    { tipo: 'total', motivo: 'cerrado', casos: 1, unidades: 5, monto: 500, venta_perdida: 500, perdida_real: 0 },
    { tipo: 'parcial', motivo: 'producto_danado', casos: 1, unidades: 1, monto: 100, venta_perdida: 0, perdida_real: 60 },
  ],
  por_preventista: [
    { usuario_id: 'u1', nombre: 'Marcelo', pedidos_salieron: 10, pedidos_entregados: 9, rechazos_totales: 1, pedidos_con_salvedad: 1, lineas_salvedad: 1, monto: 600, venta_perdida: 500, perdida_real: 60, tasa_rechazo: 0.2 },
  ],
  por_chofer: [
    { transportista_id: 't1', nombre: 'Marcos', pedidos_salieron: 9, pedidos_entregados: 9, rechazos_totales: 0, pedidos_con_salvedad: 1, lineas_salvedad: 1, monto: 100, venta_perdida: 0, perdida_real: 60, tasa_rechazo: 0.1111 },
    { transportista_id: null, nombre: null, pedidos_salieron: 1, pedidos_entregados: 0, rechazos_totales: 1, pedidos_con_salvedad: 0, lineas_salvedad: 0, monto: 500, venta_perdida: 500, perdida_real: 0, tasa_rechazo: 1 },
  ],
  por_cliente: [
    { cliente_id: 7, nombre: 'Almacén Cerrado', codigo: 'A7', activo: false, rechazos_totales: 1, lineas_salvedad: 0, monto: 500, venta_perdida: 500, perdida_real: 0 },
  ],
  por_producto: [],
  detalle: [
    { ...filaBase, tipo: 'total', pedido_id: 100, salvedad_id: null, fecha: '2026-09-10', cliente_id: 7, cliente_nombre: 'Almacén Cerrado', cliente_activo: false, usuario_id: 'u1', preventista_nombre: 'Marcelo', transportista_id: null, chofer_nombre: null, motivo: 'cerrado', producto_id: null, producto_nombre: null, lineas: 2, unidades: 5, monto: 500, venta_perdida: 500, perdida_real: 0, destino: 'devuelto' },
    { ...filaBase, tipo: 'parcial', pedido_id: 101, salvedad_id: 9, fecha: '2026-09-11', cliente_id: 8, cliente_nombre: 'Kiosco Ana', usuario_id: 'u1', preventista_nombre: 'Marcelo', transportista_id: 't1', chofer_nombre: 'Marcos', motivo: 'producto_danado', producto_id: 3, producto_nombre: 'Coca 2L', lineas: 1, unidades: 1, monto: 100, venta_perdida: 0, perdida_real: 60, destino: 'mermado', estado_resolucion: 'pendiente' },
  ],
  detalle_total: 2,
  detalle_limite: 3000,
  detalle_truncado: false,
}

describe('ReporteRechazos', () => {
  beforeEach(() => {
    mockUseReporte.mockReset()
    mockEnabled.mockReset()
    mockCtx = { sucursales: [{ id: 1, nombre: 'Tucumán' }], hasMultipleSucursales: false, currentSucursalId: 1 }
    mockUseReporte.mockReturnValue({ data: datos, isLoading: false, error: null })
  })

  it('pide la sucursal activa y el período del preset por defecto', () => {
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    expect(mockUseReporte).toHaveBeenCalledWith(1, '2026-09-01', '2026-09-30')
    expect(mockEnabled).toHaveBeenLastCalledWith(true)
  })

  it('sin sucursal activa resuelta no consulta (null sería la red)', () => {
    mockCtx = { sucursales: [], hasMultipleSucursales: false, currentSucursalId: null }
    mockUseReporte.mockReturnValue({ data: undefined, isLoading: true, error: null })
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    expect(mockEnabled).toHaveBeenLastCalledWith(false)
  })

  it('los KPIs son los del RPC, con la venta perdida y la pérdida real separadas', () => {
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    expect(screen.getByTestId('kpi-tasa')).toHaveTextContent('9,3 %')
    expect(screen.getByTestId('kpi-rechazos')).toHaveTextContent('34 enteros · 61 líneas')
    expect(screen.getByTestId('kpi-venta-perdida')).toHaveTextContent(formatPrecio(1268640))
    expect(screen.getByTestId('kpi-perdida-real')).toHaveTextContent(formatPrecio(48954.62))
  })

  it('el corte por chofer muestra la tasa y al que no tenía chofer', async () => {
    const user = userEvent.setup()
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    await user.click(screen.getByRole('tab', { name: 'Por chofer' }))
    const tabla = screen.getByRole('table', { name: 'Por chofer' })
    expect(within(tabla).getByText('Marcos')).toBeInTheDocument()
    expect(within(tabla).getByText('Sin chofer')).toBeInTheDocument()
    expect(within(tabla).getByText('11,1 %')).toBeInTheDocument()
  })

  it('el cliente inactivo se sigue viendo (es historial)', async () => {
    const user = userEvent.setup()
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    await user.click(screen.getByRole('tab', { name: 'Por cliente' }))
    const tabla = screen.getByRole('table', { name: 'Por cliente' })
    expect(within(tabla).getByText('Almacén Cerrado')).toBeInTheDocument()
    expect(within(tabla).getByText('inactivo')).toBeInTheDocument()
  })

  it('filtrar el detalle achica la lista y su resumen, no los KPIs', async () => {
    const user = userEvent.setup()
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    const detalle = screen.getByRole('table', { name: 'Detalle de rechazos' })
    expect(within(detalle).getAllByRole('row')).toHaveLength(3)

    await user.selectOptions(screen.getByLabelText('Chofer'), '__sin__')
    expect(within(screen.getByRole('table', { name: 'Detalle de rechazos' })).getAllByRole('row')).toHaveLength(2)
    expect(screen.getByTestId('resumen-detalle')).toHaveTextContent('Lo filtrado: 1 pedidos enteros y 0 líneas')
    expect(screen.getByTestId('kpi-venta-perdida')).toHaveTextContent(formatPrecio(1268640))
  })

  it('muestra causas, no culpas: no hay columna de responsable', () => {
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    expect(screen.queryByText(/responsable:/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/culpa/i)).not.toBeInTheDocument()
    expect(screen.getByText(/No asigna responsables/)).toBeInTheDocument()
  })

  it('el error del RPC se muestra', () => {
    mockUseReporte.mockReturnValue({ data: undefined, isLoading: false, error: new Error('Acceso denegado') })
    render(<ReporteRechazos formatPrecio={formatPrecio} />)
    expect(screen.getByText(/No se pudo cargar el reporte de rechazos: Acceso denegado/)).toBeInTheDocument()
  })
})
