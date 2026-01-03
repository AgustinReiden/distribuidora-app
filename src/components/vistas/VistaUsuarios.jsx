import React from 'react';
import { UserCog, Edit2 } from 'lucide-react';
import { getRolColor, getRolLabel } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';

export default function VistaUsuarios({
  usuarios,
  loading,
  onEditarUsuario
}) {
  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold text-gray-800">Usuarios</h1>
        <p className="text-gray-600 text-sm mt-1">
          Para crear usuarios, hacelo desde Supabase → Authentication → Users
        </p>
      </div>

      {loading ? <LoadingSpinner /> : usuarios.length === 0 ? (
        <div className="text-center py-12 text-gray-500">
          <UserCog className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay usuarios</p>
        </div>
      ) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Nombre</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Email</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Rol</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Estado</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Acciones</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {usuarios.map(usuario => (
                <tr key={usuario.id} className="hover:bg-gray-50 transition-colors">
                  <td className="px-4 py-3 font-medium text-gray-800">{usuario.nombre}</td>
                  <td className="px-4 py-3 text-gray-600">{usuario.email}</td>
                  <td className="px-4 py-3">
                    <span className={`px-2 py-1 rounded-full text-sm ${getRolColor(usuario.rol)}`}>
                      {getRolLabel(usuario.rol)}
                    </span>
                  </td>
                  <td className="px-4 py-3">
                    <span className={`px-2 py-1 rounded-full text-sm ${
                      usuario.activo ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
                    }`}>
                      {usuario.activo ? 'Activo' : 'Inactivo'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => onEditarUsuario(usuario)}
                      className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg transition-colors"
                      title="Editar"
                    >
                      <Edit2 className="w-4 h-4" />
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
