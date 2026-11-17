import { Loader2 } from 'lucide-react'

/**
 * El «estoy verificando» de una acción que espera la red antes de abrir nada. Una
 * pastilla fija abajo: no cambia el diseño de la pantalla que la dispara.
 */
export default function AvisoEspera({ visible, texto = 'Verificando…' }: { visible: boolean; texto?: string }) {
  if (!visible) return null
  return (
    <div
      role="status"
      aria-live="polite"
      className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 px-4 py-2 rounded-full bg-gray-900/90 text-white text-sm shadow-lg"
    >
      <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />
      {texto}
    </div>
  )
}
