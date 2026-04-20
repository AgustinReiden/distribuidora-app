import type { ReactElement } from 'react'
import { Building2 } from 'lucide-react'

interface SinSucursalScreenProps {
  onLogout: () => void
}

/**
 * Blocking screen shown when the authenticated user has no rows in
 * usuario_sucursales. Replaces the previous "phantom fallback" that
 * silently pretended the user was on sucursal id=1 (C6). The user must
 * contact an admin to be assigned via the asignar_usuario_sucursal RPC
 * from migration 063.
 */
export default function SinSucursalScreen({ onLogout }: SinSucursalScreenProps): ReactElement {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-900 p-6 transition-colors">
      <div className="max-w-md w-full text-center bg-white dark:bg-gray-800 rounded-lg shadow-lg p-8">
        <div className="mx-auto w-14 h-14 rounded-full bg-blue-50 dark:bg-blue-900/30 flex items-center justify-center mb-4">
          <Building2 className="w-7 h-7 text-blue-600 dark:text-blue-300" />
        </div>
        <h1 className="text-xl font-semibold text-gray-900 dark:text-gray-100 mb-3">
          Sin sucursal asignada
        </h1>
        <p className="text-gray-600 dark:text-gray-400 mb-6">
          Tu cuenta no tiene sucursales asignadas. Por favor contactá a un administrador
          para que te asigne al menos una sucursal antes de poder usar la aplicación.
        </p>
        <button
          type="button"
          onClick={onLogout}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors"
        >
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}
