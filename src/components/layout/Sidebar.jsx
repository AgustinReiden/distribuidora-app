import React, { useState } from 'react';
import { Truck, ChevronLeft, ChevronRight, LogOut, Moon, Sun, BarChart3, ShoppingCart, Users, Package, TrendingUp, UserCog } from 'lucide-react';
import { getRolColor, getRolLabel } from '../../utils/formatters';
import { useTheme } from '../../contexts/ThemeContext';

const menuConfig = [
  { id: 'dashboard', icon: BarChart3, label: 'Dashboard', roles: ['admin'] },
  { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'preventista', 'transportista'] },
  { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'preventista'] },
  { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'preventista'] },
  { id: 'reportes', icon: TrendingUp, label: 'Reportes', roles: ['admin'] },
  { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
];

export default function Sidebar({ vista, setVista, perfil, onLogout, colapsado, setColapsado }) {
  const { darkMode, toggleDarkMode } = useTheme();
  const menuItems = menuConfig.filter(item => item.roles.includes(perfil?.rol));

  return (
    <aside
      className={`fixed left-0 top-0 h-full bg-white dark:bg-gray-800 border-r dark:border-gray-700 shadow-lg transition-all duration-300 z-40 flex flex-col ${
        colapsado ? 'w-20' : 'w-64'
      }`}
    >
      {/* Header */}
      <div className={`flex items-center ${colapsado ? 'justify-center' : 'justify-between'} p-4 border-b dark:border-gray-700`}>
        {!colapsado && (
          <div className="flex items-center space-x-2">
            <div className="p-2 bg-blue-600 rounded-lg">
              <Truck className="w-6 h-6 text-white" />
            </div>
            <span className="font-bold text-xl text-gray-800 dark:text-white">Distribuidora</span>
          </div>
        )}
        {colapsado && (
          <div className="p-2 bg-blue-600 rounded-lg">
            <Truck className="w-6 h-6 text-white" />
          </div>
        )}
      </div>

      {/* Botón colapsar */}
      <button
        onClick={() => setColapsado(!colapsado)}
        className="absolute -right-3 top-20 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-full p-1 shadow-md hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        aria-label={colapsado ? 'Expandir menú' : 'Colapsar menú'}
      >
        {colapsado ? (
          <ChevronRight className="w-4 h-4 text-gray-600 dark:text-gray-300" />
        ) : (
          <ChevronLeft className="w-4 h-4 text-gray-600 dark:text-gray-300" />
        )}
      </button>

      {/* Menú */}
      <nav className="flex-1 p-4 space-y-2 overflow-y-auto">
        {menuItems.map(item => (
          <button
            key={item.id}
            onClick={() => setVista(item.id)}
            className={`flex items-center ${colapsado ? 'justify-center' : 'space-x-3'} w-full px-4 py-3 rounded-xl transition-all ${
              vista === item.id
                ? 'bg-blue-600 text-white shadow-md'
                : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700'
            }`}
            title={colapsado ? item.label : undefined}
            aria-current={vista === item.id ? 'page' : undefined}
          >
            <item.icon className="w-5 h-5 flex-shrink-0" />
            {!colapsado && <span className="font-medium">{item.label}</span>}
          </button>
        ))}
      </nav>

      {/* Footer */}
      <div className={`p-4 border-t dark:border-gray-700 space-y-3`}>
        {/* Toggle tema */}
        <button
          onClick={toggleDarkMode}
          className={`flex items-center ${colapsado ? 'justify-center' : 'space-x-3'} w-full px-4 py-3 rounded-xl text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors`}
          title={colapsado ? (darkMode ? 'Modo claro' : 'Modo oscuro') : undefined}
          aria-label={darkMode ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro'}
        >
          {darkMode ? <Sun className="w-5 h-5" /> : <Moon className="w-5 h-5" />}
          {!colapsado && <span>{darkMode ? 'Modo claro' : 'Modo oscuro'}</span>}
        </button>

        {/* Info usuario */}
        {!colapsado && (
          <div className="px-4 py-3 bg-gray-50 dark:bg-gray-700/50 rounded-xl">
            <p className="font-medium text-gray-800 dark:text-white text-sm truncate">{perfil?.nombre}</p>
            <p className="text-xs text-gray-500 dark:text-gray-400 truncate">{perfil?.email}</p>
            <span className={`inline-block mt-2 text-xs px-2 py-1 rounded-full ${getRolColor(perfil?.rol)}`}>
              {getRolLabel(perfil?.rol)}
            </span>
          </div>
        )}

        {/* Logout */}
        <button
          onClick={onLogout}
          className={`flex items-center ${colapsado ? 'justify-center' : 'space-x-3'} w-full px-4 py-3 rounded-xl text-red-600 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors`}
          title={colapsado ? 'Cerrar sesión' : undefined}
          aria-label="Cerrar sesión"
        >
          <LogOut className="w-5 h-5" />
          {!colapsado && <span>Cerrar sesión</span>}
        </button>
      </div>
    </aside>
  );
}
