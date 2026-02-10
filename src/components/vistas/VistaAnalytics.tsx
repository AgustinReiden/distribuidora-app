/**
 * VistaAnalytics — Centro de Análisis
 *
 * UI para exportar datos denormalizados listos para Power BI.
 * Incluye selector de período y descripción de cada dataset.
 */
import React, { useState } from 'react'
import { Database, Download, Loader2, CheckCircle2, AlertCircle, FileSpreadsheet, Info } from 'lucide-react'

export interface VistaAnalyticsProps {
  onExportBI: (desde: string, hasta: string) => Promise<void>
  exportando: boolean
  error: string | null
  exito: boolean
}

type PresetId = 'ultimo_mes' | 'ultimos_3_meses' | 'este_ano' | 'personalizado'

function getPresetDates(preset: PresetId): { desde: string; hasta: string } {
  const now = new Date()
  const hasta = now.toISOString().split('T')[0]
  let desde: Date

  switch (preset) {
    case 'ultimo_mes':
      desde = new Date(now.getFullYear(), now.getMonth() - 1, now.getDate())
      break
    case 'ultimos_3_meses':
      desde = new Date(now.getFullYear(), now.getMonth() - 3, now.getDate())
      break
    case 'este_ano':
      desde = new Date(now.getFullYear(), 0, 1)
      break
    default:
      desde = new Date(now.getFullYear(), now.getMonth() - 1, now.getDate())
  }

  return { desde: desde.toISOString().split('T')[0], hasta }
}

const datasets = [
  {
    nombre: 'Ventas Detallado',
    descripcion: 'Cada item de pedido con cliente, producto, margenes, zona, preventista y transportista',
    icon: '📊',
  },
  {
    nombre: 'Clientes',
    descripcion: 'Clientes con segmentacion (Alto/Medio/Bajo), estado de actividad, lat/lng para mapas de calor',
    icon: '👥',
  },
  {
    nombre: 'Productos',
    descripcion: 'Productos con rotacion diaria, stock en dias, velocidad de venta y margen',
    icon: '📦',
  },
  {
    nombre: 'Compras',
    descripcion: 'Detalle de compras con proveedor y producto',
    icon: '🛒',
  },
  {
    nombre: 'Cobranzas',
    descripcion: 'Pagos registrados con cliente y forma de pago',
    icon: '💰',
  },
  {
    nombre: 'Canasta de Productos',
    descripcion: 'Pares de productos comprados juntos con confianza y lift (market basket analysis)',
    icon: '🔗',
  },
]

export default function VistaAnalytics({
  onExportBI,
  exportando,
  error,
  exito,
}: VistaAnalyticsProps): React.ReactElement {
  const defaultDates = getPresetDates('ultimo_mes')
  const [preset, setPreset] = useState<PresetId>('ultimo_mes')
  const [desde, setDesde] = useState(defaultDates.desde)
  const [hasta, setHasta] = useState(defaultDates.hasta)

  const handlePreset = (p: PresetId) => {
    setPreset(p)
    if (p !== 'personalizado') {
      const dates = getPresetDates(p)
      setDesde(dates.desde)
      setHasta(dates.hasta)
    }
  }

  const handleExport = () => {
    if (desde && hasta) {
      onExportBI(desde, hasta)
    }
  }

  const presets: { id: PresetId; label: string }[] = [
    { id: 'ultimo_mes', label: 'Ultimo mes' },
    { id: 'ultimos_3_meses', label: 'Ultimos 3 meses' },
    { id: 'este_ano', label: 'Este año' },
    { id: 'personalizado', label: 'Personalizado' },
  ]

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Database className="w-7 h-7 text-blue-600 dark:text-blue-400" />
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Centro de Analisis</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Exporta datos listos para Power BI con analisis de correlacion de productos
          </p>
        </div>
      </div>

      {/* Period selector */}
      <section className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4" aria-labelledby="periodo-heading">
        <h2 id="periodo-heading" className="font-semibold mb-3 text-gray-700 dark:text-gray-200">Periodo de datos</h2>

        <div className="flex flex-wrap gap-2 mb-4" role="group" aria-label="Presets de periodo">
          {presets.map(p => (
            <button
              key={p.id}
              onClick={() => handlePreset(p.id)}
              aria-pressed={preset === p.id}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
                preset === p.id
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label htmlFor="fecha-desde" className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400">
              Desde
            </label>
            <input
              id="fecha-desde"
              type="date"
              value={desde}
              onChange={e => { setDesde(e.target.value); setPreset('personalizado') }}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div>
            <label htmlFor="fecha-hasta" className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400">
              Hasta
            </label>
            <input
              id="fecha-hasta"
              type="date"
              value={hasta}
              onChange={e => { setHasta(e.target.value); setPreset('personalizado') }}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
        </div>
      </section>

      {/* Export card */}
      <section className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-6" aria-labelledby="export-heading">
        <div className="flex items-start gap-4 mb-4">
          <FileSpreadsheet className="w-10 h-10 text-green-600 dark:text-green-400 flex-shrink-0 mt-1" aria-hidden="true" />
          <div>
            <h2 id="export-heading" className="text-lg font-semibold text-gray-800 dark:text-white">Exportar para Power BI</h2>
            <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
              Genera un archivo Excel con 7 hojas de datos denormalizados, listos para importar en Power BI
            </p>
          </div>
        </div>

        {/* Dataset list */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-6">
          {datasets.map(ds => (
            <div
              key={ds.nombre}
              className="flex items-start gap-2 p-3 bg-gray-50 dark:bg-gray-750 dark:bg-opacity-50 rounded-lg border border-gray-100 dark:border-gray-700"
            >
              <span className="text-lg flex-shrink-0">{ds.icon}</span>
              <div>
                <p className="text-sm font-medium text-gray-800 dark:text-gray-200">{ds.nombre}</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">{ds.descripcion}</p>
              </div>
            </div>
          ))}
        </div>

        {/* Status messages */}
        <div aria-live="polite">
          {error && (
            <div role="alert" className="flex items-center gap-2 p-3 mb-4 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <AlertCircle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0" aria-hidden="true" />
              <p className="text-sm text-red-700 dark:text-red-300">{error}</p>
            </div>
          )}

          {exito && (
            <div role="status" className="flex items-center gap-2 p-3 mb-4 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg">
              <CheckCircle2 className="w-5 h-5 text-green-600 dark:text-green-400 flex-shrink-0" aria-hidden="true" />
              <p className="text-sm text-green-700 dark:text-green-300">Exportacion completada. Revisa tu carpeta de descargas.</p>
            </div>
          )}
        </div>

        {/* Export button */}
        <button
          onClick={handleExport}
          disabled={exportando || !desde || !hasta}
          className="flex items-center justify-center gap-2 w-full sm:w-auto px-6 py-3 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white font-medium rounded-lg transition-colors"
        >
          {exportando ? (
            <>
              <Loader2 className="w-5 h-5 animate-spin" />
              Generando exportacion...
            </>
          ) : (
            <>
              <Download className="w-5 h-5" />
              Generar Exportacion Completa
            </>
          )}
        </button>
      </section>

      {/* Power BI instructions */}
      <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-5">
        <div className="flex items-center gap-2 mb-3">
          <Info className="w-5 h-5 text-blue-600 dark:text-blue-400" />
          <h3 className="font-semibold text-blue-900 dark:text-blue-200">Como usar en Power BI</h3>
        </div>
        <ol className="list-decimal list-inside space-y-2 text-sm text-blue-800 dark:text-blue-300">
          <li>Descarga el archivo Excel generado</li>
          <li>Abre Power BI Desktop y selecciona <strong>Obtener datos &rarr; Excel</strong></li>
          <li>Importa todas las hojas como tablas (excepto &quot;Info_Exportacion&quot;)</li>
          <li>Crea relaciones: <code className="bg-blue-100 dark:bg-blue-800 px-1 rounded">Ventas_Detallado.cliente_id &rarr; Clientes.id</code> y <code className="bg-blue-100 dark:bg-blue-800 px-1 rounded">Ventas_Detallado.producto_id &rarr; Productos.id</code></li>
          <li>Usa <strong>Clientes.latitud / longitud</strong> para crear un mapa de calor de ventas por ubicacion</li>
          <li>Usa la hoja <strong>Canasta_Productos</strong> para descubrir que productos se venden juntos (lift &gt; 1.5 = asociacion fuerte)</li>
        </ol>
      </div>
    </div>
  )
}
