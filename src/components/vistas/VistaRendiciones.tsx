/**
 * Vista de rendiciones (resumen auto-calculado + cierre + resolucion).
 * Muestra resumen por (dia de pago, transportista) con breakdown por forma de
 * pago, total entregado ese dia (comparador secundario), gastos del dia y
 * estado (pendiente/confirmada/disconformidad/resuelta).
 */
import React, { Suspense, useState, useEffect, useCallback, useMemo } from 'react'
import {
  Banknote,
  Calendar,
  User,
  CheckCircle,
  Clock,
  Filter,
  RefreshCw,
  ChevronDown,
  ChevronUp,
  AlertTriangle,
  FileText,
  Receipt,
  Download,
  Wallet,
  Users,
  IdCard
} from 'lucide-react'
import { fechaLocalISO, formatDateTime } from '../../utils/formatters'
import { supabase } from '../../hooks/supabase/base'
import { useRendiciones } from '../../hooks/supabase'
import { useTransportistasQuery, useClientesQuery } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { FORMAS_PAGO, formaPagoLabel } from '../../constants/formasPago'
import type { ResumenRendicionDiaria, PerfilDB, EstadoRendicion, RendicionGastoInput, ClienteDB } from '../../types'
import { lazyWithReload } from '../../utils/lazyWithReload'

const ModalCerrarRendicion = lazyWithReload(() => import('../modals/ModalCerrarRendicion'))
const ModalResolverRendicion = lazyWithReload(() => import('../modals/ModalResolverRendicion'))
const ModalCtaCtePendiente = lazyWithReload(() => import('../modals/ModalCtaCtePendiente'))
const ModalFichaCliente = lazyWithReload(() => import('../modals/ModalFichaCliente'))

function formatMoney(value: number | undefined | null): string {
  return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value || 0)
}

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const ESTADO_STYLES: Record<EstadoRendicion, { label: string; badge: string; border: string }> = {
  pendiente: {
    label: 'Pendiente',
    badge: 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300',
    border: 'border-gray-300 dark:border-gray-600'
  },
  confirmada: {
    label: 'Confirmada',
    badge: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300',
    border: 'border-emerald-500'
  },
  disconformidad: {
    label: 'Disconformidad',
    badge: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300',
    border: 'border-red-500'
  },
  resuelta: {
    label: 'Resuelta',
    badge: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300',
    border: 'border-blue-500'
  }
}

/** Fila del detalle de una rendición: cliente + quién cobró (RPC obtener_detalle_rendicion, migs 135/137/140). */
interface DetalleRendicionCliente {
  cliente_id: number
  cliente_nombre: string
  /** Usuario que registró el pago. Ojo: puede no ser el transportista de la
   *  rendición — un saldo viejo cobrado en el mostrador figura bajo el
   *  transportista que repartió ese pedido. */
  cobrado_por_id: string | null
  cobrado_por: string
  total: number
  total_entregas: number
  total_ctascte: number
  efectivo: number
  transferencia: number
  cheque: number
  tarjeta: number
  vale_blanco: number
  otros: number
  cantidad_pagos: number
}

/** Un pago individual dentro de la rendición (RPC obtener_pagos_rendicion_cliente, mig 142). */
interface PagoRendicion {
  pago_id: number
  created_at: string
  monto: number
  forma_pago: string
  referencia: string | null
  notas: string | null
  pedido_id: number | null
  pedido_fecha: string | null
  pedido_estado: string | null
  cobrado_por: string
  es_entrega_del_dia: boolean
}

/** Claves de forma de pago que se pueden usar para filtrar el detalle. */
type FormaKey = 'efectivo' | 'transferencia' | 'cheque' | 'tarjeta' | 'vale_blanco' | 'otros'

const FORMA_LABELS: Record<FormaKey, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  cheque: 'Cheque',
  tarjeta: 'Tarjeta',
  vale_blanco: 'Vale Blanco',
  otros: 'Otros'
}

interface ResumenCardProps {
  resumen: ResumenRendicionDiaria
  onCerrar: (resumen: ResumenRendicionDiaria) => void
  onResolver: (resumen: ResumenRendicionDiaria) => void
  onVerFicha: (clienteId: number) => void
}

function ResumenCard({ resumen, onCerrar, onResolver, onVerFicha }: ResumenCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState(false)
  const [detalle, setDetalle] = useState<DetalleRendicionCliente[] | null>(null)
  const [loadingDetalle, setLoadingDetalle] = useState(false)
  // Un error del backend tiene que verse. Antes se hacía setDetalle([]) y el
  // fallo quedaba disfrazado de "no hay datos" (así pasó inadvertido meses que
  // la RPC fallaba por un tipo mal declarado).
  const [errorDetalle, setErrorDetalle] = useState<string>('')
  const [exportando, setExportando] = useState(false)
  // Drill-down al pago: fila abierta (cliente+cobrador) y sus pagos ya traídos.
  const [filaAbierta, setFilaAbierta] = useState<string | null>(null)
  const [pagosPorFila, setPagosPorFila] = useState<Record<string, PagoRendicion[]>>({})
  const [cargandoPagos, setCargandoPagos] = useState<string | null>(null)
  // Drill-down: al clickear una forma de pago del breakdown se filtra el detalle
  // por cliente para ver quien compone ese total.
  const [formaFiltro, setFormaFiltro] = useState<FormaKey | null>(null)
  const estadoStyle = ESTADO_STYLES[resumen.estado]

  const desgloses = useMemo(() => {
    const mapa: Record<string, number> = {
      efectivo: resumen.total_efectivo,
      transferencia: resumen.total_transferencia,
      cheque: resumen.total_cheque,
      cuenta_corriente: resumen.total_cuenta_corriente,
      tarjeta: resumen.total_tarjeta,
      vale_blanco: resumen.total_vale_blanco,
      otros: resumen.total_otros
    }
    return FORMAS_PAGO
      .map(fp => ({ meta: fp, value: mapa[fp.value] || 0 }))
      .filter(d => d.value > 0)
  }, [resumen])

  const diferencia = resumen.total_general - resumen.total_entregado
  const diferenciaStr = diferencia === 0
    ? 'Cobrado igual a entregado'
    : diferencia > 0
      ? `+${formatMoney(diferencia)} cobrado sobre entregado`
      : `${formatMoney(diferencia)} cobrado menos que entregado`

  // Detalle por cliente: se carga cada vez que se expande la tarjeta.
  // OJO: las deps NO pueden incluir `detalle`/`loadingDetalle`. Al setear el
  // loading se re-dispararia el effect, su cleanup cancelaria el fetch en vuelo
  // y el "Cargando detalle..." quedaba colgado para siempre.
  useEffect(() => {
    if (!expandido) return
    let cancelado = false
    setLoadingDetalle(true)
    void (async () => {
      const { data, error } = await supabase.rpc('obtener_detalle_rendicion', {
        p_fecha: resumen.fecha,
        p_transportista_id: resumen.transportista_id
      })
      if (cancelado) return
      if (error) {
        setErrorDetalle(error.message || 'No se pudo cargar el detalle')
        setDetalle([])
      } else {
        setErrorDetalle('')
        setDetalle((data || []).map((r: Record<string, unknown>) => ({
          cliente_id: Number(r.cliente_id),
          cliente_nombre: String(r.cliente_nombre ?? 'Cliente'),
          cobrado_por_id: (r.cobrado_por_id as string | null) ?? null,
          cobrado_por: String(r.cobrado_por ?? 'Sin usuario'),
          total: Number(r.total) || 0,
          total_entregas: Number(r.total_entregas) || 0,
          total_ctascte: Number(r.total_ctascte) || 0,
          efectivo: Number(r.efectivo) || 0,
          transferencia: Number(r.transferencia) || 0,
          cheque: Number(r.cheque) || 0,
          tarjeta: Number(r.tarjeta) || 0,
          vale_blanco: Number(r.vale_blanco) || 0,
          otros: Number(r.otros) || 0,
          cantidad_pagos: Number(r.cantidad_pagos) || 0
        })))
      }
      setLoadingDetalle(false)
    })()
    return () => { cancelado = true }
  }, [expandido, resumen.fecha, resumen.transportista_id])

  const clientesCtasCtes = useMemo(
    () => (detalle ?? []).filter(d => d.total_ctascte > 0),
    [detalle]
  )

  // Cuánto cobró cada persona dentro de esta rendición. Sirve para el control
  // de caja: la rendición agrupa por transportista, pero la plata la puede
  // haber cobrado otro (p. ej. un saldo viejo cobrado en el mostrador).
  const porCobrador = useMemo(() => {
    const m = new Map<string, number>()
    for (const d of detalle ?? []) m.set(d.cobrado_por, (m.get(d.cobrado_por) ?? 0) + d.total)
    return [...m.entries()].sort((a, b) => b[1] - a[1])
  }, [detalle])

  // Filas visibles: con filtro activo, solo los clientes que aportaron a esa forma.
  const detalleVisible = useMemo(() => {
    if (!detalle) return []
    if (!formaFiltro) return detalle
    return detalle.filter(d => (d[formaFiltro] || 0) > 0)
  }, [detalle, formaFiltro])

  const filaKey = (d: DetalleRendicionCliente) => `${d.cliente_id}-${d.cobrado_por_id ?? 'x'}`

  /** Abre/cierra una fila del detalle y trae sus pagos la primera vez. */
  const toggleFila = useCallback(async (d: DetalleRendicionCliente) => {
    const key = filaKey(d)
    if (filaAbierta === key) { setFilaAbierta(null); return }
    setFilaAbierta(key)
    if (pagosPorFila[key]) return

    setCargandoPagos(key)
    const { data, error } = await supabase.rpc('obtener_pagos_rendicion_cliente', {
      p_fecha: resumen.fecha,
      p_transportista_id: resumen.transportista_id,
      p_cliente_id: d.cliente_id
    })
    if (error) {
      setErrorDetalle(error.message || 'No se pudieron cargar los pagos')
      setPagosPorFila(prev => ({ ...prev, [key]: [] }))
    } else {
      setPagosPorFila(prev => ({
        ...prev,
        [key]: (data || []).map((r: Record<string, unknown>) => ({
          pago_id: Number(r.pago_id),
          created_at: String(r.created_at ?? ''),
          monto: Number(r.monto) || 0,
          forma_pago: String(r.forma_pago ?? ''),
          referencia: (r.referencia as string | null) ?? null,
          notas: (r.notas as string | null) ?? null,
          pedido_id: r.pedido_id != null ? Number(r.pedido_id) : null,
          pedido_fecha: (r.pedido_fecha as string | null) ?? null,
          pedido_estado: (r.pedido_estado as string | null) ?? null,
          cobrado_por: String(r.cobrado_por ?? 'Sin usuario'),
          es_entrega_del_dia: Boolean(r.es_entrega_del_dia)
        }))
      }))
    }
    setCargandoPagos(null)
  }, [filaAbierta, pagosPorFila, resumen.fecha, resumen.transportista_id])

  const handleExportarExcel = useCallback(async () => {
    if (!detalle || detalle.length === 0) return
    setExportando(true)
    try {
      const filas = detalle.map(d => ({
        Cliente: d.cliente_nombre,
        Cobró: d.cobrado_por,
        Total: d.total,
        'Entregas (dia)': d.total_entregas,
        'Ctas Ctes': d.total_ctascte,
        Efectivo: d.efectivo,
        Transferencia: d.transferencia,
        Cheque: d.cheque,
        Tarjeta: d.tarjeta,
        'Vale Blanco': d.vale_blanco,
        Otros: d.otros,
        'Nro pagos': d.cantidad_pagos
      }))
      const { createMultiSheetExcel } = await import('../../utils/excel')
      await createMultiSheetExcel(
        [{ name: 'Detalle', data: filas, columnWidths: [28, 16, 14, 14, 14, 12, 14, 12, 12, 12, 10, 8] }],
        `rendicion-${resumen.transportista_nombre}-${resumen.fecha}`.replace(/\s+/g, '_')
      )
    } finally {
      setExportando(false)
    }
  }, [detalle, resumen.transportista_nombre, resumen.fecha])

  return (
    <div className={`bg-white dark:bg-gray-800 rounded-xl shadow-sm border-l-4 ${estadoStyle.border} overflow-hidden`}>
      <div className="p-4">
        <div className="flex items-start justify-between flex-wrap gap-3">
          <div className="flex-1 min-w-[200px]">
            <div className="flex items-center gap-2 mb-1 flex-wrap">
              <User className="w-4 h-4 text-gray-500" />
              <span className="font-semibold text-gray-800 dark:text-white">
                {resumen.transportista_nombre}
              </span>
              <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${estadoStyle.badge}`}>
                {estadoStyle.label}
              </span>
            </div>
            <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400 flex-wrap">
              <Calendar className="w-4 h-4" />
              <span>{formatFechaCorta(resumen.fecha)}</span>
              <span className="px-2 py-0.5 rounded-full text-xs bg-gray-100 dark:bg-gray-700">
                {resumen.cantidad_pedidos} {resumen.cantidad_pedidos === 1 ? 'pedido entregado' : 'pedidos entregados'}
              </span>
            </div>
          </div>

          <div className="text-right">
            <p className="text-xs text-gray-500 dark:text-gray-400">Cobrado ese día</p>
            <p className="text-2xl font-bold text-gray-800 dark:text-white">
              {formatMoney(resumen.total_general)}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
              Entregado: <span className="font-medium">{formatMoney(resumen.total_entregado)}</span>
            </p>
          </div>
        </div>

        {/* Division Entregas vs Ctas Ctes */}
        <div className="grid grid-cols-2 gap-3 mt-4">
          <div className="bg-emerald-50 dark:bg-emerald-900/15 border border-emerald-200 dark:border-emerald-800 rounded-lg p-2.5">
            <p className="text-xs text-emerald-700 dark:text-emerald-300">Entregas (cobro del día)</p>
            <p className="font-bold text-emerald-700 dark:text-emerald-400">{formatMoney(resumen.total_entregas)}</p>
          </div>
          <div className="bg-blue-50 dark:bg-blue-900/15 border border-blue-200 dark:border-blue-800 rounded-lg p-2.5">
            <p className="text-xs text-blue-700 dark:text-blue-300">Ctas Ctes (cobro de saldos)</p>
            <p className="font-bold text-blue-700 dark:text-blue-400">{formatMoney(resumen.total_ctascte)}</p>
          </div>
        </div>

        {/* Breakdown por forma de pago (solo las que tienen monto) */}
        {desgloses.length > 0 && (
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-4">
            {desgloses.map(({ meta, value }) => (
              <div key={meta.value} className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-2">
                <p className="text-xs text-gray-500 dark:text-gray-400">{meta.label}</p>
                <p className={`font-bold text-${meta.color}-700 dark:text-${meta.color}-400`}>{formatMoney(value)}</p>
              </div>
            ))}
          </div>
        )}

        {/* Indicadores de gastos y observaciones */}
        {(resumen.cantidad_gastos > 0 || resumen.observaciones) && (
          <div className="mt-3 flex items-center gap-3 text-xs flex-wrap">
            {resumen.cantidad_gastos > 0 && (
              <span className="inline-flex items-center gap-1 px-2 py-1 rounded bg-amber-50 dark:bg-amber-900/20 text-amber-700 dark:text-amber-300">
                <Receipt className="w-3 h-3" />
                {resumen.cantidad_gastos} gasto{resumen.cantidad_gastos !== 1 ? 's' : ''} · {formatMoney(resumen.total_gastos)}
              </span>
            )}
            {resumen.observaciones && (
              <span className="inline-flex items-center gap-1 px-2 py-1 rounded bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300">
                <FileText className="w-3 h-3" />
                Con observaciones
              </span>
            )}
          </div>
        )}

        {/* Footer con estado + acciones */}
        <div className="flex items-center justify-between mt-4 pt-3 border-t border-gray-200 dark:border-gray-700 flex-wrap gap-2">
          <div className="flex items-center gap-2 text-sm">
            {resumen.estado === 'confirmada' && (
              <>
                <CheckCircle className="w-5 h-5 text-emerald-500" />
                <div>
                  <p className="font-medium text-emerald-700 dark:text-emerald-400">Confirmada</p>
                  {resumen.controlada_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      {new Date(resumen.controlada_at).toLocaleString('es-AR')}
                      {resumen.controlada_por_nombre && ` por ${resumen.controlada_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            )}
            {resumen.estado === 'disconformidad' && (
              <>
                <AlertTriangle className="w-5 h-5 text-red-500" />
                <div>
                  <p className="font-medium text-red-700 dark:text-red-400">Disconformidad</p>
                  {resumen.controlada_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      Reportada {new Date(resumen.controlada_at).toLocaleString('es-AR')}
                      {resumen.controlada_por_nombre && ` por ${resumen.controlada_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            )}
            {resumen.estado === 'resuelta' && (
              <>
                <CheckCircle className="w-5 h-5 text-blue-500" />
                <div>
                  <p className="font-medium text-blue-700 dark:text-blue-400">Resuelta</p>
                  {resumen.resuelta_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      {new Date(resumen.resuelta_at).toLocaleString('es-AR')}
                      {resumen.resuelta_por_nombre && ` por ${resumen.resuelta_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            )}
            {resumen.estado === 'pendiente' && (
              <>
                <Clock className="w-5 h-5 text-gray-400" />
                <p className="text-gray-600 dark:text-gray-400">Pendiente de control</p>
              </>
            )}
          </div>

          <div className="flex items-center gap-2 flex-wrap">
            <button
              onClick={() => setExpandido(!expandido)}
              className="text-sm text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 flex items-center gap-1"
            >
              {expandido ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
              Detalle
            </button>

            {resumen.estado === 'disconformidad' ? (
              <button
                onClick={() => onResolver(resumen)}
                className="px-4 py-2 rounded-lg text-sm font-medium bg-blue-600 hover:bg-blue-700 text-white"
              >
                Resolver
              </button>
            ) : (
              <button
                onClick={() => onCerrar(resumen)}
                className="px-4 py-2 rounded-lg text-sm font-medium bg-blue-600 hover:bg-blue-700 text-white"
              >
                {resumen.estado === 'pendiente' ? 'Cerrar rendición' : 'Editar cierre'}
              </button>
            )}
          </div>
        </div>

        {expandido && (
          <div className="mt-4 pt-3 border-t border-gray-200 dark:border-gray-700 text-sm space-y-3">
            <div>
              <p className="text-xs text-gray-500 mb-2">
                Breakdown completo por forma de pago
                <span className="text-gray-400"> · clickeá una para ver qué clientes la componen</span>
              </p>
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                {([
                  ['efectivo', 'Efectivo', resumen.total_efectivo],
                  ['transferencia', 'Transferencia', resumen.total_transferencia],
                  ['cheque', 'Cheque', resumen.total_cheque],
                  ['tarjeta', 'Tarjeta', resumen.total_tarjeta],
                  ['vale_blanco', 'Vale Blanco', resumen.total_vale_blanco],
                  ['otros', 'Otros', resumen.total_otros]
                ] as [FormaKey, string, number][]).map(([key, label, valor]) => (
                  <button
                    key={key}
                    onClick={() => setFormaFiltro(formaFiltro === key ? null : key)}
                    disabled={valor === 0}
                    className={`text-left px-1.5 py-1 rounded transition-colors disabled:cursor-default ${
                      formaFiltro === key
                        ? 'bg-blue-100 dark:bg-blue-900/30 ring-1 ring-blue-400'
                        : valor > 0 ? 'hover:bg-gray-100 dark:hover:bg-gray-700' : ''
                    }`}
                  >
                    <span className="text-gray-500">{label}:</span>{' '}
                    <span className="font-medium">{formatMoney(valor)}</span>
                  </button>
                ))}
                {/* Cuenta corriente como forma de pago está deprecada (ya no se registran pagos así):
                    solo se muestra para datos históricos con monto, evitando un $0 permanente que confunde.
                    La cuenta corriente real (cobro de saldos) se ve arriba en la tarjeta "Ctas Ctes". */}
                {resumen.total_cuenta_corriente > 0 && (
                  <div className="px-1.5 py-1"><span className="text-gray-500">Cuenta Cte.:</span> <span className="font-medium">{formatMoney(resumen.total_cuenta_corriente)}</span></div>
                )}
              </div>
            </div>

            {/* Detalle por cliente (Ítem 4) + export a Excel */}
            <div>
              <div className="flex items-center justify-between mb-2 flex-wrap gap-2">
                <p className="text-xs text-gray-500 flex items-center gap-1 flex-wrap">
                  <Users className="w-3 h-3" />
                  Detalle por cliente
                  {detalle && !formaFiltro && (
                    <span className="text-gray-400">
                      · {detalle.length} cliente{detalle.length !== 1 ? 's' : ''}
                      {clientesCtasCtes.length > 0 && ` · ${clientesCtasCtes.length} con ctas ctes (${formatMoney(resumen.total_ctascte)})`}
                    </span>
                  )}
                  {formaFiltro && (
                    <button
                      onClick={() => setFormaFiltro(null)}
                      className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300"
                    >
                      {FORMA_LABELS[formaFiltro]}: {detalleVisible.length} cliente{detalleVisible.length !== 1 ? 's' : ''} ✕
                    </button>
                  )}
                </p>
                <button
                  onClick={() => { void handleExportarExcel() }}
                  disabled={exportando || !detalle || detalle.length === 0}
                  className="text-xs inline-flex items-center gap-1 px-2 py-1 rounded border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50"
                >
                  <Download className="w-3 h-3" />
                  {exportando ? 'Exportando…' : 'Exportar Excel'}
                </button>
              </div>

              {/* Quién cobró: la rendición agrupa por transportista, pero la
                  plata la puede haber cobrado otro (típico: un saldo viejo
                  cobrado en el mostrador desde la ficha del cliente). */}
              {!loadingDetalle && porCobrador.length > 0 && (
                <div className="flex flex-wrap gap-2 mb-2">
                  {porCobrador.map(([nombre, monto]) => (
                    <span
                      key={nombre}
                      className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300"
                    >
                      Cobró {nombre}: <strong>{formatMoney(monto)}</strong>
                    </span>
                  ))}
                </div>
              )}

              {errorDetalle && (
                <p className="text-xs text-red-600 dark:text-red-400 py-2 flex items-start gap-1.5">
                  <AlertTriangle className="w-3.5 h-3.5 mt-0.5 shrink-0" />
                  <span>No se pudo cargar el detalle: {errorDetalle}</span>
                </p>
              )}

              {loadingDetalle ? (
                <p className="text-xs text-gray-400 py-2">Cargando detalle…</p>
              ) : detalleVisible.length > 0 ? (
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="text-gray-500 dark:text-gray-400 text-left border-b border-gray-200 dark:border-gray-700">
                        <th className="py-1 pr-2 font-medium">Cliente</th>
                        <th className="py-1 px-2 font-medium">Cobró</th>
                        {formaFiltro && <th className="py-1 px-2 font-medium text-right">{FORMA_LABELS[formaFiltro]}</th>}
                        <th className="py-1 px-2 font-medium text-right">Total</th>
                        <th className="py-1 px-2 font-medium text-right">Entregas</th>
                        <th className="py-1 pl-2 font-medium text-right">Ctas Ctes</th>
                      </tr>
                    </thead>
                    <tbody>
                      {detalleVisible.map(d => {
                        const key = filaKey(d)
                        const abierta = filaAbierta === key
                        const pagos = pagosPorFila[key]
                        const colSpan = formaFiltro ? 6 : 5
                        return (
                          <React.Fragment key={key}>
                            <tr
                              onClick={() => { void toggleFila(d) }}
                              className={`border-b border-gray-100 dark:border-gray-700/50 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/40 ${abierta ? 'bg-gray-50 dark:bg-gray-700/40' : ''}`}
                            >
                              <td className="py-1 pr-2 text-gray-700 dark:text-gray-300">
                                <span className="inline-flex items-center gap-1">
                                  {abierta ? <ChevronUp className="w-3 h-3 text-gray-400" /> : <ChevronDown className="w-3 h-3 text-gray-400" />}
                                  {d.cliente_nombre}
                                </span>
                              </td>
                              <td className="py-1 px-2 text-gray-500">{d.cobrado_por}</td>
                              {formaFiltro && (
                                <td className="py-1 px-2 text-right font-semibold text-blue-700 dark:text-blue-300">{formatMoney(d[formaFiltro])}</td>
                              )}
                              <td className="py-1 px-2 text-right font-medium text-gray-800 dark:text-gray-200">{formatMoney(d.total)}</td>
                              <td className="py-1 px-2 text-right text-emerald-600 dark:text-emerald-400">{d.total_entregas > 0 ? formatMoney(d.total_entregas) : '—'}</td>
                              <td className="py-1 pl-2 text-right text-blue-600 dark:text-blue-400">{d.total_ctascte > 0 ? formatMoney(d.total_ctascte) : '—'}</td>
                            </tr>

                            {abierta && (
                              <tr className="border-b border-gray-100 dark:border-gray-700/50">
                                <td colSpan={colSpan} className="py-2 px-2 bg-gray-50/60 dark:bg-gray-900/30">
                                  {cargandoPagos === key ? (
                                    <p className="text-xs text-gray-400">Cargando pagos…</p>
                                  ) : pagos && pagos.length > 0 ? (
                                    <div className="space-y-1.5">
                                      {pagos.map(p => (
                                        <div key={p.pago_id} className="flex items-start justify-between gap-2 flex-wrap">
                                          <div className="min-w-0">
                                            <span className="font-medium text-gray-800 dark:text-gray-200">{formatMoney(p.monto)}</span>
                                            <span className="text-gray-500"> · {formaPagoLabel(p.forma_pago)}</span>
                                            <span className="text-gray-400"> · {formatDateTime(p.created_at)}</span>
                                            {p.pedido_id && (
                                              <span className="text-gray-500"> · Pedido #{p.pedido_id}
                                                {p.pedido_fecha ? ` (${formatFechaCorta(p.pedido_fecha)})` : ''}
                                              </span>
                                            )}
                                            {!p.pedido_id && <span className="text-gray-500"> · Pago a cuenta</span>}
                                            {p.referencia && <span className="text-gray-400"> · Ref: {p.referencia}</span>}
                                            <span className="text-gray-400"> · cobró {p.cobrado_por}</span>
                                            {p.notas && <p className="text-gray-400 italic">{p.notas}</p>}
                                          </div>
                                          <span className={`px-1.5 py-0.5 rounded shrink-0 ${
                                            p.es_entrega_del_dia
                                              ? 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300'
                                              : 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300'
                                          }`}>
                                            {p.es_entrega_del_dia ? 'Entrega del día' : 'Ctas Ctes'}
                                          </span>
                                        </div>
                                      ))}
                                      <button
                                        onClick={(e) => { e.stopPropagation(); onVerFicha(d.cliente_id) }}
                                        className="mt-1 inline-flex items-center gap-1 px-2 py-1 rounded border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700"
                                      >
                                        <IdCard className="w-3 h-3" /> Ver ficha del cliente
                                      </button>
                                    </div>
                                  ) : (
                                    <p className="text-xs text-gray-400">Sin pagos para mostrar.</p>
                                  )}
                                </td>
                              </tr>
                            )}
                          </React.Fragment>
                        )
                      })}
                    </tbody>
                    {formaFiltro && (
                      <tfoot>
                        <tr className="border-t border-gray-300 dark:border-gray-600">
                          <td className="py-1 pr-2 font-medium text-gray-600 dark:text-gray-300" colSpan={2}>Total {FORMA_LABELS[formaFiltro]}</td>
                          <td className="py-1 px-2 text-right font-bold text-blue-700 dark:text-blue-300">
                            {formatMoney(detalleVisible.reduce((acc, d) => acc + (d[formaFiltro] || 0), 0))}
                          </td>
                          <td colSpan={3} />
                        </tr>
                      </tfoot>
                    )}
                  </table>
                </div>
              ) : (
                <p className="text-xs text-gray-400 py-2">
                  {formaFiltro ? 'Ningún cliente pagó con esa forma ese día.' : 'Sin pagos ese día.'}
                </p>
              )}
            </div>

            <div className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
              <Banknote className="w-3 h-3" />
              <span>{diferenciaStr}</span>
            </div>

            {resumen.observaciones && (
              <div>
                <p className="text-xs text-gray-500 mb-1">Observaciones</p>
                <p className="text-sm text-gray-700 dark:text-gray-300 whitespace-pre-wrap bg-gray-50 dark:bg-gray-700/50 p-2 rounded">
                  {resumen.observaciones}
                </p>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export default function VistaRendiciones(): React.ReactElement {
  const notify = useNotification()
  const {
    resumenes,
    loading,
    fetchResumen,
    confirmarRendicion,
    resolverRendicion
  } = useRendiciones()
  const { data: transportistas = [] } = useTransportistasQuery()

  const hoy = fechaLocalISO()
  const haceUnaSemana = useMemo(() => {
    const d = new Date()
    d.setDate(d.getDate() - 7)
    return fechaLocalISO(d)
  }, [])

  const [fechaDesde, setFechaDesde] = useState<string>(haceUnaSemana)
  const [fechaHasta, setFechaHasta] = useState<string>(hoy)
  const [transportistaFiltro, setTransportistaFiltro] = useState<string>('')
  const [estadoFiltro, setEstadoFiltro] = useState<'todas' | 'pendientes' | 'confirmadas' | 'disconformidad' | 'resueltas'>('todas')

  const [cerrarResumen, setCerrarResumen] = useState<ResumenRendicionDiaria | null>(null)
  const [resolverResumen, setResolverResumen] = useState<ResumenRendicionDiaria | null>(null)
  const [guardando, setGuardando] = useState(false)
  const [verCtaCte, setVerCtaCte] = useState(false)
  // Ficha del cliente abierta desde el detalle de una rendición. Se resuelve
  // contra la lista de clientes: ModalFichaCliente es autónomo (solo necesita
  // el cliente y onClose), igual que en ReportesContainer.
  const [clienteFichaId, setClienteFichaId] = useState<number | null>(null)
  const { data: clientes = [] } = useClientesQuery()
  const clienteFicha = useMemo(
    () => (clienteFichaId == null ? null : clientes.find(c => Number(c.id) === clienteFichaId) ?? null),
    [clientes, clienteFichaId]
  )

  const cargar = useCallback(async (): Promise<void> => {
    await fetchResumen(fechaDesde, fechaHasta, transportistaFiltro || null)
  }, [fechaDesde, fechaHasta, transportistaFiltro, fetchResumen])

  useEffect(() => {
    cargar()
  }, [cargar])

  const handleCerrar = useCallback(async (
    estado: 'confirmada' | 'disconformidad',
    observaciones: string | null,
    gastos: RendicionGastoInput[]
  ): Promise<void> => {
    if (!cerrarResumen) return
    setGuardando(true)
    try {
      await confirmarRendicion(
        cerrarResumen.fecha,
        cerrarResumen.transportista_id,
        estado,
        observaciones,
        gastos
      )
      notify.success(estado === 'confirmada' ? 'Rendición confirmada' : 'Disconformidad registrada')
      setCerrarResumen(null)
    } catch {
      // Error ya notificado en el hook
    } finally {
      setGuardando(false)
    }
  }, [cerrarResumen, confirmarRendicion, notify])

  const handleResolver = useCallback(async (observaciones: string): Promise<void> => {
    if (!resolverResumen) return
    setGuardando(true)
    try {
      await resolverRendicion(
        resolverResumen.fecha,
        resolverResumen.transportista_id,
        observaciones
      )
      notify.success('Disconformidad resuelta')
      setResolverResumen(null)
    } catch {
      // Error ya notificado
    } finally {
      setGuardando(false)
    }
  }, [resolverResumen, resolverRendicion, notify])

  const resumenesFiltrados = useMemo(() => {
    if (estadoFiltro === 'todas') return resumenes
    if (estadoFiltro === 'pendientes') return resumenes.filter(r => r.estado === 'pendiente')
    if (estadoFiltro === 'confirmadas') return resumenes.filter(r => r.estado === 'confirmada')
    if (estadoFiltro === 'disconformidad') return resumenes.filter(r => r.estado === 'disconformidad')
    if (estadoFiltro === 'resueltas') return resumenes.filter(r => r.estado === 'resuelta')
    return resumenes
  }, [resumenes, estadoFiltro])

  const stats = useMemo(() => ({
    total: resumenes.length,
    confirmadas: resumenes.filter(r => r.estado === 'confirmada').length,
    pendientes: resumenes.filter(r => r.estado === 'pendiente').length,
    disconformidad: resumenes.filter(r => r.estado === 'disconformidad').length,
    totalCobrado: resumenes.reduce((sum, r) => sum + r.total_general, 0),
    totalEntregado: resumenes.reduce((sum, r) => sum + r.total_entregado, 0)
  }), [resumenes])

  return (
    <div className="space-y-4 p-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white flex items-center gap-2">
            <Banknote className="w-6 h-6" />
            Rendiciones Diarias
          </h1>
          <p className="text-gray-500 mt-1 text-sm">
            Resumen auto-calculado por transportista y día (basado en fecha de pago)
          </p>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          {/* Deuda del mismo rango que la rendición, para poder cuadrar
              entregado vs cobrado vs pendiente en un solo lugar. */}
          <button
            onClick={() => setVerCtaCte(true)}
            className="flex items-center gap-2 px-4 py-2 border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            <Wallet className="w-4 h-4" />
            Cta cte pendiente
          </button>
          <button
            onClick={cargar}
            disabled={loading}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors disabled:opacity-50"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
            Refrescar
          </button>
        </div>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-6 gap-3">
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Total</p>
          <p className="text-2xl font-bold">{stats.total}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Confirmadas</p>
          <p className="text-2xl font-bold text-emerald-600">{stats.confirmadas}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Pendientes</p>
          <p className="text-2xl font-bold text-amber-600">{stats.pendientes}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Disconformidad</p>
          <p className="text-2xl font-bold text-red-600">{stats.disconformidad}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Cobrado total</p>
          <p className="text-lg font-bold">{formatMoney(stats.totalCobrado)}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Entregado total</p>
          <p className="text-lg font-bold">{formatMoney(stats.totalEntregado)}</p>
        </div>
      </div>

      {/* Filtros */}
      <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
        <div className="flex items-center gap-2 mb-3">
          <Filter className="w-4 h-4 text-gray-500" />
          <h3 className="text-sm font-medium text-gray-700 dark:text-gray-300">Filtros</h3>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-3">
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Desde</label>
            <input
              type="date"
              value={fechaDesde}
              onChange={(e) => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Hasta</label>
            <input
              type="date"
              value={fechaHasta}
              onChange={(e) => setFechaHasta(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Transportista</label>
            <select
              value={transportistaFiltro}
              onChange={(e) => setTransportistaFiltro(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            >
              <option value="">Todos</option>
              {transportistas.map((t: PerfilDB) => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Estado</label>
            <select
              value={estadoFiltro}
              onChange={(e) => setEstadoFiltro(e.target.value as typeof estadoFiltro)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            >
              <option value="todas">Todas</option>
              <option value="pendientes">Pendientes</option>
              <option value="confirmadas">Confirmadas</option>
              <option value="disconformidad">Disconformidad</option>
              <option value="resueltas">Resueltas</option>
            </select>
          </div>
        </div>
      </div>

      {/* Lista */}
      {loading ? (
        <div className="text-center py-12">
          <RefreshCw className="w-8 h-8 animate-spin mx-auto text-gray-400" />
          <p className="mt-4 text-gray-500">Cargando rendiciones...</p>
        </div>
      ) : resumenesFiltrados.length === 0 ? (
        <div className="text-center py-12 bg-white dark:bg-gray-800 rounded-lg shadow-sm">
          <Banknote className="w-12 h-12 text-gray-300 mx-auto" />
          <p className="mt-4 text-gray-500">No hay rendiciones en el rango seleccionado</p>
        </div>
      ) : (
        <div className="space-y-3">
          {resumenesFiltrados.map(r => (
            <ResumenCard
              key={`${r.fecha}-${r.transportista_id}`}
              resumen={r}
              onCerrar={setCerrarResumen}
              onResolver={setResolverResumen}
              onVerFicha={setClienteFichaId}
            />
          ))}
        </div>
      )}

      {/* Modales */}
      {cerrarResumen && (
        <Suspense fallback={null}>
          <ModalCerrarRendicion
            fecha={cerrarResumen.fecha}
            transportistaNombre={cerrarResumen.transportista_nombre}
            totalCobrado={cerrarResumen.total_general}
            totalEntregado={cerrarResumen.total_entregado}
            totalEntregas={cerrarResumen.total_entregas}
            totalCtasCte={cerrarResumen.total_ctascte}
            observacionesPrevias={cerrarResumen.observaciones}
            onConfirmar={handleCerrar}
            onClose={() => setCerrarResumen(null)}
            guardando={guardando}
          />
        </Suspense>
      )}

      {resolverResumen && (
        <Suspense fallback={null}>
          <ModalResolverRendicion
            fecha={resolverResumen.fecha}
            transportistaNombre={resolverResumen.transportista_nombre}
            observacionesPrevias={resolverResumen.observaciones}
            onResolver={handleResolver}
            onClose={() => setResolverResumen(null)}
            guardando={guardando}
          />
        </Suspense>
      )}

      {verCtaCte && (
        <Suspense fallback={null}>
          <ModalCtaCtePendiente
            fechaDesde={fechaDesde}
            fechaHasta={fechaHasta}
            transportistaId={transportistaFiltro}
            onClose={() => setVerCtaCte(false)}
          />
        </Suspense>
      )}

      {clienteFicha && (
        <Suspense fallback={null}>
          <ModalFichaCliente
            cliente={clienteFicha as ClienteDB}
            onClose={() => setClienteFichaId(null)}
          />
        </Suspense>
      )}
    </div>
  )
}
