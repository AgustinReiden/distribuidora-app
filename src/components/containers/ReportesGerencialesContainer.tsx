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

/** Opciones de período: trimestre en curso + últimos 6 meses (el mes actual es parcial). */
function generarPeriodos(): PeriodoOpt[] {
  const hoy = new Date()
  const opts: PeriodoOpt[] = []

  const qStart = Math.floor(hoy.getMonth() / 3) * 3
  const qDesde = new Date(hoy.getFullYear(), qStart, 1)
  const qFin = new Date(hoy.getFullYear(), qStart + 3, 0)
  const qParcial = hoy < qFin
  opts.push({
    key: 'trimestre',
    label: `Trimestre ${MESES_ES[qStart].slice(0, 3)}–${MESES_ES[qStart + 2].slice(0, 3)} ${hoy.getFullYear()}`,
    desde: ymd(qDesde),
    hasta: ymd(qParcial ? hoy : qFin),
    esMes: false,
    periodoMes: null,
    parcial: qParcial,
  })

  for (let i = 0; i < 6; i++) {
    const d = new Date(hoy.getFullYear(), hoy.getMonth() - i, 1)
    const y = d.getFullYear()
    const m = d.getMonth()
    const ultimo = new Date(y, m + 1, 0)
    const esActual = i === 0
    opts.push({
      key: `${y}-${String(m + 1).padStart(2, '0')}`,
      label: `${MESES_ES[m]} ${y}`,
      desde: ymd(new Date(y, m, 1)),
      hasta: ymd(esActual ? hoy : ultimo),
      esMes: true,
      periodoMes: ymd(new Date(y, m, 1)),
      parcial: esActual,
    })
  }

  return opts
}

export default function ReportesGerencialesContainer(): React.ReactElement {
  const periodos = useMemo(() => generarPeriodos(), [])
  const [periodoSel, setPeriodoSel] = useState<PeriodoOpt>(() => periodos[0])

  // Sólo las sucursales que el usuario tiene asignadas (SucursalContext).
  // El backend (RPC) refuerza esto: un admin de una sola sucursal no puede ver
  // datos de otra ni el consolidado de la red.
  const { sucursales, hasMultipleSucursales, loading: sucLoading } = useSucursal()

  const opcionesSucursal: SucursalOpt[] = useMemo(() => {
    const list: SucursalOpt[] = sucursales.map(s => ({ id: s.id as number | null, nombre: s.nombre }))
    // El consolidado de red sólo se ofrece a quien tiene 2+ sucursales asignadas.
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list
  }, [sucursales, hasMultipleSucursales])

  // Default: red si tiene varias; su única sucursal si tiene una.
  const [sucursalSel, setSucursalSel] = useState<number | null | undefined>(undefined)
  useEffect(() => {
    if (sucursalSel === undefined && sucursales.length > 0) {
      setSucursalSel(hasMultipleSucursales ? null : sucursales[0].id)
    }
  }, [sucursales, hasMultipleSucursales, sucursalSel])

  const ready = sucursalSel !== undefined
  const sucParam = sucursalSel ?? null

  const { data: reporte, isLoading, error } = useReporteGerencialQuery(sucParam, periodoSel.desde, periodoSel.hasta, ready)
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
        opcionesPeriodo={periodos}
        onSucursal={setSucursalSel}
        onPeriodo={setPeriodoSel}
        analisis={analisis ?? null}
      />
    </Suspense>
  )
}
