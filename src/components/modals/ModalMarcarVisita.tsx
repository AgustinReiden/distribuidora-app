/**
 * Modal "Marcar visita".
 *
 * Permite a un preventista registrar una visita a un cliente sin tener
 * que cargar pedido. Captura GPS y dispara `registrar_visita_cliente` al
 * confirmar.
 *
 * Reglas de geolocalización (post-052):
 * - Para preventistas, el modal está envuelto en `<GeolocationGate>` —
 *   si el permiso está `denied`, ven una pantalla bloqueante con
 *   instrucciones y nunca llegan al listado.
 * - Si la captura devuelve `denied` (raza con un cambio de permiso entre
 *   gate y click), bloqueamos y avisamos.
 * - Si devuelve `timeout`/`unavailable`/`error`, abrimos `ModalMotivoSinGps`
 *   pidiendo justificación escrita; sin motivo no se registra.
 * - Admin sigue pudiendo marcar visitas con o sin GPS (flujo histórico).
 *
 * Filtro de clientes: misma regla que el resto de la app — preventista ve
 * clientes sin `preventista_ids` asignados o asignados a él mismo. Admin ve
 * todos. (El backend re-valida en el RPC.)
 */
import React, { useMemo, useState, useRef, useEffect } from 'react'
import { Search, MapPin, Loader2, Check } from 'lucide-react'
import ModalBase from './ModalBase'
import GeolocationGate from '../GeolocationGate'
import ModalMotivoSinGps from './ModalMotivoSinGps'
import { useRegistrarVisitaMutation } from '../../hooks/queries'
import { useGeolocationCapture, type GpsResult, type GpsStatus } from '../../hooks/useGeolocationCapture'
import { useNotification } from '../../contexts/NotificationContext'
import type { ClienteDB } from '../../types'

interface ModalMarcarVisitaProps {
  clientes: ClienteDB[]
  userId: string | null
  isAdmin: boolean
  isPreventista: boolean
  onClose: () => void
}

function matchSearch(c: ClienteDB, q: string): boolean {
  if (!q) return true
  const needle = q.toLowerCase().trim()
  return (
    (c.nombre_fantasia || '').toLowerCase().includes(needle) ||
    (c.razon_social || '').toLowerCase().includes(needle) ||
    (c.direccion || '').toLowerCase().includes(needle) ||
    (c.cuit || '').toLowerCase().includes(needle)
  )
}

type MotivoPending = {
  cliente: ClienteDB
  status: Exclude<GpsStatus, 'ok' | 'denied'>
}

export default function ModalMarcarVisita({
  clientes,
  userId,
  isAdmin,
  isPreventista,
  onClose,
}: ModalMarcarVisitaProps): React.ReactElement {
  const [search, setSearch] = useState('')
  const [pendienteId, setPendienteId] = useState<string | null>(null)
  const [motivoPending, setMotivoPending] = useState<MotivoPending | null>(null)
  const capturarGps = useGeolocationCapture()
  const registrar = useRegistrarVisitaMutation()
  const notify = useNotification()
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  // Filtrado por rol: admin ve todos, preventista ve sin asignar + asignados a él.
  const clientesVisibles = useMemo<ClienteDB[]>(() => {
    const activos = clientes.filter(c => c.activo !== false)
    if (isAdmin) return activos
    if (!userId) return []
    return activos.filter(c => {
      const ids = c.preventista_ids
      if (!ids || ids.length === 0) return true
      return ids.includes(userId)
    })
  }, [clientes, isAdmin, userId])

  const filtrados = useMemo<ClienteDB[]>(() => {
    return clientesVisibles
      .filter(c => matchSearch(c, search))
      .sort((a, b) => (a.nombre_fantasia || '').localeCompare(b.nombre_fantasia || ''))
      .slice(0, 50)
  }, [clientesVisibles, search])

  const persistir = async (
    cliente: ClienteDB,
    gps: GpsResult,
    motivoOmision?: string,
  ): Promise<boolean> => {
    try {
      const res = await registrar.mutateAsync({
        clienteId: Number(cliente.id),
        status: gps.status,
        ...(gps.status === 'ok'
          ? { lat: gps.lat, lng: gps.lng, accuracy: gps.accuracy, capturadoAt: gps.capturadoAt }
          : {}),
        ...(motivoOmision ? { motivoOmision } : {}),
      })
      if (!res.success) {
        notify.error(res.error || 'No se pudo registrar la visita')
        return false
      }
      const msg =
        gps.status === 'ok'
          ? `Visita registrada en ${cliente.nombre_fantasia}`
          : `Visita registrada en ${cliente.nombre_fantasia} (sin GPS)`
      notify.success(msg)
      return true
    } catch (e) {
      notify.error('Error registrando visita: ' + (e as Error).message)
      return false
    }
  }

  const handleMarcar = async (cliente: ClienteDB) => {
    if (pendienteId || motivoPending) return
    setPendienteId(cliente.id)
    try {
      const gps = await capturarGps()

      // Admin: comportamiento histórico — registra siempre, sin bloqueo ni motivo.
      if (!isPreventista) {
        const ok = await persistir(cliente, gps)
        if (ok) onClose()
        return
      }

      // Preventista — reglas estrictas:
      if (gps.status === 'denied') {
        notify.error('Permiso de GPS bloqueado. Activalo desde el navegador y reintentá.')
        return
      }
      if (gps.status !== 'ok') {
        // Pasamos a ModalMotivoSinGps (permanece pendienteId hasta que confirme/cancele).
        setMotivoPending({ cliente, status: gps.status })
        return
      }
      const ok = await persistir(cliente, gps)
      if (ok) onClose()
    } finally {
      // Si quedó esperando motivo, no liberamos aún para que el listado no quede clickeable.
      if (!motivoPending) setPendienteId(null)
    }
  }

  const handleConfirmarMotivo = async (motivo: string) => {
    if (!motivoPending) return
    const { cliente, status } = motivoPending
    // Re-capturamos el GPS por si justo se obtuvo señal entre el primer intento
    // y el confirmar — pero no es bloqueante; aceptamos el status original.
    const gps: GpsResult = { status }
    const ok = await persistir(cliente, gps, motivo)
    setMotivoPending(null)
    setPendienteId(null)
    if (ok) onClose()
  }

  const handleCancelarMotivo = () => {
    setMotivoPending(null)
    setPendienteId(null)
  }

  return (
    <>
      <ModalBase title="Marcar visita" onClose={onClose} maxWidth="max-w-lg">
        <GeolocationGate enabled={isPreventista} onCancel={onClose}>
          <div className="space-y-3">
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Elegí el cliente que estás visitando. Vamos a registrar tu ubicación actual junto con la visita.
            </p>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" aria-hidden />
              <input
                ref={inputRef}
                type="text"
                value={search}
                onChange={e => setSearch(e.target.value)}
                placeholder="Buscar por nombre, razón social, CUIT o dirección"
                className="w-full pl-9 pr-3 py-2 text-sm rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
            </div>

            {filtrados.length === 0 ? (
              <div className="py-8 text-center text-sm text-gray-500 dark:text-gray-400">
                {clientesVisibles.length === 0
                  ? 'No tenés clientes visibles para marcar visita.'
                  : 'Ningún cliente coincide con la búsqueda.'}
              </div>
            ) : (
              <ul className="max-h-[55vh] overflow-y-auto divide-y divide-gray-100 dark:divide-gray-700 rounded-lg border border-gray-200 dark:border-gray-700">
                {filtrados.map(c => {
                  const isPending = pendienteId === c.id
                  const isAnyPending = pendienteId !== null
                  return (
                    <li key={c.id}>
                      <button
                        type="button"
                        onClick={() => handleMarcar(c)}
                        disabled={isAnyPending}
                        className="w-full text-left px-3 py-2.5 hover:bg-gray-50 dark:hover:bg-gray-700/50 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-3"
                      >
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-medium text-gray-900 dark:text-white truncate">
                            {c.nombre_fantasia || c.razon_social || 'Sin nombre'}
                          </p>
                          {c.direccion && (
                            <p className="text-xs text-gray-500 dark:text-gray-400 truncate flex items-center gap-1">
                              <MapPin className="w-3 h-3" />
                              {c.direccion}
                            </p>
                          )}
                        </div>
                        {isPending ? (
                          <Loader2 className="w-4 h-4 text-blue-500 animate-spin shrink-0" />
                        ) : (
                          <Check className="w-4 h-4 text-gray-300 dark:text-gray-600 shrink-0" />
                        )}
                      </button>
                    </li>
                  )
                })}
              </ul>
            )}

            {clientesVisibles.length > filtrados.length && (
              <p className="text-xs text-gray-400 dark:text-gray-500 text-center">
                Mostrando {filtrados.length} de {clientesVisibles.length}. Afiná la búsqueda para ver más.
              </p>
            )}
          </div>
        </GeolocationGate>
      </ModalBase>

      {motivoPending && (
        <ModalMotivoSinGps
          status={motivoPending.status}
          guardando={registrar.isPending}
          onConfirm={handleConfirmarMotivo}
          onCancel={handleCancelarMotivo}
        />
      )}
    </>
  )
}
