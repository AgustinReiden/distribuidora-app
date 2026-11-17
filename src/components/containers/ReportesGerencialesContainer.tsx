import React, { Suspense, useCallback, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import { useReporteGerencialQuery, useReporteCombosQuery, useReporteCombosRotacionQuery, useAnalisisMensualQuery, useMetasGerencialQuery, useGuardarMetaMutation, useCalcularComisionesQuery, useSucursalesActivasQuery } from '../../hooks/queries'
import { useSucursal } from '../../contexts/SucursalContext'
import { useAlertasCombos } from '../../hooks/useAlertasCombos'
import { useDiaArgentino } from '../../hooks/useDiaArgentino'
import type { PeriodoOpt, SucursalOpt } from '../vistas/VistaReportesGerenciales'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { escribirPreset, escribirRango, escribirSucursal, leerPreset, leerRango, leerSucursal } from '../../utils/paramsReporte'
import { ymdLocalDate as ymd, primerDiaMesAtras, hoyArgentinaLocal } from '../../utils/fechaLocal'

const VistaReportesGerenciales = lazyWithReload(() => import('../vistas/VistaReportesGerenciales'))

const MESES_ES = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre']

/**
 * Presets de fecha tipo BI. El primero (Este mes) es el default — NO hay un
 * trimestre hardcodeado. Además del listado, el usuario puede elegir un rango
 * personalizado (manejado vía onRango en la vista).
 */
function generarPeriodos(hoy: Date): PeriodoOpt[] {
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
  const pm = primerDiaMesAtras(hoy, 1)
  add('mes-pasado', 'Mes pasado', pm, new Date(y, m, 0), true, pm)
  const qStart = Math.floor(m / 3) * 3
  add('trimestre', 'Trimestre en curso', new Date(y, qStart, 1), hoy)
  add('anio', 'Año en curso', new Date(y, 0, 1), hoy)
  // Meses anteriores (para el análisis narrativo guardado por mes).
  for (let i = 2; i < 12; i++) {
    const d = primerDiaMesAtras(hoy, i)
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
    parcial: hasta >= ymd(hoyArgentinaLocal()),
  }
}

export default function ReportesGerencialesContainer(): React.ReactElement {
  // «Este mes» y los demás presets llegan hasta hoy: se rearman cuando cambia el día argentino, no
  // quedan fijos en el día en que se montó la pantalla (#1597, 1597-b3).
  const hoyArgentina = useDiaArgentino()
  // Hoy como `Date` local a mediodía (el mismo que `hoyArgentinaLocal`), pero atado a ese día.
  const hoy = useMemo(() => {
    const [anio, mes, dia] = hoyArgentina.split('-').map(Number)
    return new Date(anio, mes - 1, dia, 12)
  }, [hoyArgentina])
  const periodos = useMemo(() => generarPeriodos(hoy), [hoy])
  // Opción "Personalizado" al final del selector (rango default: últimos 30 días).
  const customDefault = useMemo(() => {
    const hace30 = new Date(hoy.getTime() - 29 * 24 * 60 * 60 * 1000)
    return periodoCustom(ymd(hace30), ymd(hoy))
  }, [hoy])
  const opcionesPeriodo = useMemo<PeriodoOpt[]>(() => [...periodos, customDefault], [periodos, customDefault])

  // El período y la sucursal viven en la URL para que "Ver detalle" pueda
  // llevarlos a /reportes, el link sea compartible y el reload los conserve.
  // Los toggles de abajo NO: son exclusivos de esta pantalla.
  const [searchParams, setSearchParams] = useSearchParams()
  const rangoUrl = leerRango(searchParams)
  const presetUrl = leerPreset(searchParams)

  /**
   * Con un preset elegido, manda el preset (por su key), no las fechas: «Este mes» termina hoy, y
   * con las fechas de ayer en la URL el selector caía en «Personalizado» pasada la medianoche
   * (1597-b3). Sin preset —un link de /reportes, o un rango tipeado— el preset se deriva del rango:
   * una URL compartida marca el preset que coincida, y «Personalizado» si no. Las dos pantallas
   * ofrecen juegos de presets distintos, por eso lo que viaja entre ellas son las fechas.
   */
  const periodoSel = useMemo<PeriodoOpt>(() => {
    const elegido = presetUrl ? periodos.find(p => p.key === presetUrl) : undefined
    if (elegido) return elegido
    if (!rangoUrl.desde || !rangoUrl.hasta) return periodos[0] // default: Este mes
    return (
      periodos.find(p => p.desde === rangoUrl.desde && p.hasta === rangoUrl.hasta) ??
      periodoCustom(rangoUrl.desde, rangoUrl.hasta)
    )
  }, [periodos, presetUrl, rangoUrl.desde, rangoUrl.hasta])

  const [incluirNoEntregados, setIncluirNoEntregados] = useState(false)
  const [comparar, setComparar] = useState(true)

  const onPeriodo = useCallback((p: PeriodoOpt): void => {
    // Un preset se guarda por su key y SIN fechas: el rango se recalcula con el día argentino (un
    // «Este mes» con las fechas de ayer en la URL se quedaría atrás). «Personalizado» guarda las fechas.
    if (p.key === 'custom') {
      setSearchParams(escribirPreset(escribirRango(searchParams, p.desde, p.hasta), null), { replace: true })
    } else {
      setSearchParams(escribirPreset(escribirRango(searchParams, null, null), p.key), { replace: true })
    }
  }, [searchParams, setSearchParams])

  // Cambia el rango personalizado (date pickers de la vista): deja de haber preset.
  const onRango = useCallback((desde: string, hasta: string): void => {
    if (!desde || !hasta || desde > hasta) return
    setSearchParams(escribirPreset(escribirRango(searchParams, desde, hasta), null), { replace: true })
  }, [searchParams, setSearchParams])

  const { sucursales, hasMultipleSucursales, loading: sucLoading, currentSucursalId } = useSucursal()

  const opcionesSucursal: SucursalOpt[] = useMemo(() => {
    const list: SucursalOpt[] = sucursales.map(s => ({ id: s.id as number | null, nombre: s.nombre }))
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list
  }, [sucursales, hasMultipleSucursales])

  // La URL manda (`suc=red` es la red, pedida explícitamente); si no trae sucursal
  // se usa lo que el usuario eligió acá o, en su defecto, la sucursal activa.
  // Se sigue distinguiendo `undefined` (todavía no resuelta) para no disparar
  // el RPC antes de que carguen las sucursales.
  const sucursalUrl = leerSucursal(searchParams)
  const sucursalValida = sucursalUrl != null && !sucursales.some(s => s.id === sucursalUrl)
    ? undefined // un link a una sucursal ajena cae al default, no al 'Acceso denegado' del RPC
    : sucursalUrl
  // Lo que el usuario eligió en el selector de esta pantalla (si eligió algo).
  const [sucursalElegida, setSucursalElegida] = useState<number | null | undefined>(undefined)
  // El default es la sucursal ACTIVA, como el resto de la app (#1052): la red
  // sigue en el selector y en `suc=red`, pero no es donde se arranca. Se deriva
  // (no se guarda), así que seguir a la activa si cambia mientras la pantalla
  // está abierta. Con varias sucursales se espera a que la activa esté resuelta:
  // caer a la red mientras tanto es justo lo que esto evita.
  const sucursalActiva = sucursales.find(s => s.id === currentSucursalId)
  const sucursalPorDefecto: number | undefined = sucursalActiva
    ? sucursalActiva.id
    : (!hasMultipleSucursales && sucursales.length > 0 ? sucursales[0].id : undefined)
  const sucursalSel = sucursalValida !== undefined ? sucursalValida
    : (sucursalElegida !== undefined ? sucursalElegida : sucursalPorDefecto)

  const setSucursalSel = useCallback((id: number | null): void => {
    setSucursalElegida(id)
    setSearchParams(escribirSucursal(searchParams, id), { replace: true })
  }, [searchParams, setSearchParams])

  const ready = sucursalSel !== undefined
  const sucParam = sucursalSel ?? null

  const { data: reporte, isLoading, error } = useReporteGerencialQuery(sucParam, periodoSel.desde, periodoSel.hasta, incluirNoEntregados, comparar, ready)

  // Alertas de combos (#1194): margen bajo o negativo, sin costo, descuento
  // alto y "no conviene", con la misma cuenta que el panel de combos. Son de
  // los combos vigentes HOY (no del período) y de la sucursal activa: los
  // combos se leen por RLS de esa sucursal, así que en la red o en otra
  // sucursal no se suman.
  // Análisis de combos (#1193): venta, descuento y margen real por combo, de
  // `reporte_combos` (mig 387). Es informativo: no entra en ninguna cascada.
  const { data: combosReporte } = useReporteCombosQuery(sucParam, periodoSel.desde, periodoSel.hasta, incluirNoEntregados, comparar, ready)
  const { data: combosRotacion } = useReporteCombosRotacionQuery(sucParam, periodoSel.desde, periodoSel.hasta, incluirNoEntregados, ready)
  const alertasCombos = useAlertasCombos(ready && sucParam != null && sucParam === currentSucursalId)
  const reporteConCombos = useMemo(() => {
    if (!reporte) return reporte
    if (alertasCombos.length === 0 && !combosReporte && !combosRotacion) return reporte
    return {
      ...reporte,
      alertas: [...(reporte.alertas ?? []), ...alertasCombos],
      combos: combosReporte,
      combosRotacion,
    }
  }, [reporte, alertasCombos, combosReporte, combosRotacion])
  const { data: analisis } = useAnalisisMensualQuery(sucParam, periodoSel.periodoMes, ready && periodoSel.esMes)
  const { data: metas } = useMetasGerencialQuery(sucParam, periodoSel.periodoMes, ready && periodoSel.esMes)
  const guardarMeta = useGuardarMetaMutation()
  // La meta de la Red la carga sólo quien tiene todas las sucursales activas, el
  // mismo criterio con que la lee (#1272) y con que la guarda el RPC (#1321).
  const { data: sucursalesActivas = [] } = useSucursalesActivasQuery()
  const tieneTodasLasSucursales = sucursalesActivas.length > 0
    && sucursalesActivas.every(a => sucursales.some(s => s.id === a.id))

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
        reporte={reporteConCombos}
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
        metasEditable={periodoSel.esMes && (sucParam != null || tieneTodasLasSucursales)}
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
