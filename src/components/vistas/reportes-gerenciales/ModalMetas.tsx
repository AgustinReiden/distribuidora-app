import React, { useState } from 'react'
import { X, Target } from 'lucide-react'
import { Button } from '../../ui/Button'
import { CampoNumero } from '../../ui/CampoNumero'
import { esTextoIlegible, leerNumero, numeroConMiles } from '../../../utils/normalizarNumero'
import type { MetasGerenciales } from '../../../hooks/queries'

/** Modal para cargar las metas (objetivos) del mes: venta y margen neto. */
export default function ModalMetas({
  metas,
  periodoLabel,
  sucursalNombre,
  onGuardar,
  onClose,
  guardando = false,
}: {
  metas: MetasGerenciales | null
  periodoLabel: string
  sucursalNombre: string
  onGuardar: (venta: number | null, margenNeto: number | null) => void
  onClose: () => void
  guardando?: boolean
}): React.ReactElement {
  const [venta, setVenta] = useState<string>(metas?.venta != null ? numeroConMiles(Number(metas.venta)) : '')
  const [margen, setMargen] = useState<string>(metas?.margen_neto != null ? numeroConMiles(Number(metas.margen_neto)) : '')

  // B20 (D17): plata, con los miles que pone el campo. Antes se borraba todo menos dígitos, punto y
  // menos: «1.500,50» quedaba 1,5005 y «20.000.000», sin meta. Lo que no se entiende no se guarda.
  const parse = (s: string): number | null => (s.trim() === '' ? null : leerNumero(s))
  const ilegible = esTextoIlegible(venta) || esTextoIlegible(margen)

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-sm p-5" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-1">
          <h3 className="text-lg font-bold text-gray-900 dark:text-white flex items-center gap-2">
            <Target className="w-5 h-5 text-blue-600" /> Metas del mes
          </h3>
          <Button
            variant="ghost"
            size="iconSm"
            onClick={onClose}
            className="text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-gray-300"
            aria-label="Cerrar"
          >
            <X className="w-5 h-5" />
          </Button>
        </div>
        <p className="text-xs text-gray-500 dark:text-gray-400 mb-4">{sucursalNombre} · {periodoLabel}</p>

        <label className="block text-sm font-medium mb-1 dark:text-gray-200">Venta objetivo ($)</label>
        <CampoNumero
          aria-label="Venta objetivo"
          negativo
          value={venta}
          onChange={setVenta}
          placeholder="Ej: 20000000"
          className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm mb-3"
        />
        <label className="block text-sm font-medium mb-1 dark:text-gray-200">Margen neto objetivo ($)</label>
        <CampoNumero
          aria-label="Margen neto objetivo"
          negativo
          value={margen}
          onChange={setMargen}
          placeholder="Ej: 6000000"
          className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm mb-4"
        />

        <div className="flex justify-end gap-2">
          <Button variant="ghost" size="md" onClick={onClose}>Cancelar</Button>
          <Button
            onClick={() => onGuardar(parse(venta), parse(margen))}
            disabled={guardando || ilegible}
            variant="primary"
            size="md"
          >
            Guardar
          </Button>
        </div>
      </div>
    </div>
  )
}
