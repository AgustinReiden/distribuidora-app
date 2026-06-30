import React, { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useReporteGerencialQuery, useAnalisisMensualQuery } from '../../hooks/queries'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PeriodoOpt, SucursalOpt } from '../vistas/VistaReportesGerenciales'

const VistaReportesGerenciales = lazy(() => import('../vistas/VistaReportesGerenciales'))

const MESES_ES = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre']

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/**
 * Presets de fecha tipo BI. El primero (Este mes) es el default — NO hay un
 * trimestre hardcodeado. Además del listado, el usuario puede elegir un rango
 * personalizado (manejado vía onRango en la vista).
 */
function generarPeriodos(): PeriodoOpt[] {
  const hoy = new Date()
  const y = hoy.getFullYear()
  const m = hoy.getMonth()
  const hoyYmd = ymd(hoy)
  const opts: PeriodoOpt[] = []
  const add = (key: string, label: string, desde: Date, hasta: Date, esMes = false, periodoMes: Date | null = null) => {
    opts.push({
      key, label,
      desde: ymd(desde), hasta: ymd(hasta > hoy ? hoy : hasta),
      esMes, periodoMes: periodoMes ? ymd(periodoMes) : null,
      parcial: ymd(hasta) >= hoyYmd, // el período llega hasta hoy ⇒ todavía abierto
    })
  }

  add('mes-actual', 'Este mes', new Date(y, m, 1), hoy, true, new Date(y, m, 1))
  const pm = new Date(y, m - 1, 1)
  add('mes-pasado', 'Mes pasado', pm, new Date(y, m, 0), true, pm)
  const qStart = Math.floor(m / 3) * 3
  add('trimestre', 'Trimestre en curso', new Date(y, qStart, 1), hoy)
  add('anio', 'Año en curso', new Date(y, 0, 1), hoy)
  // Meses anteriores (para el análisis narrativo guardado por mes).
  for (let i = 2; i < 12; i++) {
    const d = new Date(y, m - i, 1)
    const yy = d.getFullYear()
    const mm = d.getMonth()
    add(`${yy}-${String(mm + 1).padStart(2, '0')}`, `${MESES_ES[mm]} ${yy}`, new Date(yy, mm, 1), new Date(yy, mm + 1, 0), true, new Date(yy, mm, 1))
  }
  return opts
}

function periodoCustom(desde: string, hasta: string): PeriodoOpt {
  return {
    key: 'custom',
    label: desde && hasta ? `${desde} → ${hasta}` : 'Personalizado',
    desde, hasta,
    esMes: false, periodoMes: null,
    parcial: hasta >= ymd(new Date()),
  }
}

export default function ReportesGerencialesContainer(): React.ReactElement {
  const periodos = useMemo(() => generarPeriodos(), [])
  // Opción "Personalizado" al final del selector (rango default: últimos 30 días).
  const customDefault = useMemo(() => {
    const hoy = new Date()
    const hace30 = new Date(hoy.getTime() - 29 * 24 * 60 * 60 * 1000)
    return periodoCustom(ymd(hace30), ymd(hoy))
  }, [])
  const opcionesPeriodo = useMemo<PeriodoOpt[]>(() => [...periodos, customDefault], [periodos, customDefault])

  const [periodoSel, setPeriodoSel] = useState<PeriodoOpt>(() => periodos[0]) // default: Este mes
  const [incluirNoEntregados, setIncluirNoEntregados] = useState(false)

  // Cambia el rango personalizado (date pickers de la vista).
  const onRango = (desde: string, hasta: string) => {
    if (!desde || !hasta || desde > hasta) return
    setPeriodoSel(periodoCustom(desde, hasta))
  }

  const { sucursales, hasMultipleSucursales, loading: sucLoading } = useSucursal()

  const opcionesSucursal: SucursalOpt[] = useMemo(() => {
    const list: SucursalOpt[] = sucursales.map(s => ({ id: s.id as number | null, nombre: s.nombre }))
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list
  }, [sucursales, hasMultipleSucursales])

  const [sucursalSel, setSucursalSel] = useState<number | null | undefined>(undefined)
  useEffect(() => {
    if (sucursalSel === undefined && sucursales.length > 0) {
      setSucursalSel(hasMultipleSucursales ? null : sucursales[0].id)
    }
  }, [sucursales, hasMultipleSucursales, sucursalSel])

  const ready = sucursalSel !== undefined
  const sucParam = sucursalSel ?? null

  const { data: reporte, isLoading, error } = useReporteGerencialQuery(sucParam, periodoSel.desde, periodoSel.hasta, incluirNoEntregados, ready)
  const { data: analisis } = useAnalisisMensualQuery(sucParam, periodoSel.periodoMes, ready && periodoSel.esMes)

  return (
    <Suspense fallback={<div className="flex items-center justify-center py-20"><Loader2 className="w-8 h-8 animate-spin text-blue-600" /></div>}>
      <VistaReportesGerenciales
        reporte={reporte}
        loading={isLoading || !ready || sucLoading}
        error={error ? (error as Error).message : null}
        sucursalSel={sucParam}
        periodoSel={periodoSel}
        opcionesSucursal={opcionesSucursal}
        opcionesPeriodo={opcionesPeriodo}
        onSucursal={setSucursalSel}
        onPeriodo={setPeriodoSel}
        onRango={onRango}
        incluirNoEntregados={incluirNoEntregados}
        onIncluirNoEntregados={setIncluirNoEntregados}
        analisis={analisis ?? null}
      />
    </Suspense>
  )
}
