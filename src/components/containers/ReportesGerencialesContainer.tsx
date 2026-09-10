import React, { Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import { useReporteGerencialQuery, useAnalisisMensualQuery, useMetasGerencialQuery, useGuardarMetaMutation, useCalcularComisionesQuery } from '../../hooks/queries'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PeriodoOpt, SucursalOpt } from '../vistas/VistaReportesGerenciales'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { escribirRango, escribirSucursal, leerRango, leerSucursal } from '../../utils/paramsReporte'

const VistaReportesGerenciales = lazyWithReload(() => import('../vistas/VistaReportesGerenciales'))

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

  // El período y la sucursal viven en la URL para que "Ver detalle" pueda
  // llevarlos a /reportes, el link sea compartible y el reload los conserve.
  // Los toggles de abajo NO: son exclusivos de esta pantalla.
  const [searchParams, setSearchParams] = useSearchParams()
  const rangoUrl = leerRango(searchParams)

  /**
   * El preset se deriva del rango, no se guarda: así una URL compartida marca
   * el preset correcto si coincide con alguno, y "Personalizado" si no. Las dos
   * pantallas ofrecen juegos de presets distintos, por eso lo que viaja son las
   * fechas y no el id del preset.
   */
  const periodoSel = useMemo<PeriodoOpt>(() => {
    if (!rangoUrl.desde || !rangoUrl.hasta) return periodos[0] // default: Este mes
    return (
      periodos.find(p => p.desde === rangoUrl.desde && p.hasta === rangoUrl.hasta) ??
      periodoCustom(rangoUrl.desde, rangoUrl.hasta)
    )
  }, [periodos, rangoUrl.desde, rangoUrl.hasta])

  const [incluirNoEntregados, setIncluirNoEntregados] = useState(false)
  const [comparar, setComparar] = useState(true)

  const onPeriodo = useCallback((p: PeriodoOpt): void => {
    setSearchParams(escribirRango(searchParams, p.desde, p.hasta), { replace: true })
  }, [searchParams, setSearchParams])

  // Cambia el rango personalizado (date pickers de la vista).
  const onRango = useCallback((desde: string, hasta: string): void => {
    if (!desde || !hasta || desde > hasta) return
    setSearchParams(escribirRango(searchParams, desde, hasta), { replace: true })
  }, [searchParams, setSearchParams])

  const { sucursales, hasMultipleSucursales, loading: sucLoading } = useSucursal()

  const opcionesSucursal: SucursalOpt[] = useMemo(() => {
    const list: SucursalOpt[] = sucursales.map(s => ({ id: s.id as number | null, nombre: s.nombre }))
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list
  }, [sucursales, hasMultipleSucursales])

  // La URL manda; si no trae sucursal, se resuelve el default una sola vez y se
  // escribe, para que el link que el usuario copie ya diga qué está mirando.
  // Se sigue distinguiendo `undefined` (todavía no resuelta) para no disparar
  // el RPC antes de que carguen las sucursales.
  const sucursalUrl = leerSucursal(searchParams)
  const sucursalValida = sucursalUrl != null && !sucursales.some(s => s.id === sucursalUrl)
    ? undefined // un link a una sucursal ajena cae al default, no al 'Acceso denegado' del RPC
    : sucursalUrl
  const [sucursalFallback, setSucursalFallback] = useState<number | null | undefined>(undefined)
  const sucursalSel = sucursalValida !== undefined ? sucursalValida : sucursalFallback

  useEffect(() => {
    if (sucursalValida === undefined && sucursalFallback === undefined && sucursales.length > 0) {
      setSucursalFallback(hasMultipleSucursales ? null : sucursales[0].id)
    }
  }, [sucursales, hasMultipleSucursales, sucursalValida, sucursalFallback])

  const setSucursalSel = useCallback((id: number | null): void => {
    setSucursalFallback(id)
    setSearchParams(escribirSucursal(searchParams, id), { replace: true })
  }, [searchParams, setSearchParams])

  const ready = sucursalSel !== undefined
  const sucParam = sucursalSel ?? null

  const { data: reporte, isLoading, error } = useReporteGerencialQuery(sucParam, periodoSel.desde, periodoSel.hasta, incluirNoEntregados, comparar, ready)
  const { data: analisis } = useAnalisisMensualQuery(sucParam, periodoSel.periodoMes, ready && periodoSel.esMes)
  const { data: metas } = useMetasGerencialQuery(sucParam, periodoSel.periodoMes, ready && periodoSel.esMes)
  const guardarMeta = useGuardarMetaMutation()

  // Comision segun las reglas vigentes (mig 150), para no mostrar dos numeros
  // distintos de comision entre /comisiones y este reporte. Se pide con el mismo
  // alcance de sucursal que el reporte: null = red consolidada (las asignadas).
  const scopeComision = sucParam != null ? [sucParam] : null
  const { data: comisionCalc } = useCalcularComisionesQuery(
    periodoSel.desde, periodoSel.hasta, ready, scopeComision)
  const rangoPrev = reporte?.comparativo
  const { data: comisionCalcPrev } = useCalcularComisionesQuery(
    rangoPrev?.desde ?? '', rangoPrev?.hasta ?? '', Boolean(comparar && rangoPrev), scopeComision)

  const onGuardarMeta = (venta: number | null, margenNeto: number | null): void => {
    if (!periodoSel.periodoMes) return
    if (venta != null) guardarMeta.mutate({ sucursalId: sucParam, periodo: periodoSel.periodoMes, metrica: 'venta', valor: venta })
    if (margenNeto != null) guardarMeta.mutate({ sucursalId: sucParam, periodo: periodoSel.periodoMes, metrica: 'margen_neto', valor: margenNeto })
  }

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
        onPeriodo={onPeriodo}
        onRango={onRango}
        incluirNoEntregados={incluirNoEntregados}
        onIncluirNoEntregados={setIncluirNoEntregados}
        comparar={comparar}
        onComparar={setComparar}
        metas={metas ?? null}
        metasEditable={periodoSel.esMes}
        onGuardarMeta={onGuardarMeta}
        guardandoMeta={guardarMeta.isPending}
        analisis={analisis ?? null}
        comisionCalculada={comisionCalc?.totales.comision ?? null}
        comisionCalculadaPrev={comisionCalcPrev?.totales.comision ?? null}
        comisionPorVendedor={comisionCalc?.preventistas ?? null}
      />
    </Suspense>
  )
}
