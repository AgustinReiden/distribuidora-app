import { useState, useRef, useEffect } from 'react'
import { Building2, ChevronDown } from 'lucide-react'
import { useSucursal } from '../../contexts/SucursalContext'

export default function SucursalSelector() {
  const { currentSucursalId, currentSucursalNombre, sucursales, hasMutipleSucursales, switchSucursal } = useSucursal()
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  // Close on outside click
  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  if (!currentSucursalId) return null

  // Single sucursal: static badge, no dropdown
  if (!hasMutipleSucursales) {
    return (
      <div className="flex items-center space-x-1.5 px-2 py-1 rounded-md bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 text-sm">
        <Building2 className="w-4 h-4" />
        <span className="font-medium truncate max-w-[120px]">{currentSucursalNombre}</span>
      </div>
    )
  }

  // Multiple sucursales: dropdown selector
  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        aria-haspopup="listbox"
        aria-label="Cambiar sucursal"
        className="flex items-center space-x-1.5 px-2 py-1.5 rounded-lg bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900/50 transition-colors text-sm"
      >
        <Building2 className="w-4 h-4" />
        <span className="font-medium truncate max-w-[120px]">{currentSucursalNombre}</span>
        <ChevronDown className={`w-3.5 h-3.5 transition-transform ${open ? 'rotate-180' : ''}`} />
      </button>

      {open && (
        <div
          role="listbox"
          aria-label="Sucursales disponibles"
          className="absolute right-0 top-full mt-1 w-56 bg-white dark:bg-gray-800 rounded-lg shadow-lg border border-gray-200 dark:border-gray-700 py-1 z-50"
        >
          {sucursales.map(suc => (
            <button
              key={suc.id}
              role="option"
              aria-selected={suc.id === currentSucursalId}
              onClick={async () => {
                setOpen(false)
                await switchSucursal(suc.id)
              }}
              className={`w-full text-left px-3 py-2 text-sm flex items-center justify-between transition-colors ${
                suc.id === currentSucursalId
                  ? 'bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 font-medium'
                  : 'text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
              }`}
            >
              <span className="truncate">{suc.nombre}</span>
              <span className="text-xs text-gray-400 dark:text-gray-500 ml-2 capitalize">{suc.rol}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
