/**
 * Avisos: todo lo que se dibuja con `position: fixed` y se superpone con el resto.
 *
 * Por eso van detrás del interruptor "Avisos fijos" de la barra de arriba y, de
 * los que se pisan entre sí, se muestra uno por vez: `OfflineIndicator` vive en
 * `bottom-4 right-4` y `SyncStatusBanner` en `bottom-4 left-4 right-4`, así que
 * renderizarlos juntos sólo muestra el de arriba.
 *
 * `SyncStatusBanner` no recibe datos por props: los lee de Dexie (`offlineDb`) con
 * un poll. La galería le siembra una operación fallida en la IndexedDB de SU
 * propio origen (localhost:5174, distinto del de la app) y la borra al salir.
 */
import { useEffect, useState } from 'react'
import OfflineIndicator from '../../../src/components/layout/OfflineIndicator'
import { SyncStatusBanner } from '../../../src/components/SyncStatusBanner'
import { useNotification } from '../../../src/contexts/NotificationContext'
import { db } from '../../../src/lib/offlineDb'
import { FueraDeLaV1, Marco, Seccion, Subtitulo } from '../ui/Marco'

type AvisoFijo = 'ninguno' | 'offline' | 'pendientes' | 'sincronizando' | 'sync'

const OPCIONES: Array<{ valor: AvisoFijo; etiqueta: string }> = [
  { valor: 'ninguno', etiqueta: 'Ninguno' },
  { valor: 'offline', etiqueta: 'OfflineIndicator · sin conexión' },
  { valor: 'pendientes', etiqueta: 'OfflineIndicator · online con pendientes' },
  { valor: 'sincronizando', etiqueta: 'OfflineIndicator · sincronizando' },
  { valor: 'sync', etiqueta: 'SyncStatusBanner · 2 operaciones fallidas' },
]

const PEDIDOS_OFFLINE = [
  {
    offlineId: 'off-1',
    clienteId: '4012',
    clienteNombre: 'Kiosco La Esquina',
    items: [
      { producto_id: '101', cantidad: 12 },
      { producto_id: '110', cantidad: 8 },
    ],
    total: 28_700,
    creadoOffline: new Date(Date.now() - 42 * 60_000).toISOString(),
  },
  {
    offlineId: 'off-2',
    clienteId: '4290',
    clienteNombre: 'Despensa El Trébol',
    items: [{ producto_id: '216', cantidad: 24 }],
    total: 41_150,
    creadoOffline: new Date(Date.now() - 11 * 60_000).toISOString(),
  },
]

const MERMAS_OFFLINE = [
  { offlineId: 'mer-1', productoNombre: 'Manaos Naranja 2,25 L', cantidad: 3, motivo: 'rotura' },
]

const BOTON =
  'inline-flex items-center gap-2 h-10 px-4 rounded-lg text-sm font-medium bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200 border border-stone-200 dark:border-gray-700 shadow-warm hover:bg-stone-50 dark:hover:bg-gray-700/50 transition-colors'

function BotonesToast() {
  const notify = useNotification()

  return (
    <Marco etiqueta="useNotification() · los cuatro tipos de toast (abajo a la derecha, z-[100])">
      <div className="flex flex-wrap gap-2">
        <button
          type="button"
          className={BOTON}
          onClick={() => notify.success('Pedido #18420 creado.')}
        >
          success
        </button>
        <button
          type="button"
          className={BOTON}
          onClick={() =>
            notify.error('No se pudo registrar el pago: el cliente tiene otra sesión abierta.', {
              persist: false,
            })
          }
        >
          error
        </button>
        <button
          type="button"
          className={BOTON}
          onClick={() =>
            notify.warning('Quedan 2 operaciones sin sincronizar en este dispositivo.')
          }
        >
          warning
        </button>
        <button
          type="button"
          className={BOTON}
          onClick={() => notify.info('La ruta del día se recalculó con 3 paradas nuevas.')}
        >
          info
        </button>
      </div>
    </Marco>
  )
}

export default function SeccionAvisos({ mostrarFijos }: { mostrarFijos: boolean }) {
  const [aviso, setAviso] = useState<AvisoFijo>('ninguno')
  const activo: AvisoFijo = mostrarFijos ? aviso : 'ninguno'

  // Siembra la cola de Dexie sólo mientras el banner está elegido, y la limpia al
  // salir: si quedara escrita, el banner volvería a aparecer en la próxima carga.
  useEffect(() => {
    if (activo !== 'sync') return undefined

    const ahora = new Date()
    void db.pendingOperations.bulkAdd([
      {
        type: 'CREATE_PEDIDO',
        payload: { clienteId: '4118' },
        status: 'failed',
        retryCount: 5,
        maxRetries: 5,
        lastError:
          'Cliente asignado a otro preventista: Almacén Don Ramón (#4118) lo atiende Carla Ávila',
        hash: 'galeria-1',
        createdAt: ahora,
        updatedAt: ahora,
      },
      {
        type: 'SYNC_PAGO',
        payload: { pedidoId: '18371' },
        status: 'failed',
        retryCount: 5,
        maxRetries: 5,
        lastError: 'Failed to fetch',
        hash: 'galeria-2',
        createdAt: ahora,
        updatedAt: ahora,
      },
    ])

    return () => {
      void db.pendingOperations.clear()
    }
  }, [activo])

  return (
    <Seccion
      id="avisos"
      titulo="Avisos"
      descripcion={
        <>
          Todos son <code>position: fixed</code> y se tapan entre sí. El interruptor
          &ldquo;Avisos fijos&rdquo; de la barra de arriba los apaga a todos; acá se elige
          cuál mostrar.
        </>
      }
    >
      <div>
        <Subtitulo>Aviso fijo a mostrar</Subtitulo>
        <Marco etiqueta="el aviso aparece anclado a la ventana, no dentro de este marco">
          <div className="flex flex-wrap items-center gap-3">
            <label htmlFor="galeria-aviso" className="text-sm text-stone-700 dark:text-stone-300">
              Variante
            </label>
            <select
              id="galeria-aviso"
              value={aviso}
              disabled={!mostrarFijos}
              onChange={(e) => setAviso(e.target.value as AvisoFijo)}
              className="h-9 rounded-lg border border-stone-300 dark:border-gray-700 bg-white dark:bg-gray-800 px-3 text-sm text-stone-800 dark:text-gray-200 disabled:opacity-50"
            >
              {OPCIONES.map((o) => (
                <option key={o.valor} value={o.valor}>
                  {o.etiqueta}
                </option>
              ))}
            </select>
            {!mostrarFijos && (
              <span className="text-xs text-amber-700 dark:text-amber-400">
                Prendé &ldquo;Avisos fijos&rdquo; arriba para verlos.
              </span>
            )}
          </div>
        </Marco>
      </div>

      <BotonesToast />

      <FueraDeLaV1>
        <p>
          <strong>BannerActualizacion</strong> no se puede forzar sin tocar{' '}
          <code>src/</code>. Su estado sale entero de{' '}
          <code>useActualizacionDisponible</code>: el inicial es{' '}
          <code>hayActualizacionSWEsperando()</code> (
          <code>src/hooks/useActualizacionDisponible.ts:55</code>), que sin service worker
          registrado siempre da <code>false</code>; y el chequeo de{' '}
          <code>/version.json</code> está apagado en desarrollo por{' '}
          <code>const activo = !import.meta.env.DEV</code> (línea 58). El hook no acepta
          ningún override y el componente no recibe props.
        </p>
      </FueraDeLaV1>

      {activo === 'offline' && <OfflineIndicator isOnline={false} />}
      {activo === 'pendientes' && (
        <OfflineIndicator
          isOnline
          pedidosPendientes={PEDIDOS_OFFLINE}
          mermasPendientes={MERMAS_OFFLINE}
          onSincronizar={() => {}}
        />
      )}
      {activo === 'sincronizando' && (
        <OfflineIndicator
          isOnline
          pedidosPendientes={PEDIDOS_OFFLINE}
          mermasPendientes={MERMAS_OFFLINE}
          sincronizando
          onSincronizar={() => {}}
        />
      )}
      {activo === 'sync' && <SyncStatusBanner pollInterval={1000} />}
    </Seccion>
  )
}
