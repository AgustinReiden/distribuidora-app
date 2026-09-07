import React, { Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useCalcularComisionesQuery, usePreventistasQuery } from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { lazyWithReload } from '../../utils/lazyWithReload'

const VistaComisiones = lazyWithReload(() => import('../vistas/VistaComisiones'))
const ModalComisionReglas = lazyWithReload(() => import('../modals/ModalComisionReglas'))

function LoadingState(): React.ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

function getPrimerDiaMes(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}

function getHoy(): string {
  return fechaLocalISO()
}

export default function ComisionesContainer(): React.ReactElement {
  const notify = useNotification()
  const { isAdmin } = useAuthData()
  const [fechaDesde, setFechaDesde] = useState(getPrimerDiaMes)
  const [fechaHasta, setFechaHasta] = useState(getHoy)
  const [modalReglasOpen, setModalReglasOpen] = useState(false)

  // El cálculo lo resuelve la DB (mig 150): misma base que el reporte gerencial
  // y % por regla vigente, en vez del `ventas × % tipeado` que había acá.
  const { data: resultado, isLoading, error } = useCalcularComisionesQuery(fechaDesde, fechaHasta)
  const { data: padronPreventistas = [] } = usePreventistasQuery()

  // La lista del desplegable sale de los DATOS, no de los roles. Precedente
  // escrito en la mig 198: un desplegable filtrado por rol escondía $32,8M de
  // venta real. Acá el filtro por rol dejaba afuera a admins y encargados, que
  // comisionan igual —`calcular_comisiones` agrupa por `pedidos.usuario_id` sin
  // mirar rol (mig 150)— y por eso no había forma de asignarles un %.
  //
  // Unión de dos fuentes: quien efectivamente vendió en el período, sea cual
  // sea su rol, y el padrón de preventistas de la sucursal, para el que todavía
  // no vendió. Un admin o encargado sin ventas en el período no aparece: no
  // tiene comisión que configurar hasta que venda, y aparece solo con ampliar
  // el rango de fechas.
  const preventistas = useMemo(() => {
    const porId = new Map<string, string>()
    const nombreDe = (n: string | null, e: string | null): string => n || e || 'Sin nombre'
    for (const p of resultado?.preventistas ?? []) {
      porId.set(p.id, nombreDe(p.nombre, p.email))
    }
    for (const p of padronPreventistas) {
      if (!porId.has(p.id)) porId.set(p.id, nombreDe(p.nombre ?? null, p.email ?? null))
    }
    return [...porId]
      .map(([id, nombre]) => ({ id, nombre }))
      .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
  }, [resultado, padronPreventistas])

  useEffect(() => {
    if (error) {
      notify.error((error as Error).message || 'Error al cargar comisiones')
    }
  }, [error, notify])

  const handleFiltrar = useCallback((desde: string, hasta: string) => {
    setFechaDesde(desde)
    setFechaHasta(hasta)
  }, [])

  return (
    <>
      <Suspense fallback={<LoadingState />}>
        <VistaComisiones
          resultado={resultado}
          loading={isLoading}
          fechaDesde={fechaDesde}
          fechaHasta={fechaHasta}
          onFiltrar={handleFiltrar}
          onAbrirReglas={isAdmin ? () => setModalReglasOpen(true) : undefined}
        />
      </Suspense>

      {modalReglasOpen && (
        <Suspense fallback={null}>
          <ModalComisionReglas
            preventistas={preventistas}
            comisionDefault={resultado?.comision_default ?? 2}
            onClose={() => setModalReglasOpen(false)}
          />
        </Suspense>
      )}
    </>
  )
}
