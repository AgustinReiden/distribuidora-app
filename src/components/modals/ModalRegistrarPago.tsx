import React, { useState, FormEvent, ChangeEvent } from 'react'
import { X, DollarSign, FileText, AlertCircle, Check } from 'lucide-react'
import { formatPrecio as formatCurrency } from '../../utils/formatters'
import { useZodValidation } from '../../hooks/useZodValidation'
import { modalPagoSchema } from '../../lib/schemas'
import type { ClienteDB, Pedido, Pago, FormaPago } from '../../types'

// Alias for the Cliente type used in this component
type Cliente = ClienteDB;

interface FormaPagoOption {
  value: string;
  label: string;
}

const FORMAS_PAGO: FormaPagoOption[] = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'tarjeta', label: 'Tarjeta' },
  { value: 'cuenta_corriente', label: 'Cuenta Corriente' }
]

interface PagoData {
  clienteId: string;
  pedidoId: string | null;
  monto: number;
  formaPago: string;
  referencia: string;
  notas: string;
}

interface PagoRegistrado extends Pago {
  monto: number;
}

export interface ModalRegistrarPagoProps {
  cliente: Cliente | null;
  saldoPendiente: number;
  pedidos: Pedido[];
  onClose: () => void;
  onConfirmar: (data: PagoData) => Promise<PagoRegistrado>;
  onGenerarRecibo?: (pago: PagoRegistrado, cliente: Cliente) => void;
}

export default function ModalRegistrarPago({
  cliente,
  saldoPendiente,
  pedidos,
  onClose,
  onConfirmar,
  onGenerarRecibo
}: ModalRegistrarPagoProps): React.ReactElement | null {
  // Zod validation hook
  const { validate, getFirstError } = useZodValidation(modalPagoSchema)

  const [monto, setMonto] = useState<string>('')
  const [formaPago, setFormaPago] = useState<string>('efectivo')
  const [referencia, setReferencia] = useState<string>('')
  const [notas, setNotas] = useState<string>('')
  const [pedidoSeleccionado, setPedidoSeleccionado] = useState<string>('')
  const [loading, setLoading] = useState<boolean>(false)
  const [pagoRegistrado, setPagoRegistrado] = useState<PagoRegistrado | null>(null)
  const [error, setError] = useState<string>('')

  // Filter pending payment orders
  const pedidosPendientes = (pedidos || []).filter(p =>
    p.cliente_id === cliente?.id && p.estado_pago !== 'pagado'
  )

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    setError('')

    // Validar con Zod
    const result = validate({ monto: parseFloat(monto) || 0, formaPago, referencia, notas, pedidoSeleccionado })
    if (!result.success) {
      setError(getFirstError() || 'Error de validacion')
      return
    }

    setLoading(true)
    try {
      const pago = await onConfirmar({
        clienteId: cliente!.id,
        pedidoId: pedidoSeleccionado || null,
        monto: result.data.monto,
        formaPago,
        referencia,
        notas
      })
      setPagoRegistrado(pago)
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error al registrar el pago'
      setError(errorMessage)
    } finally {
      setLoading(false)
    }
  }

  const handleMontoPreset = (porcentaje: number): void => {
    if (saldoPendiente) {
      setMonto((saldoPendiente * porcentaje / 100).toFixed(2))
    }
  }

  if (!cliente) return null

  // Success screen
  if (pagoRegistrado) {
    return (
      <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
        <div className="bg-white dark:bg-gray-800 rounded-2xl w-full max-w-md p-6">
          <div className="text-center">
            <div className="w-16 h-16 bg-green-100 dark:bg-green-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
              <Check className="w-8 h-8 text-green-600" />
            </div>
            <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
              Pago Registrado
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-4">
              Se registro un pago de <span className="font-bold text-green-600">{formatCurrency(pagoRegistrado.monto)}</span> para {cliente.nombre_fantasia}
            </p>
            <div className="flex gap-3 justify-center">
              {onGenerarRecibo && (
                <button
                  onClick={() => onGenerarRecibo(pagoRegistrado, cliente)}
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg flex items-center gap-2"
                >
                  <FileText className="w-4 h-4" />
                  Generar Recibo
                </button>
              )}
              <button
                onClick={onClose}
                className="px-4 py-2 bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-900 dark:text-white rounded-lg"
              >
                Cerrar
              </button>
            </div>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-2xl w-full max-w-md">
        {/* Header */}
        <div className="p-6 border-b border-gray-200 dark:border-gray-700">
          <div className="flex justify-between items-center">
            <div>
              <h2 className="text-xl font-bold text-gray-900 dark:text-white">Registrar Pago</h2>
              <p className="text-gray-600 dark:text-gray-400">{cliente.nombre_fantasia}</p>
            </div>
            <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
              <X className="w-5 h-5" />
            </button>
          </div>

          {/* Balance info */}
          {saldoPendiente > 0 && (
            <div className="mt-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 rounded-lg">
              <div className="flex justify-between items-center">
                <span className="text-yellow-700 dark:text-yellow-400">Saldo pendiente:</span>
                <span className="text-xl font-bold text-yellow-700 dark:text-yellow-400">
                  {formatCurrency(saldoPendiente)}
                </span>
              </div>
            </div>
          )}
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit} className="p-6 space-y-4">
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-center gap-2 text-red-700 dark:text-red-400">
              <AlertCircle className="w-4 h-4" />
              {error}
            </div>
          )}

          {/* Monto */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Monto *
            </label>
            <div className="relative">
              <DollarSign className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400" />
              <input
                type="number"
                step="0.01"
                min="0"
                value={monto}
                onChange={(e: ChangeEvent<HTMLInputElement>) => setMonto(e.target.value)}
                placeholder="0.00"
                className="w-full pl-10 pr-4 py-3 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white text-lg font-semibold"
                required
              />
            </div>
            {saldoPendiente > 0 && (
              <div className="flex gap-2 mt-2">
                <button
                  type="button"
                  onClick={() => handleMontoPreset(100)}
                  className="px-3 py-1 text-xs bg-blue-100 hover:bg-blue-200 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400 rounded"
                >
                  Total
                </button>
                <button
                  type="button"
                  onClick={() => handleMontoPreset(50)}
                  className="px-3 py-1 text-xs bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded"
                >
                  50%
                </button>
                <button
                  type="button"
                  onClick={() => handleMontoPreset(25)}
                  className="px-3 py-1 text-xs bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded"
                >
                  25%
                </button>
              </div>
            )}
          </div>

          {/* Forma de pago */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Forma de Pago
            </label>
            <div className="grid grid-cols-3 gap-2">
              {FORMAS_PAGO.slice(0, 3).map(fp => (
                <button
                  key={fp.value}
                  type="button"
                  onClick={() => setFormaPago(fp.value)}
                  className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                    formaPago === fp.value
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                  }`}
                >
                  {fp.label}
                </button>
              ))}
            </div>
            <div className="grid grid-cols-2 gap-2 mt-2">
              {FORMAS_PAGO.slice(3).map(fp => (
                <button
                  key={fp.value}
                  type="button"
                  onClick={() => setFormaPago(fp.value)}
                  className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                    formaPago === fp.value
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                  }`}
                >
                  {fp.label}
                </button>
              ))}
            </div>
          </div>

          {/* Referencia */}
          {(formaPago === 'transferencia' || formaPago === 'cheque') && (
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                {formaPago === 'cheque' ? 'Numero de Cheque *' : 'Referencia/Comprobante'}
              </label>
              <input
                type="text"
                value={referencia}
                onChange={(e: ChangeEvent<HTMLInputElement>) => setReferencia(e.target.value)}
                placeholder={formaPago === 'cheque' ? 'Ej: 12345678' : 'Ej: TRF-001234'}
                className={`w-full px-4 py-2 border rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white ${
                  formaPago === 'cheque' && !referencia.trim()
                    ? 'border-yellow-400 dark:border-yellow-600'
                    : 'border-gray-300 dark:border-gray-600'
                }`}
                required={formaPago === 'cheque'}
              />
              {formaPago === 'cheque' && !referencia.trim() && (
                <p className="text-xs text-yellow-600 mt-1">Campo obligatorio para pagos con cheque</p>
              )}
            </div>
          )}

          {/* Aplicar a pedido especifico */}
          {pedidosPendientes.length > 0 && (
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Aplicar a Pedido (opcional)
              </label>
              <select
                value={pedidoSeleccionado}
                onChange={(e: ChangeEvent<HTMLSelectElement>) => setPedidoSeleccionado(e.target.value)}
                className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
              >
                <option value="">Pago a cuenta general</option>
                {pedidosPendientes.map(p => (
                  <option key={p.id} value={p.id}>
                    Pedido #{p.id} - {formatCurrency(p.total)}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Notas */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Notas (opcional)
            </label>
            <textarea
              value={notas}
              onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setNotas(e.target.value)}
              placeholder="Observaciones del pago..."
              rows={2}
              className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white resize-none"
            />
          </div>

          {/* Actions */}
          <div className="flex gap-3 pt-4">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-3 bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-900 dark:text-white rounded-lg font-medium"
            >
              Cancelar
            </button>
            <button
              type="submit"
              disabled={loading || !monto}
              className="flex-1 px-4 py-3 bg-green-600 hover:bg-green-700 disabled:opacity-50 text-white rounded-lg font-medium flex items-center justify-center gap-2"
            >
              {loading ? (
                <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-white" />
              ) : (
                <>
                  <Check className="w-5 h-5" />
                  Registrar
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
