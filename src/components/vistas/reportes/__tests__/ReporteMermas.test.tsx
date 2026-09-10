/**
 * Los casos vienen migrados de `ModalHistorialMermas.test.tsx`, que se borró
 * cuando el historial pasó a ser una pestaña de /reportes.
 *
 * Cambia la naturaleza de los fixtures: antes eran filas crudas de
 * `mermas_stock` y el componente hacía la aritmética; ahora son la respuesta
 * del RPC `reporte_mermas` (mig 226), que agrega en la base. Lo que se fija acá
 * es que la pantalla NO re-derive ni contradiga esos números.
 *
 * El caso del final es nuevo y es la razón de ser del rediseño: truncar la
 * lista ya no mueve los totales.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockCrearExcel = vi.fn()
const mockUseReporte = vi.fn()
const mockFetch = vi.fn()

vi.mock('../../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: unknown[], filename: string) => mockCrearExcel(hojas, filename),
}))

vi.mock('../../../../hooks/queries/useMermasReporteQuery', () => ({
  useMermasReporteQuery: (suc: unknown, desde: string, hasta: string, motivo: unknown) =>
    mockUseReporte(suc, desde, hasta, motivo),
  fetchReporteMermas: (...args: unknown[]) => mockFetch(...args),
  LIMITE_DETALLE_MERMAS: 2000,
}))

vi.mock('../../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ sucursales: [{ id: 1, nombre: 'Tucumán' }], hasMultipleSucursales: false }),
}))

// Período fijo: si no, el nombre del archivo depende del día en que corran.
vi.mock('../../../../utils/periodosReporte', () => ({
  presetsVentas: () => [
    { id: 'anio-2026', label: 'Año 2026', desde: '2026-01-01', hasta: '2026-09-07' },
    { id: 'mes-2026-09', label: 'Septiembre 2026 (en curso)', desde: '2026-09-01', hasta: '2026-09-07' },
  ],
}))

import { ReporteMermas } from '../ReporteMermas'

const formatPrecio = (v: number): string => `$${Math.round(v).toLocaleString('es-AR')}`

const detalle = [
  {
    id: 'm1', created_at: '2026-08-15T14:00:00Z', cantidad: 2, motivo: 'rotura', clasificacion: 'perdida',
    costo_unitario: 900, costo_total: 1800, precio_unitario: 3000, precio_total: 6000,
    origen_costo: 'congelado', producto_id: 'p1', producto_nombre: 'Coca 2L', producto_codigo: 'C2L',
    producto_categoria: 'Gaseosas', stock_anterior: 10, stock_nuevo: 8,
    usuario_id: 'u1', usuario_nombre: 'Jony', sucursal_id: '1', sucursal_nombre: 'Tucumán',
    observaciones: 'Se cayó el pallet',
  },
  {
    id: 'm2', created_at: '2026-05-10T14:00:00Z', cantidad: 5, motivo: 'vencimiento', clasificacion: 'perdida',
    costo_unitario: 300, costo_total: 1500, precio_unitario: 800, precio_total: 4000,
    origen_costo: 'estimado', producto_id: 'p2', producto_nombre: 'Agua 500', producto_codigo: 'A500',
    producto_categoria: 'Aguas', stock_anterior: 50, stock_nuevo: 45,
    usuario_id: null, usuario_nombre: null, sucursal_id: '1', sucursal_nombre: 'Tucumán',
    observaciones: null,
  },
  {
    id: 'm3', created_at: '2026-08-20T14:00:00Z', cantidad: 1, motivo: 'otro', clasificacion: 'ajuste',
    costo_unitario: null, costo_total: null, precio_unitario: 100, precio_total: 100,
    origen_costo: 'sin_costo', producto_id: 'p3', producto_nombre: 'Sin costo', producto_codigo: 'SC',
    producto_categoria: null, stock_anterior: 5, stock_nuevo: 4,
    usuario_id: 'u1', usuario_nombre: 'Jony', sucursal_id: '1', sucursal_nombre: 'Tucumán',
    observaciones: null,
  },
  // Reversión de promoción: cantidad NEGATIVA y fuera del total.
  {
    id: 'm5', created_at: '2026-08-22T14:00:00Z', cantidad: -3, motivo: 'promociones_reversion',
    clasificacion: 'promocion', costo_unitario: 900, costo_total: -2700,
    precio_unitario: 3000, precio_total: -9000, origen_costo: 'congelado',
    producto_id: 'p1', producto_nombre: 'Coca 2L', producto_codigo: 'C2L', producto_categoria: 'Gaseosas',
    stock_anterior: 90, stock_nuevo: 93, usuario_id: 'u1', usuario_nombre: 'Jony',
    sucursal_id: '1', sucursal_nombre: 'Tucumán', observaciones: null,
  },
]

const por_motivo = [
  { motivo: 'rotura', clasificacion: 'perdida', registros: 1, unidades: 2, costo: 1800, precio: 6000, filas_costo_estimado: 0, filas_sin_costo: 0 },
  { motivo: 'vencimiento', clasificacion: 'perdida', registros: 1, unidades: 5, costo: 1500, precio: 4000, filas_costo_estimado: 1, filas_sin_costo: 0 },
  { motivo: 'otro', clasificacion: 'ajuste', registros: 1, unidades: 1, costo: 0, precio: 100, filas_costo_estimado: 0, filas_sin_costo: 1 },
  { motivo: 'promociones_reversion', clasificacion: 'promocion', registros: 1, unidades: -3, costo: -2700, precio: -9000, filas_costo_estimado: 0, filas_sin_costo: 0 },
]

const totales = {
  registros: 3, unidades: 8, costo: 3300, precio: 10100,
  costo_perdida: 3300, costo_ajuste: 0, costo_muestra: 0,
  registros_ajuste_promocion: 1, unidades_ajuste_promocion: -3, costo_ajuste_promocion: -2700,
  filas_costo_estimado: 1, filas_sin_costo: 1,
}

function reporte(over: Record<string, unknown> = {}) {
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-01-01', hasta: '2026-09-07',
      generado_at: '2026-09-09T12:00:00Z', filtro_motivo: null,
      criterio: 'Mermas por dia argentino de carga…',
    },
    totales, por_motivo, detalle,
    detalle_total: detalle.length, detalle_limite: 500, detalle_truncado: false,
    ...over,
  }
}

/** El KPI "Pérdida a costo". El mismo número aparece en la fila TOTAL de la
 *  tabla —tienen que coincidir—, así que hay que aseverar acotado. */
function kpiPerdida(): HTMLElement {
  return screen.getByText('Pérdida a costo').parentElement as HTMLElement
}

function renderTab(data: unknown = reporte()) {
  mockUseReporte.mockReturnValue({ data, isLoading: false, error: null })
  return render(<ReporteMermas formatPrecio={formatPrecio} />)
}

describe('ReporteMermas', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('el filtro de fecha va al servidor', () => {
    it('le pasa el rango del preset al hook, no filtra en el cliente', () => {
      renderTab()
      expect(mockUseReporte).toHaveBeenCalledWith(null, '2026-01-01', '2026-09-07', null)
    })

    it('cambiar de período vuelve a consultar con el rango nuevo', async () => {
      renderTab()
      await userEvent.selectOptions(screen.getByLabelText(/Período/i), 'mes-2026-09')
      expect(mockUseReporte).toHaveBeenLastCalledWith(null, '2026-09-01', '2026-09-07', null)
    })

    it('el filtro de motivo también va al servidor: mueve los totales', async () => {
      renderTab()
      await userEvent.selectOptions(screen.getByLabelText(/^Motivo/i), 'rotura')
      expect(mockUseReporte).toHaveBeenLastCalledWith(null, '2026-01-01', '2026-09-07', 'rotura')
    })
  })

  describe('los ajustes de promoción quedan fuera del total', () => {
    it('la pérdida a costo es la del RPC, sin los ajustes de promoción', () => {
      renderTab()
      // 1800 + 1500 = 3300; el -2700 de la reversión no entra.
      expect(within(kpiPerdida()).getByText('$3.300')).toBeInTheDocument()
    })

    it('lo explica en pantalla en vez de esconderlos', () => {
      renderTab()
      expect(screen.getByText(/contrapartida en stock de un regalo/i)).toBeInTheDocument()
      // Y la tabla reconcilia: el total dice explícitamente qué deja afuera.
      expect(screen.getByText(/TOTAL PÉRDIDA \(sin ajustes de promoción\)/i)).toBeInTheDocument()
    })

    it('la fila de promoción se marca como fuera del total', () => {
      renderTab()
      expect(screen.getAllByText(/fuera del total/i).length).toBeGreaterThan(0)
    })
  })

  describe('las marcas de calidad del dato', () => {
    it('avisa de las filas valuadas al costo de hoy por no tener snapshot', () => {
      renderTab()
      expect(screen.getByText(/anteriores a que se guardara el costo del momento/i)).toBeInTheDocument()
      expect(screen.getAllByText(/costo estimado/i).length).toBeGreaterThan(0)
    })

    it('marca el producto sin costo cargado: $0 no es "no vale nada"', () => {
      renderTab()
      expect(screen.getByText(/no es que valgan \$0/i)).toBeInTheDocument()
      expect(screen.getAllByText(/sin costo/i).length).toBeGreaterThan(0)
    })

    it('aclara que el precio de venta es el de hoy', () => {
      renderTab()
      expect(screen.getByText(/el precio de venta es el de/i)).toBeInTheDocument()
    })
  })

  describe('los defectos de render que traía el modal', () => {
    it('una cantidad negativa no imprime el doble signo', () => {
      renderTab()
      expect(screen.getByText('+3')).toBeInTheDocument()
      expect(screen.queryByText('--3')).not.toBeInTheDocument()
    })

    it('promociones_reversion tiene etiqueta, no sale el string crudo', () => {
      renderTab()
      expect(screen.getAllByText('Reversión de promoción').length).toBeGreaterThan(0)
      expect(screen.queryByText('promociones_reversion')).not.toBeInTheDocument()
    })

    it('muestra quién registró la merma', () => {
      renderTab()
      expect(screen.getAllByText('Jony').length).toBeGreaterThan(0)
    })

    it('una merma sin usuario dice que no está registrado, no que es desconocido', () => {
      renderTab()
      expect(screen.getByText('Sin registrar')).toBeInTheDocument()
    })
  })

  describe('la búsqueda sólo achica la lista, no los totales', () => {
    it('filtra las filas pero deja la pérdida a costo intacta', async () => {
      renderTab()
      await userEvent.type(screen.getByLabelText(/Buscar en el detalle/i), 'Agua')
      expect(screen.getByText(/Mostrando 1 de 4 registros/i)).toBeInTheDocument()
      // El total sigue siendo el del período completo.
      expect(within(kpiPerdida()).getByText('$3.300')).toBeInTheDocument()
      // Y no vuelve a consultar: es puro cliente.
      expect(mockUseReporte).toHaveBeenLastCalledWith(null, '2026-01-01', '2026-09-07', null)
    })
  })

  describe('export a Excel', () => {
    it('baja tres hojas y la primera es Info', async () => {
      renderTab()
      await userEvent.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas, filename] = mockCrearExcel.mock.calls[0]
      expect(hojas.map((h: { name: string }) => h.name)).toEqual(['Info', 'Resumen por motivo', 'Detalle'])
      expect(filename).toBe('mermas-Tucumán-2026-01-01_2026-09-07')
    })

    it('Info lleva el criterio del RPC, no uno reescrito en el front', async () => {
      renderTab()
      await userEvent.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]
      const info = hojas[0].data as { Campo: string; Valor: unknown }[]
      expect(info.find((r) => r.Campo === 'Criterio')?.Valor).toBe('Mermas por dia argentino de carga…')
    })

    it('el detalle lleva el costo, el precio y de dónde salió cada costo', async () => {
      renderTab()
      await userEvent.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]
      const fila = (hojas[2].data as Record<string, unknown>[])[0]
      expect(fila).toMatchObject({
        Producto: 'Coca 2L',
        Motivo: 'Rotura',
        'Costo total': 1800,
        'Origen del costo': 'congelado',
      })
    })

    it('el resumen cierra con el total de pérdida y los ajustes aparte', async () => {
      renderTab()
      await userEvent.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      const [hojas] = mockCrearExcel.mock.calls[0]
      const filas = hojas[1].data as Record<string, unknown>[]
      const total = filas.find((f) => String(f.Motivo).startsWith('TOTAL PÉRDIDA'))
      const promo = filas.find((f) => String(f.Motivo).startsWith('Ajustes de promoción'))
      expect(total?.Costo).toBe(3300)
      expect(promo?.Costo).toBe(-2700)
    })

    it('no se puede exportar un período sin registros', () => {
      renderTab(reporte({ detalle: [], por_motivo: [], detalle_total: 0 }))
      expect(screen.getByRole('button', { name: /Exportar a Excel/i })).toBeDisabled()
    })

    it('si la lista está recortada, el Excel se rearma con el tope máximo', async () => {
      const truncado = reporte({ detalle_total: 900, detalle_truncado: true })
      mockFetch.mockResolvedValue(reporte({ detalle_total: 900, detalle_truncado: true }))
      renderTab(truncado)
      await userEvent.click(screen.getByRole('button', { name: /Exportar a Excel/i }))
      // Un Excel truncado en silencio es justo lo que este reporte vino a arreglar.
      expect(mockFetch).toHaveBeenCalledWith(null, '2026-01-01', '2026-09-07', null, 2000)
    })
  })

  describe('truncamiento', () => {
    it('avisa cuando la lista no entra entera', () => {
      renderTab(reporte({ detalle_total: 900, detalle_truncado: true }))
      expect(screen.getByText(/se listan los/i)).toBeInTheDocument()
    })

    it('no avisa cuando entran todas', () => {
      renderTab()
      expect(screen.queryByText(/se listan los/i)).not.toBeInTheDocument()
    })

    it('truncar la lista NO mueve los totales: son del período completo', () => {
      // Es la diferencia de fondo con el modal, donde el corte de 1.000 filas
      // de PostgREST alimentaba la suma y truncar cambiaba el número.
      renderTab(reporte({ detalle_total: 900, detalle_truncado: true }))
      expect(within(kpiPerdida()).getByText('$3.300')).toBeInTheDocument()
      expect(screen.getByText(/Los totales de arriba son del período completo/i)).toBeInTheDocument()
      expect(screen.getByText(/Mostrando 4 de 900 registros/i)).toBeInTheDocument()
    })
  })
})
