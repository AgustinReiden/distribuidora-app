/**
 * Precarga de la cache de TanStack Query.
 *
 * Los paneles y la campanita no reciben datos por props: los piden con su propio
 * `useQuery`. En vez de mockear módulos (no hay `vi.mock` en el navegador) ni tocar
 * `src/`, la galería escribe el resultado con `setQueryData` usando la MISMA
 * queryKey que el hook real. Con `staleTime: Infinity` en el QueryClient de la
 * galería, la query nunca se considera vencida y el `queryFn` no llega a correr.
 *
 * Si una queryKey cambia en `src/`, acá deja de matchear y el panel aparece vacío:
 * el import de `pedidosKeys` / `noEntregadosKeys` es a propósito, para que al menos
 * el nombre de la key siga siendo el mismo objeto.
 */
import type { QueryClient } from '@tanstack/react-query'
import { pedidosKeys, noEntregadosKeys } from '../../../src/hooks/queries'
import type { PedidoSinResolver, NotificacionDB } from '../../../src/hooks/queries'
import type { PedidoTrabado } from '../../../src/hooks/queries/usePedidosTrabadosQuery'
import { SUCURSAL_ID_FIXTURE } from './auth'

function hace(dias: number): string {
  const d = new Date()
  d.setDate(d.getDate() - dias)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function haceHoras(horas: number): string {
  return new Date(Date.now() - horas * 3_600_000).toISOString()
}

export const PEDIDOS_TRABADOS_FIXTURE: PedidoTrabado[] = [
  {
    id: '17904',
    fecha: hace(23),
    total: 74_300,
    clienteNombre: 'Almacén Don Ramón',
    transportistaId: '44444444-4444-4444-8444-444444444444',
    diasTrabado: 23,
  },
  {
    id: '18016',
    fecha: hace(14),
    total: 121_900,
    clienteNombre: 'Autoservicio Yerba Buena',
    transportistaId: '66666666-6666-4666-8666-666666666666',
    diasTrabado: 14,
  },
  {
    id: '18105',
    fecha: hace(9),
    total: 38_450,
    clienteNombre: 'Kiosco La Esquina',
    transportistaId: null,
    diasTrabado: 9,
  },
  {
    id: '18188',
    fecha: hace(5),
    total: 56_200,
    clienteNombre: 'Despensa El Trébol',
    transportistaId: '44444444-4444-4444-8444-444444444444',
    diasTrabado: 5,
  },
]

export const PEDIDOS_SIN_RESOLVER_FIXTURE: PedidoSinResolver[] = [
  { pedidoId: '18402', clienteNombre: 'Kiosco La Esquina', fecha: hace(4), total: 22_800 },
  { pedidoId: '18409', clienteNombre: 'Despensa El Trébol', fecha: hace(3), total: 41_150 },
  { pedidoId: '18417', clienteNombre: 'Almacén Don Ramón', fecha: hace(2), total: 67_900 },
  { pedidoId: '18419', clienteNombre: 'Autoservicio Yerba Buena', fecha: hace(1), total: 130_400 },
]

export const NOTIFICACIONES_FIXTURE: NotificacionDB[] = [
  {
    id: 9001,
    usuario_id: '11111111-1111-4111-8111-111111111111',
    sucursal_id: SUCURSAL_ID_FIXTURE,
    tipo: 'movimiento_pendiente',
    titulo: 'Movimiento pendiente de aceptar',
    mensaje: 'Taco Pozo te mandó 40 fardos de Manaos Cola 2,25 L.',
    entidad_tipo: 'movimiento_sucursal',
    entidad_id: 812,
    payload: null,
    leida: false,
    created_at: haceHoras(3),
    leida_at: null,
  },
  {
    id: 9000,
    usuario_id: '11111111-1111-4111-8111-111111111111',
    sucursal_id: SUCURSAL_ID_FIXTURE,
    tipo: 'cliente_duplicado',
    titulo: 'Alta de cliente bloqueada por duplicado',
    mensaje: 'Nahuel Juárez intentó cargar "La Esquina" y chocó con Kiosco La Esquina (#4012).',
    entidad_tipo: 'cliente',
    entidad_id: 4012,
    payload: null,
    leida: false,
    created_at: haceHoras(27),
    leida_at: null,
  },
  {
    id: 8994,
    usuario_id: '11111111-1111-4111-8111-111111111111',
    sucursal_id: SUCURSAL_ID_FIXTURE,
    tipo: 'rendicion',
    titulo: 'Rendición cerrada',
    mensaje: 'Gustavo Paz cerró la rendición del reparto con $1.204.300 en efectivo.',
    entidad_tipo: null,
    entidad_id: null,
    payload: null,
    leida: true,
    created_at: haceHoras(52),
    leida_at: haceHoras(50),
  },
]

export function sembrarCacheGaleria(qc: QueryClient): void {
  qc.setQueryData(
    [...pedidosKeys.all(SUCURSAL_ID_FIXTURE), 'trabados'],
    PEDIDOS_TRABADOS_FIXTURE,
  )
  qc.setQueryData(
    [...noEntregadosKeys.all(SUCURSAL_ID_FIXTURE), 'sin-resolver'],
    PEDIDOS_SIN_RESOLVER_FIXTURE,
  )
  qc.setQueryData(['notificaciones'], NOTIFICACIONES_FIXTURE)
}
