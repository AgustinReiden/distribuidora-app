/**
 * Métricas de fixture para `VistaDashboard`.
 *
 * Datos verosímiles de una distribuidora de Tucumán, en pesos. Los consume la
 * sección Dashboard de la galería y el test de caracterización por rol
 * (`VistaDashboard.porRol.test.tsx`): una sola fuente, así el test y lo que se ve
 * en la galería hablan de los mismos números. Si `DashboardMetricasExtended`
 * cambia, esto rompe en `npm run typecheck`.
 */
import type { DashboardMetricasExtended, ProductoDB } from '../../../src/types'
import type { AvanceMetasResultado } from '../../../src/hooks/queries'
import { PRODUCTOS_FIXTURE } from './catalogo'

export const METRICAS_DASHBOARD: DashboardMetricasExtended = {
  ventasPeriodo: 4850000,
  ventasEnCurso: 920000,
  pedidosPeriodo: 64,
  pedidosEntregados: 50,
  pedidosEnCurso: 9,
  ventasPeriodoAnterior: 4200000,
  pedidosPeriodoAnterior: 58,
  productosMasVendidos: [
    { id: '101', nombre: 'Manaos Cola 2,25 L', cantidad: 1240 },
    { id: '102', nombre: 'Manaos Naranja 2,25 L', cantidad: 980 },
    { id: '110', nombre: 'Soda sifón 1,5 L', cantidad: 720 },
    { id: '120', nombre: 'Yerba mate 1 kg', cantidad: 415 },
    { id: '130', nombre: 'Fideos tirabuzón 500 g', cantidad: 260 },
  ],
  clientesMasActivos: [
    { id: '4012', nombre: 'Kiosco La Esquina', total: 610000, pedidos: 9 },
    { id: '4020', nombre: 'Autoservicio Don Pepe', total: 540000, pedidos: 7 },
  ],
  pedidosPorEstado: { pendiente: 5, asignado: 9, entregado: 50 },
  ventasPorDia: [
    { dia: 'lun', ventas: 610000, pedidos: 8 },
    { dia: 'mar', ventas: 745000, pedidos: 10 },
    { dia: 'mié', ventas: 520000, pedidos: 7 },
    { dia: 'jue', ventas: 890000, pedidos: 12 },
    { dia: 'vie', ventas: 1020000, pedidos: 14 },
    { dia: 'sáb', ventas: 430000, pedidos: 6 },
    { dia: 'dom', ventas: 0, pedidos: 0 },
  ],
}

export const TOTAL_CLIENTES_DASHBOARD = 187

/** Dos productos bajo su mínimo, para la alerta de stock bajo. */
export const PRODUCTOS_STOCK_BAJO_DASHBOARD: ProductoDB[] = [
  { ...PRODUCTOS_FIXTURE.manaosCola, stock: 40 },
  { ...PRODUCTOS_FIXTURE.manaosNaranja, stock: 25 },
]

/** Objetivos del mes, para el panel "Mis objetivos". */
export const AVANCE_METAS_DASHBOARD: AvanceMetasResultado = {
  preventista_id: 'fixture-preventista',
  nombre: 'Preventista de fixture',
  periodo: '2026-09-01',
  dias_transcurridos: 20,
  dias_periodo: 30,
  resumen: { total: 2, cumplidas: 1, en_riesgo: 0 },
  productos_sin_marca: 0,
  metas: [
    {
      id: 1,
      tipo_meta: 'facturacion',
      unidad: '$',
      alcance: { tipo: 'global', id: null, nombre: null },
      desde: '2026-09-01',
      hasta: '2026-09-30',
      dias_periodo: 30,
      dias_transcurridos: 20,
      periodo_personalizado: false,
      objetivo: 6000000,
      logrado: 4850000,
      pct: 80.8,
      objetivo_prorrateado: 4000000,
      estado: 'adelantado',
      marca_id: null,
      categoria_id: null,
      producto_ids: null,
    },
    {
      id: 2,
      tipo_meta: 'clientes_nuevos',
      unidad: 'clientes',
      alcance: { tipo: 'global', id: null, nombre: null },
      desde: '2026-09-01',
      hasta: '2026-09-30',
      dias_periodo: 30,
      dias_transcurridos: 20,
      periodo_personalizado: false,
      objetivo: 5,
      logrado: 5,
      pct: 100,
      objetivo_prorrateado: 3.33,
      estado: 'cumplida',
      marca_id: null,
      categoria_id: null,
      producto_ids: null,
    },
  ],
}
