import React, { lazy, Suspense, useMemo, useState } from 'react'
import { Loader2 } from 'lucide-react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useReporteGerencialQuery, useAnalisisMensualQuery } from '../../hooks/queries'
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

  // Trimestre en curso
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

  // Últimos 6 meses
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
  const [sucursalSel, setSucursalSel] = useState<number | null>(null) // null = red consolidada

  const { data: sucursalesDb } = useQuery({
    queryKey: ['sucursales-activas-reporte'],
    queryFn: async () => {
      const { data, error } = await supabase.from('sucursales').select('id, nombre').eq('activa', true).order('id')
      if (error) throw new Error(error.message)
      return data as { id: number; nombre: string }[]
    },
    staleTime: 60 * 60 * 1000,
  })

  const opcionesSucursal: SucursalOpt[] = useMemo(() => {
    const list = (sucursalesDb ?? []).map(s => ({ id: s.id as number | null, nombre: s.nombre }))
    return [{ id: null, nombre: 'Red (consolidado)' }, ...list]
  }, [sucursalesDb])

  const { data: reporte, isLoading, error } = useReporteGerencialQuery(sucursalSel, periodoSel.desde, periodoSel.hasta)
  const { data: analisis } = useAnalisisMensualQuery(sucursalSel, periodoSel.periodoMes, periodoSel.esMes)

  return (
    <Suspense fallback={<div className="flex items-center justify-center py-20"><Loader2 className="w-8 h-8 animate-spin text-blue-600" /></div>}>
      <VistaReportesGerenciales
        reporte={reporte}
        loading={isLoading}
        error={error ? (error as Error).message : null}
        sucursalSel={sucursalSel}
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
