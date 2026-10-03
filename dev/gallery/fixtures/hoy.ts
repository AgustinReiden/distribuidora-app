/**
 * Fixtures de la pantalla "Hoy" del preventista (WP-48, #773).
 *
 * Los consumen la sección Hoy de la galería y `VistaHoy.test.tsx`: una sola
 * fuente, así el test y lo que se ve en la galería hablan de los mismos datos.
 * Si `VisitaHoy` o `AvanceMetasResultado` cambian, esto rompe en
 * `npm run typecheck`.
 */
import type { AvanceMetasResultado } from '../../../src/hooks/queries'
import type { VisitaHoy } from '../../../src/hooks/queries/useVisitasQuery'
import { AVANCE_METAS_DASHBOARD } from './dashboard'

/** Lunes 21 de septiembre de 2026, a media mañana en Tucumán (12:00 UTC-3). */
export const FECHA_HOY = new Date('2026-09-21T15:00:00Z')

/** Los mismos objetivos del dashboard, al día 21 del mes. */
export const AVANCE_METAS_HOY: AvanceMetasResultado = {
  ...AVANCE_METAS_DASHBOARD,
  dias_transcurridos: 21,
  metas: AVANCE_METAS_DASHBOARD.metas.map(meta => ({ ...meta, dias_transcurridos: 21 })),
}

/** Sin metas cargadas: el panel de objetivos no se muestra. */
export const SIN_METAS_HOY: AvanceMetasResultado = {
  ...AVANCE_METAS_DASHBOARD,
  resumen: { total: 0, cumplidas: 0, en_riesgo: 0 },
  metas: [],
}

function visita(parcial: Partial<VisitaHoy> & Pick<VisitaHoy, 'visita_id' | 'created_at'>): VisitaHoy {
  return {
    cliente_id: 4000 + parcial.visita_id,
    cliente_nombre: null,
    cliente_direccion: null,
    cliente_lat: -26.8241,
    cliente_lng: -65.2226,
    gps_lat: -26.8243,
    gps_lng: -65.2229,
    gps_status: 'ok',
    gps_capturado_at: parcial.created_at,
    distancia_m: 40,
    ...parcial,
  }
}

/**
 * Cuatro visitas en el orden en que las devuelve `listar_visitas_hoy` (por
 * hora): una en el cliente, una cerca, una sin GPS y una lejos, para ver los
 * cuatro badges.
 */
export const VISITAS_HOY: VisitaHoy[] = [
  visita({
    visita_id: 1,
    created_at: '2026-09-21T12:10:00Z',
    cliente_nombre: 'Kiosco La Esquina',
    cliente_direccion: 'San Martín 450, San Miguel de Tucumán',
    distancia_m: 35,
  }),
  visita({
    visita_id: 2,
    created_at: '2026-09-21T12:45:00Z',
    cliente_nombre: 'Autoservicio Don Pepe',
    cliente_direccion: 'Av. Mate de Luna 2100',
    distancia_m: 640,
  }),
  visita({
    visita_id: 3,
    created_at: '2026-09-21T13:20:00Z',
    cliente_nombre: 'Almacén Lucía',
    cliente_direccion: 'Lamadrid 1200',
    gps_status: 'denied',
    gps_lat: null,
    gps_lng: null,
    gps_capturado_at: null,
    distancia_m: null,
  }),
  visita({
    visita_id: 4,
    created_at: '2026-09-21T14:05:00Z',
    cliente_nombre: 'Despensa El Sol de Yerba Buena con nombre largo',
    cliente_direccion: 'Av. Aconquija 3500, Yerba Buena',
    distancia_m: 1850,
  }),
]
