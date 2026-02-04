import { UserCog, Edit2 } from 'lucide-react';
import { getRolColor, getRolLabel } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import type { PerfilDB } from '../../types';

export interface VistaUsuariosProps {
  usuarios: PerfilDB[];
  loading: boolean;
  onEditarUsuario: (usuario: PerfilDB) => void;
}

export default function VistaUsuarios({
  usuarios,
  loading,
  onEditarUsuario
}: VistaUsuariosProps) {
  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Usuarios</h1>
        <p className="text-gray-600 dark:text-gray-400 text-sm mt-1">
          Para crear usuarios, hacelo desde Supabase → Authentication → Users
        </p>
      </div>

      {loading ? <LoadingSpinner /> : usuarios.length === 0 ? (
        <div className="text-center py-12 text-gray-500 dark:text-gray-400">
          <UserCog className="w-12 h-12 mx-auto mb-3 opacity-50" aria-hidden="true" />
          <p>No hay usuarios</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full" role="table">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Nombre</th>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Email</th>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Rol</th>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Estado</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Acciones</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {usuarios.map((usuario: PerfilDB) => (
                <tr key={usuario.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors">
                  <td className="px-4 py-3 font-medium text-gray-800 dark:text-white">{usuario.nombre}</td>
                  <td className="px-4 py-3 text-gray-600 dark:text-gray-400">{usuario.email}</td>
                  <td className="px-4 py-3">
                    <span className={`px-2 py-1 rounded-full text-sm ${getRolColor(usuario.rol)}`}>
                      {getRolLabel(usuario.rol)}
                    </span>
                  </td>
                  <td className="px-4 py-3">
                    <span className={`px-2 py-1 rounded-full text-sm ${
                      usuario.activo ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400' : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'
                    }`}>
                      {usuario.activo ? 'Activo' : 'Inactivo'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => onEditarUsuario(usuario)}
                      className="p-2 text-blue-500 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-lg transition-colors"
                      title="Editar"
                      aria-label={`Editar usuario ${usuario.nombre}`}
                    >
                      <Edit2 className="w-4 h-4" aria-hidden="true" />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
