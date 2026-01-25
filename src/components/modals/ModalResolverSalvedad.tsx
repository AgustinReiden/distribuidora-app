/**
 * Modal para que admin resuelva una salvedad pendiente
 */
import React, { useState, FormEvent, ChangeEvent } from 'react'
import { X, CheckCircle, Package, User, Truck, Calendar, FileText, AlertCircle } from 'lucide-react'
import { MOTIVOS_SALVEDAD_LABELS, ESTADOS_RESOLUCION_LABELS } from '../../lib/schemas'
import type { SalvedadItemDBExtended, EstadoResolucionSalvedad } from '../../types'

type ResolucionOption = Exclude<EstadoResolucionSalvedad, 'pendiente'>;

interface ResolucionOptionInfo {
  value: ResolucionOption;
  label: string;
  descripcion: string;
  color: string;
}

const RESOLUCIONES: ResolucionOptionInfo[] = [
  {
    value: 'reprogramada',
    label: ESTADOS_RESOLUCION_LABELS.reprogramada,
    descripcion: 'Se creara un nuevo pedido para entregar la cantidad faltante',
    color: 'blue'
  },
  {
    value: 'nota_credito',
    label: ESTADOS_RESOLUCION_LABELS.nota_credito,
    descripcion: 'Se emite una nota de credito al cliente',
    color: 'purple'
  },
  {
    value: 'descuento_transportista',
    label: ESTADOS_RESOLUCION_LABELS.descuento_transportista,
    descripcion: 'El monto se descuenta de la rendicion del transportista',
    color: 'red'
  },
  {
    value: 'absorcion_empresa',
    label: ESTADOS_RESOLUCION_LABELS.absorcion_empresa,
    descripcion: 'La empresa asume la perdida',
    color: 'amber'
  },
  {
    value: 'resuelto_otro',
    label: ESTADOS_RESOLUCION_LABELS.resuelto_otro,
    descripcion: 'Otra forma de resolucion (especificar en notas)',
    color: 'gray'
  },
  {
    value: 'anulada',
    label: ESTADOS_RESOLUCION_LABELS.anulada,
    descripcion: 'Se anula la salvedad (error en el registro)',
    color: 'slate'
  }
]

export interface ModalResolverSalvedadProps {
  salvedad: SalvedadItemDBExtended;
  onResolver: (data: {
    salvedadId: string;
    estadoResolucion: ResolucionOption;
    notas: string;
    pedidoReprogramadoId?: string;
  }) => Promise<{ success: boolean }>;
  onClose: () => void;
}

export default function ModalResolverSalvedad({
  salvedad,
  onResolver,
  onClose
}: ModalResolverSalvedadProps): React.ReactElement {
  const [resolucion, setResolucion] = useState<ResolucionOption | ''>('')
  const [notas, setNotas] = useState<string>('')
  const [guardando, setGuardando] = useState<boolean>(false)
  const [error, setError] = useState<string>('')

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    setError('')

    if (!resolucion) {
      setError('Debe seleccionar una resolucion')
      return
    }

    if (notas.trim().length < 5) {
      setError('Debe agregar notas de la resolucion (minimo 5 caracteres)')
      return
    }

    setGuardando(true)
    try {
      const result = await onResolver({
        salvedadId: salvedad.id,
        estadoResolucion: resolucion,
        notas: notas.trim()
      })

      if (!result.success) {
        setError('Error al resolver la salvedad')
        return
      }

      onClose()
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error al resolver la salvedad'
      setError(errorMessage)
    } finally {
      setGuardando(false)
    }
  }

  const formatMoney = (value: number): string => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value)
  }

  const formatDate = (dateStr: string | undefined): string => {
    if (!dateStr) return '-'
    return new Date(dateStr).toLocaleString('es-AR')
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 sticky top-0 bg-white dark:bg-gray-800 z-10">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
              <CheckCircle className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Resolver Salvedad</h2>
              <p className="text-sm text-gray-500">ID: {salvedad.id}</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Detalle de la salvedad */}
        <div className="p-4 bg-gray-50 dark:bg-gray-900 border-b dark:border-gray-700 space-y-3">
          {/* Producto */}
          <div className="flex items-start gap-3">
            <div className="p-2 bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700">
              <Package className="w-6 h-6 text-gray-400" />
            </div>
            <div className="flex-1">
              <p className="font-medium text-gray-800 dark:text-white">
                {salvedad.producto_nombre || salvedad.producto?.nombre || 'Producto'}
              </p>
              {salvedad.producto_codigo && (
                <p className="text-sm text-gray-500">Codigo: {salvedad.producto_codigo}</p>
              )}
              <div className="flex gap-4 mt-1 text-sm">
                <span>Original: <span className="font-bold">{salvedad.cantidad_original}</span></span>
                <span className="text-red-600">Afectado: <span className="font-bold">{salvedad.cantidad_afectada}</span></span>
                <span className="text-green-600">Entregado: <span className="font-bold">{salvedad.cantidad_entregada}</span></span>
              </div>
            </div>
          </div>

          {/* Info adicional */}
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
            <div className="flex items-center gap-2">
              <User className="w-4 h-4 text-gray-400" />
              <span className="text-gray-600 dark:text-gray-400">Cliente:</span>
              <span className="font-medium dark:text-white">{salvedad.cliente_nombre || '-'}</span>
            </div>
            <div className="flex items-center gap-2">
              <Truck className="w-4 h-4 text-gray-400" />
              <span className="text-gray-600 dark:text-gray-400">Transportista:</span>
              <span className="font-medium dark:text-white">{salvedad.transportista_nombre || '-'}</span>
            </div>
            <div className="flex items-center gap-2">
              <Calendar className="w-4 h-4 text-gray-400" />
              <span className="text-gray-600 dark:text-gray-400">Reportado:</span>
              <span className="font-medium dark:text-white">{formatDate(salvedad.created_at)}</span>
            </div>
          </div>

          {/* Motivo y monto */}
          <div className="flex items-center justify-between p-3 bg-amber-50 dark:bg-amber-900/20 rounded-lg border border-amber-200 dark:border-amber-800">
            <div>
              <span className="text-sm text-amber-700 dark:text-amber-400 font-medium">
                Motivo: {MOTIVOS_SALVEDAD_LABELS[salvedad.motivo]}
              </span>
              {salvedad.descripcion && (
                <p className="text-sm text-amber-600 dark:text-amber-500 mt-1">{salvedad.descripcion}</p>
              )}
            </div>
            <div className="text-right">
              <p className="text-xs text-amber-600">Monto afectado</p>
              <p className="text-xl font-bold text-amber-700 dark:text-amber-400">
                {formatMoney(salvedad.monto_afectado)}
              </p>
            </div>
          </div>

          {/* Estado del stock */}
          <div className={`flex items-center gap-2 p-2 rounded-lg text-sm ${
            salvedad.stock_devuelto
              ? 'bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400'
              : 'bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-400'
          }`}>
            <AlertCircle className="w-4 h-4" />
            <span>
              {salvedad.stock_devuelto
                ? 'Stock devuelto al inventario'
                : 'Stock NO devuelto (perdida)'}
            </span>
          </div>

          {/* Foto de evidencia */}
          {salvedad.foto_url && (
            <div>
              <p className="text-sm text-gray-600 dark:text-gray-400 mb-1">Evidencia:</p>
              <img
                src={salvedad.foto_url}
                alt="Evidencia"
                className="max-h-32 rounded-lg border dark:border-gray-700"
              />
            </div>
          )}
        </div>

        {/* Formulario de resolucion */}
        <form onSubmit={handleSubmit} className="p-4 space-y-4">
          {/* Tipo de resolucion */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Tipo de resolucion *
            </label>
            <div className="space-y-2">
              {RESOLUCIONES.map(r => (
                <button
                  key={r.value}
                  type="button"
                  onClick={() => setResolucion(r.value)}
                  className={`w-full flex items-start gap-3 p-3 border rounded-lg text-left transition-colors ${
                    resolucion === r.value
                      ? `border-${r.color}-500 bg-${r.color}-50 dark:bg-${r.color}-900/20`
                      : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700'
                  }`}
                >
                  <div className={`w-4 h-4 rounded-full border-2 mt-0.5 flex-shrink-0 ${
                    resolucion === r.value
                      ? `border-${r.color}-500 bg-${r.color}-500`
                      : 'border-gray-300 dark:border-gray-500'
                  }`}>
                    {resolucion === r.value && (
                      <div className="w-full h-full flex items-center justify-center">
                        <div className="w-1.5 h-1.5 bg-white rounded-full" />
                      </div>
                    )}
                  </div>
                  <div>
                    <p className={`font-medium ${
                      resolucion === r.value ? `text-${r.color}-700 dark:text-${r.color}-400` : 'text-gray-700 dark:text-gray-300'
                    }`}>
                      {r.label}
                    </p>
                    <p className="text-xs text-gray-500">{r.descripcion}</p>
                  </div>
                </button>
              ))}
            </div>
          </div>

          {/* Notas de resolucion */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Notas de la resolucion *
            </label>
            <textarea
              value={notas}
              onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setNotas(e.target.value)}
              placeholder="Describa como se resuelve esta salvedad..."
              rows={3}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              required
            />
          </div>

          {/* Error */}
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}

          {/* Botones */}
          <div className="flex gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
            >
              Cancelar
            </button>
            <button
              type="submit"
              disabled={guardando || !resolucion || notas.trim().length < 5}
              className="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              {guardando ? (
                <>
                  <span className="animate-spin">...</span>
                  Resolviendo...
                </>
              ) : (
                <>
                  <CheckCircle className="w-4 h-4" />
                  Resolver Salvedad
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
