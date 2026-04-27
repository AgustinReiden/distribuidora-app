/**
 * VincularTelegramButton
 *
 * Botón compacto que dispara la generación de un código OTP para vincular el
 * chat de Telegram del usuario al bot oficial de la distribuidora (Phase 1
 * MVP de bot Telegram — ver `migrations/014_bot_telegram.sql` y task 1.3).
 *
 * Comportamiento:
 *  - Click: dispara `useGenerarCodigoVinculacionBot` y abre un modal con el
 *    código grande, instrucciones paso a paso, countdown live al expirar y
 *    botón de copiar al portapapeles.
 *  - Cuando expira el TTL (10 min), se deshabilita el código y se invita a
 *    generar uno nuevo.
 *  - Si la mutation falla, se muestra un alert inline dentro del modal.
 *
 * NO requiere props: usa `auth.uid()` server-side via la RPC.
 */
import { useState, useEffect, useMemo, useCallback } from 'react'
import { Send, Copy, Check, RefreshCcw, Loader2, AlertTriangle } from 'lucide-react'
import ModalBase from '../modals/ModalBase'
import { useGenerarCodigoVinculacionBot } from '../../hooks/queries/useBotVinculacion'

// El username del bot se inyecta vía env var (`VITE_TELEGRAM_BOT_USERNAME`)
// para que se pueda actualizar sin re-deploys cuando BotFather lo cree.
// Fallback al placeholder genérico mientras el bot público todavía no existe.
const BOT_USERNAME = import.meta.env.VITE_TELEGRAM_BOT_USERNAME ?? '@TuBotDeTelegram'

/** Formatea ms restantes como mm:ss (ej: 09:35). */
function formatMmSs(msRestantes: number): string {
  const totalSegundos = Math.max(0, Math.floor(msRestantes / 1000))
  const minutos = Math.floor(totalSegundos / 60)
  const segundos = totalSegundos % 60
  return `${String(minutos).padStart(2, '0')}:${String(segundos).padStart(2, '0')}`
}

interface VincularTelegramModalProps {
  codigo: string
  expiraAt: string
  onRegenerar: () => void
  onClose: () => void
  generando: boolean
}

function VincularTelegramModal({
  codigo,
  expiraAt,
  onRegenerar,
  onClose,
  generando,
}: VincularTelegramModalProps) {
  // Tick interno de 1s para refrescar el countdown.
  const [now, setNow] = useState<number>(() => Date.now())
  const [copiado, setCopiado] = useState<boolean>(false)

  const expiraTs = useMemo(() => new Date(expiraAt).getTime(), [expiraAt])
  const msRestantes = expiraTs - now
  const expirado = msRestantes <= 0

  useEffect(() => {
    if (expirado) return
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [expirado])

  // Resetear el feedback de "copiado" si el código cambia (regenerar).
  useEffect(() => {
    setCopiado(false)
  }, [codigo])

  const handleCopiar = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(codigo)
      setCopiado(true)
      window.setTimeout(() => setCopiado(false), 2000)
    } catch {
      // En entornos sin permisos de clipboard (HTTP, iframe sandbox), no
      // rompemos: el usuario todavía puede leer el código de la pantalla.
    }
  }, [codigo])

  return (
    <ModalBase title="Vincular Telegram" onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4">
        {/* Código grande */}
        <div className="text-center">
          <p className="text-xs uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-2">
            Tu código de vinculación
          </p>
          <div
            className={`text-4xl font-mono font-bold tracking-widest py-4 px-2 rounded-lg border-2 ${
              expirado
                ? 'border-red-300 bg-red-50 dark:bg-red-900/20 text-gray-400 line-through'
                : 'border-blue-300 dark:border-blue-700 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300'
            }`}
            aria-label={`Código de vinculación ${codigo.split('').join(' ')}`}
          >
            {codigo}
          </div>

          {/* Countdown / expirado */}
          {expirado ? (
            <p className="mt-2 text-sm text-red-600 dark:text-red-400 flex items-center justify-center gap-1">
              <AlertTriangle className="w-4 h-4" />
              Código expirado, generá uno nuevo
            </p>
          ) : (
            <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
              Expira en{' '}
              <span className="font-mono font-semibold text-gray-700 dark:text-gray-200">
                {formatMmSs(msRestantes)}
              </span>
            </p>
          )}
        </div>

        {/* Instrucciones */}
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-4">
          <p className="text-sm font-semibold text-gray-700 dark:text-gray-200 mb-2">
            Cómo vincular tu cuenta
          </p>
          <ol className="list-decimal list-inside space-y-1.5 text-sm text-gray-600 dark:text-gray-300">
            <li>Abrí Telegram.</li>
            <li>
              Buscá el bot oficial:{' '}
              <code className="px-1.5 py-0.5 rounded bg-white dark:bg-gray-800 border dark:border-gray-600 font-mono text-xs">
                {BOT_USERNAME}
              </code>{' '}
              <span className="text-xs text-gray-400 italic">(Próximamente disponible)</span>
            </li>
            <li>
              Iniciá una conversación con{' '}
              <code className="px-1.5 py-0.5 rounded bg-white dark:bg-gray-800 border dark:border-gray-600 font-mono text-xs">
                /start
              </code>
              .
            </li>
            <li>
              Mandá este comando exacto:{' '}
              <code className="px-1.5 py-0.5 rounded bg-white dark:bg-gray-800 border dark:border-gray-600 font-mono text-xs">
                /vincular {codigo}
              </code>
              <span className="block text-xs text-gray-500 dark:text-gray-400 mt-0.5 ml-4">
                (o copiá y pegá la línea entera)
              </span>
            </li>
            <li>El bot te confirmará la vinculación.</li>
          </ol>
        </div>
      </div>

      {/* Acciones */}
      <div className="flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cerrar
        </button>
        <button
          onClick={onRegenerar}
          disabled={generando}
          className="px-4 py-2 border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 flex items-center justify-center gap-2"
        >
          {generando ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : (
            <RefreshCcw className="w-4 h-4" />
          )}
          Generar otro código
        </button>
        <button
          onClick={handleCopiar}
          disabled={expirado}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center justify-center gap-2"
        >
          {copiado ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
          {copiado ? '¡Copiado!' : 'Copiar código'}
        </button>
      </div>
    </ModalBase>
  )
}

interface VincularTelegramErrorModalProps {
  error: Error
  onReintentar: () => void
  onClose: () => void
  reintentando: boolean
}

function VincularTelegramErrorModal({
  error,
  onReintentar,
  onClose,
  reintentando,
}: VincularTelegramErrorModalProps) {
  return (
    <ModalBase title="Vincular Telegram" onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4">
        <div
          role="alert"
          className="flex items-start gap-3 p-3 rounded-lg border border-red-300 dark:border-red-700 bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-300"
        >
          <AlertTriangle className="w-5 h-5 flex-shrink-0 mt-0.5" />
          <div className="text-sm">
            <p className="font-semibold">No pudimos generar el código.</p>
            <p className="opacity-80 break-words">{error.message || 'Error desconocido'}</p>
          </div>
        </div>
      </div>
      <div className="flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cerrar
        </button>
        <button
          onClick={onReintentar}
          disabled={reintentando}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center justify-center gap-2"
        >
          {reintentando && <Loader2 className="w-4 h-4 animate-spin" />}
          Reintentar
        </button>
      </div>
    </ModalBase>
  )
}

export interface VincularTelegramButtonProps {
  /** Clases adicionales para el botón disparador. */
  className?: string
}

/**
 * Botón principal "Vincular Telegram". Abre un modal al hacer click y dispara
 * la generación del código.
 */
export default function VincularTelegramButton({ className }: VincularTelegramButtonProps) {
  const [abierto, setAbierto] = useState(false)
  const mutation = useGenerarCodigoVinculacionBot()

  const handleClick = (): void => {
    setAbierto(true)
    mutation.mutate()
  }

  const handleRegenerar = (): void => {
    mutation.mutate()
  }

  const handleClose = (): void => {
    setAbierto(false)
    mutation.reset()
  }

  return (
    <>
      <button
        type="button"
        onClick={handleClick}
        aria-label="Vincular Telegram"
        className={
          className ??
          'flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors'
        }
      >
        <Send className="w-5 h-5" />
        <span>Vincular Telegram</span>
      </button>

      {abierto && mutation.data && !mutation.isError && (
        <VincularTelegramModal
          codigo={mutation.data.codigo}
          expiraAt={mutation.data.expira_at}
          onRegenerar={handleRegenerar}
          onClose={handleClose}
          generando={mutation.isPending}
        />
      )}

      {abierto && mutation.isPending && !mutation.data && (
        <ModalBase title="Vincular Telegram" onClose={handleClose} maxWidth="max-w-lg">
          <div className="p-8 flex flex-col items-center justify-center gap-3">
            <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
            <p className="text-sm text-gray-500 dark:text-gray-400">Generando código…</p>
          </div>
        </ModalBase>
      )}

      {abierto && mutation.isError && !mutation.data && mutation.error && (
        <VincularTelegramErrorModal
          error={mutation.error}
          onReintentar={handleRegenerar}
          onClose={handleClose}
          reintentando={mutation.isPending}
        />
      )}
    </>
  )
}
