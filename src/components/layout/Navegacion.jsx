import React, { useState } from 'react';
import { Truck, Menu, LogOut, BarChart3, ShoppingCart, Users, Package, TrendingUp, UserCog } from 'lucide-react';
import { getRolColor, getRolLabel } from '../../utils/formatters';

const menuConfig = [
  { id: 'dashboard', icon: BarChart3, label: 'Dashboard', roles: ['admin'] },
  { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'preventista', 'transportista'] },
  { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'preventista'] },
  { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'preventista'] },
  { id: 'reportes', icon: TrendingUp, label: 'Reportes', roles: ['admin'] },
  { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
];

export default function Navegacion({ vista, setVista, perfil, onLogout }) {
  const [menuAbierto, setMenuAbierto] = useState(false);

  const menuItems = menuConfig.filter(item => item.roles.includes(perfil?.rol));

  return (
    <nav className="bg-blue-600 text-white shadow-lg">
      <div className="max-w-7xl mx-auto px-4">
        <div className="flex justify-between items-center h-16">
          {/* Logo */}
          <div className="flex items-center space-x-2">
            <Truck className="w-8 h-8" />
            <span className="font-bold text-xl hidden sm:block">Distribuidora</span>
          </div>

          {/* Menu Desktop */}
          <div className="hidden md:flex items-center space-x-1">
            {menuItems.map(item => (
              <button
                key={item.id}
                onClick={() => setVista(item.id)}
                className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-colors ${
                  vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'
                }`}
              >
                <item.icon className="w-5 h-5" />
                <span>{item.label}</span>
              </button>
            ))}

            {/* Usuario info */}
            <div className="ml-4 pl-4 border-l border-blue-400 flex items-center space-x-3">
              <span className="text-sm">{perfil?.nombre}</span>
              <span className={`text-xs px-2 py-1 rounded ${getRolColor(perfil?.rol)}`}>
                {getRolLabel(perfil?.rol)}
              </span>
              <button
                onClick={onLogout}
                className="p-2 hover:bg-blue-500 rounded-lg transition-colors"
                title="Cerrar sesión"
              >
                <LogOut className="w-5 h-5" />
              </button>
            </div>
          </div>

          {/* Menu Mobile Toggle */}
          <button
            className="md:hidden p-2"
            onClick={() => setMenuAbierto(!menuAbierto)}
          >
            <Menu className="w-6 h-6" />
          </button>
        </div>

        {/* Menu Mobile */}
        {menuAbierto && (
          <div className="md:hidden pb-4 space-y-2">
            {menuItems.map(item => (
              <button
                key={item.id}
                onClick={() => { setVista(item.id); setMenuAbierto(false); }}
                className={`flex items-center space-x-2 w-full px-4 py-2 rounded-lg transition-colors ${
                  vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'
                }`}
              >
                <item.icon className="w-5 h-5" />
                <span>{item.label}</span>
              </button>
            ))}
            <div className="pt-2 mt-2 border-t border-blue-400">
              <div className="flex items-center justify-between px-4 py-2">
                <span className="text-sm">{perfil?.nombre}</span>
                <span className={`text-xs px-2 py-1 rounded ${getRolColor(perfil?.rol)}`}>
                  {getRolLabel(perfil?.rol)}
                </span>
              </div>
              <button
                onClick={onLogout}
                className="flex items-center space-x-2 w-full px-4 py-2 hover:bg-blue-500 rounded-lg transition-colors"
              >
                <LogOut className="w-5 h-5" />
                <span>Salir</span>
              </button>
            </div>
          </div>
        )}
      </div>
    </nav>
  );
}
