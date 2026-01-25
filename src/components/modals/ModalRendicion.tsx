/**
 * Modal para que transportistas/admin presenten la rendicion del dia
 * Muestra resumen de cobros y permite ingresar monto rendido con ajustes
 */
import React, { useState, FormEvent, ChangeEvent } from 'react'
import { X, DollarSign, Plus, Trash2, AlertTriangle, CheckCircle, FileText, Banknote } from 'lucide-react'
import { TIPOS_AJUSTE_LABELS } from '../../lib/schemas'
import type { RendicionDBExtended, TipoAjusteRendicion, RendicionAjusteInput } from '../../types'

interface AjusteTemp extends RendicionAjusteInput {
  id: string;
}

export interface ModalRendicionProps {
  rendicion: RendicionDBExtended;
  onPresentar: (data: {
    rendicionId: string;
    montoRendido: number;
    justificacion?: string;
    ajustes: RendicionAjusteInput[];
  }) => Promise<{ success: boolean; diferencia: number }>;
  onClose: () => void;
}

export default function ModalRendicion({
  rendicion,
  onPresentar,
  onClose
}: ModalRendicionProps): React.ReactElement {
  const [montoRendido, setMontoRendido] = useState<number | string>(rendicion.total_efectivo_esperado || 0)
  const [justificacion, setJustificacion] = useState<string>('')
  const [ajustes, setAjustes] = useState<AjusteTemp[]>([])
  const [guardando, setGuardando] = useState<boolean>(false)
  const [error, setError] = useState<string>('')

  // Para agregar nuevo ajuste
  const [nuevoAjuste, setNuevoAjuste] = useState<{
    tipo: TipoAjusteRendicion | '';
    monto: number | string;
    descripcion: string;
  }>({ tipo: '', monto: '', descripcion: '' })
  const [mostrarFormAjuste, setMostrarFormAjuste] = useState<boolean>(false)

  const montoRendidoNum = typeof montoRendido === 'string' ? parseFloat(montoRendido) || 0 : montoRendido
  const diferencia = montoRendidoNum - (rendicion.total_efectivo_esperado || 0)
  const hayDiferencia = Math.abs(diferencia) > 0.01

  const handleAgregarAjuste = (): void => {
    if (!nuevoAjuste.tipo || !nuevoAjuste.monto || !nuevoAjuste.descripcion) {
      return
    }

    const montoAjuste = typeof nuevoAjuste.monto === 'string' ? parseFloat(nuevoAjuste.monto) || 0 : nuevoAjuste.monto

    if (nuevoAjuste.descripcion.length < 10) {
      setError('La descripcion del ajuste debe tener al menos 10 caracteres')
      return
    }

    setAjustes([
      ...ajustes,
      {
        id: Date.now().toString(),
        tipo: nuevoAjuste.tipo as TipoAjusteRendicion,
        monto: montoAjuste,
        descripcion: nuevoAjuste.descripcion
      }
    ])

    setNuevoAjuste({ tipo: '', monto: '', descripcion: '' })
    setMostrarFormAjuste(false)
    setError('')
  }

  const handleEliminarAjuste = (id: string): void => {
    setAjustes(ajustes.filter(a => a.id !== id))
  }

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    setError('')

    if (hayDiferencia && !justificacion.trim() && ajustes.length === 0) {
      setError('Debe justificar la diferencia o agregar ajustes')
      return
    }

    setGuardando(true)
    try {
      const result = await onPresentar({
        rendicionId: rendicion.id,
        montoRendido: montoRendidoNum,
        justificacion: justificacion.trim() || undefined,
        ajustes: ajustes.map(({ tipo, monto, descripcion }) => ({ tipo, monto, descripcion }))
      })

      if (!result.success) {
        setError('Error al presentar la rendicion')
        return
      }

      onClose()
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error al presentar la rendicion'
      setError(errorMessage)
    } finally {
      setGuardando(false)
    }
  }

  const formatMoney = (value: number): string => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value)
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 sticky top-0 bg-white dark:bg-gray-800 z-10">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <Banknote className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Rendicion del Dia</h2>
              <p className="text-sm text-gray-500">Fecha: {new Date(rendicion.fecha).toLocaleDateString('es-AR')}</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Resumen del recorrido */}
        <div className="p-4 bg-gray-50 dark:bg-gray-900 border-b dark:border-gray-700">
          <h3 className="text-sm font-medium text-gray-600 dark:text-gray-400 mb-3">Resumen del Recorrido</h3>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-700">
              <p className="text-xs text-gray-500">Pedidos Entregados</p>
              <p className="text-xl font-bold text-gray-800 dark:text-white">
                {rendicion.pedidos_entregados || 0}/{rendicion.total_pedidos || 0}
              </p>
            </div>
            <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-700">
              <p className="text-xs text-gray-500">Total Facturado</p>
              <p className="text-xl font-bold text-blue-600">
                {formatMoney(rendicion.total_facturado || 0)}
              </p>
            </div>
            <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-700">
              <p className="text-xs text-gray-500">Efectivo Esperado</p>
              <p className="text-xl font-bold text-green-600">
                {formatMoney(rendicion.total_efectivo_esperado || 0)}
              </p>
            </div>
            <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-700">
              <p className="text-xs text-gray-500">Otros Medios</p>
              <p className="text-xl font-bold text-purple-600">
                {formatMoney(rendicion.total_otros_medios || 0)}
              </p>
            </div>
          </div>
        </div>

        {/* Items de la rendicion */}
        {rendicion.items && rendicion.items.length > 0 && (
          <div className="p-4 border-b dark:border-gray-700">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-400 mb-3">
              Detalle de Cobros ({rendicion.items.length} pedidos)
            </h3>
            <div className="max-h-40 overflow-y-auto space-y-2">
              {rendicion.items.map(item => (
                <div key={item.id} className="flex justify-between items-center p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-sm">
                  <div>
                    <span className="font-medium">Pedido #{item.pedido_id}</span>
                    <span className="ml-2 px-2 py-0.5 bg-gray-200 dark:bg-gray-700 rounded text-xs">
                      {item.forma_pago}
                    </span>
                  </div>
                  <span className={`font-bold ${item.forma_pago === 'efectivo' ? 'text-green-600' : 'text-purple-600'}`}>
                    {formatMoney(item.monto_cobrado)}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Formulario */}
        <form onSubmit={handleSubmit} className="p-4 space-y-4">
          {/* Monto rendido */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <DollarSign className="w-4 h-4 inline mr-1" />
              Monto que rinde (efectivo) *
            </label>
            <input
              type="number"
              step="0.01"
              min="0"
              value={montoRendido}
              onChange={(e: ChangeEvent<HTMLInputElement>) => setMontoRendido(e.target.value)}
              className="w-full px-4 py-3 text-lg font-bold border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              required
            />
          </div>

          {/* Diferencia */}
          <div className={`p-4 rounded-lg flex items-center gap-3 ${
            !hayDiferencia
              ? 'bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800'
              : diferencia > 0
                ? 'bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800'
                : 'bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800'
          }`}>
            {!hayDiferencia ? (
              <CheckCircle className="w-6 h-6 text-green-600" />
            ) : (
              <AlertTriangle className={`w-6 h-6 ${diferencia > 0 ? 'text-blue-600' : 'text-red-600'}`} />
            )}
            <div>
              <p className={`font-medium ${
                !hayDiferencia
                  ? 'text-green-700 dark:text-green-400'
                  : diferencia > 0
                    ? 'text-blue-700 dark:text-blue-400'
                    : 'text-red-700 dark:text-red-400'
              }`}>
                {!hayDiferencia
                  ? 'Sin diferencia'
                  : diferencia > 0
                    ? `Sobrante: ${formatMoney(diferencia)}`
                    : `Faltante: ${formatMoney(Math.abs(diferencia))}`
                }
              </p>
              {hayDiferencia && (
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  Debe justificar esta diferencia
                </p>
              )}
            </div>
          </div>

          {/* Justificacion (si hay diferencia) */}
          {hayDiferencia && (
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                <FileText className="w-4 h-4 inline mr-1" />
                Justificacion de la diferencia
              </label>
              <textarea
                value={justificacion}
                onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setJustificacion(e.target.value)}
                placeholder="Explique el motivo de la diferencia..."
                rows={2}
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
          )}

          {/* Ajustes */}
          <div>
            <div className="flex items-center justify-between mb-2">
              <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Ajustes ({ajustes.length})
              </label>
              {!mostrarFormAjuste && (
                <button
                  type="button"
                  onClick={() => setMostrarFormAjuste(true)}
                  className="text-sm text-green-600 hover:text-green-700 flex items-center gap-1"
                >
                  <Plus className="w-4 h-4" />
                  Agregar ajuste
                </button>
              )}
            </div>

            {/* Lista de ajustes */}
            {ajustes.length > 0 && (
              <div className="space-y-2 mb-3">
                {ajustes.map(ajuste => (
                  <div key={ajuste.id} className="flex items-center gap-2 p-2 bg-gray-50 dark:bg-gray-900 rounded-lg">
                    <div className="flex-1">
                      <div className="flex items-center gap-2">
                        <span className={`px-2 py-0.5 rounded text-xs font-medium ${
                          ajuste.tipo === 'sobrante' || ajuste.tipo === 'descuento_autorizado'
                            ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
                            : 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400'
                        }`}>
                          {TIPOS_AJUSTE_LABELS[ajuste.tipo]}
                        </span>
                        <span className="font-bold">{formatMoney(ajuste.monto)}</span>
                      </div>
                      <p className="text-xs text-gray-500 mt-1">{ajuste.descripcion}</p>
                    </div>
                    <button
                      type="button"
                      onClick={() => handleEliminarAjuste(ajuste.id)}
                      className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                ))}
              </div>
            )}

            {/* Form para nuevo ajuste */}
            {mostrarFormAjuste && (
              <div className="p-3 border dark:border-gray-600 rounded-lg bg-gray-50 dark:bg-gray-900 space-y-3">
                <div className="grid grid-cols-2 gap-2">
                  <select
                    value={nuevoAjuste.tipo}
                    onChange={(e) => setNuevoAjuste({ ...nuevoAjuste, tipo: e.target.value as TipoAjusteRendicion })}
                    className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm"
                  >
                    <option value="">Tipo de ajuste</option>
                    {Object.entries(TIPOS_AJUSTE_LABELS).map(([value, label]) => (
                      <option key={value} value={value}>{label}</option>
                    ))}
                  </select>
                  <input
                    type="number"
                    step="0.01"
                    min="0"
                    placeholder="Monto"
                    value={nuevoAjuste.monto}
                    onChange={(e) => setNuevoAjuste({ ...nuevoAjuste, monto: e.target.value })}
                    className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm"
                  />
                </div>
                <input
                  type="text"
                  placeholder="Descripcion del ajuste (min 10 caracteres)"
                  value={nuevoAjuste.descripcion}
                  onChange={(e) => setNuevoAjuste({ ...nuevoAjuste, descripcion: e.target.value })}
                  className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm"
                />
                <div className="flex gap-2">
                  <button
                    type="button"
                    onClick={() => {
                      setMostrarFormAjuste(false)
                      setNuevoAjuste({ tipo: '', monto: '', descripcion: '' })
                    }}
                    className="flex-1 px-3 py-1 text-sm border dark:border-gray-600 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700"
                  >
                    Cancelar
                  </button>
                  <button
                    type="button"
                    onClick={handleAgregarAjuste}
                    disabled={!nuevoAjuste.tipo || !nuevoAjuste.monto || nuevoAjuste.descripcion.length < 10}
                    className="flex-1 px-3 py-1 text-sm bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg"
                  >
                    Agregar
                  </button>
                </div>
              </div>
            )}
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
              disabled={guardando || (hayDiferencia && !justificacion.trim() && ajustes.length === 0)}
              className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              {guardando ? (
                <>
                  <span className="animate-spin">...</span>
                  Presentando...
                </>
              ) : (
                <>
                  <CheckCircle className="w-4 h-4" />
                  Presentar Rendicion
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
