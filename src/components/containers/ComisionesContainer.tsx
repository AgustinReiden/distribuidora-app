import React, { Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useCalcularComisionesQuery, useVendedoresComisionablesQuery } from '../../hooks/queries'
import { vendedoresElegibles } from '../../utils/vendedoresComision'
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
  const { data: padron = [] } = useVendedoresComisionablesQuery()

  // El padrón —quienes PUEDEN vender— es el piso, así la lista no cambia al
  // cambiar el rango de fechas; `resultado.preventistas` sólo suma al que ya
  // no está en el padrón pero tiene comisión acumulada. La regla vive en
  // `vendedoresElegibles`, con tests.
  const preventistas = useMemo(
    () => vendedoresElegibles(padron, resultado?.preventistas),
    [padron, resultado],
  )

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
            comisionPreventista={resultado?.comision_pct_preventista ?? resultado?.comision_default ?? 2}
            comisionOtros={resultado?.comision_pct_otros ?? 0}
            onClose={() => setModalReglasOpen(false)}
          />
        </Suspense>
      )}
    </>
  )
}
