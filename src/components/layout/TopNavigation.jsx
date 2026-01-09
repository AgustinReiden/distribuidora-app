import React, { useState, useRef, useEffect } from 'react';
import { Truck, Menu, X, LogOut, Moon, Sun, BarChart3, ShoppingCart, Users, Package, TrendingUp, UserCog, ChevronDown, Route, ShoppingBag } from 'lucide-react';
import { getRolColor, getRolLabel } from '../../utils/formatters';
import { useTheme } from '../../contexts/ThemeContext';
import { NotificationCenter } from '../../contexts/NotificationContext';

const menuConfig = [
  { id: 'dashboard', icon: BarChart3, label: 'Dashboard', roles: ['admin', 'preventista'] },
  { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'preventista', 'transportista'] },
  { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'preventista'] },
  { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'preventista'] },
  { id: 'compras', icon: ShoppingBag, label: 'Compras', roles: ['admin'] },
  { id: 'recorridos', icon: Route, label: 'Recorridos', roles: ['admin'] },
  { id: 'reportes', icon: TrendingUp, label: 'Reportes', roles: ['admin'] },
  { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
];

export default function TopNavigation({
  vista,
  setVista,
  perfil,
  onLogout
}) {
  const { darkMode, toggleDarkMode } = useTheme();
  const [menuAbierto, setMenuAbierto] = useState(false);
  const [userMenuAbierto, setUserMenuAbierto] = useState(false);
  const menuRef = useRef(null);
  const userMenuRef = useRef(null);

  const menuItems = menuConfig.filter(item => item.roles.includes(perfil?.rol));

  // Cerrar menús al hacer click fuera
  useEffect(() => {
    const handleClickOutside = (event) => {
      if (menuRef.current && !menuRef.current.contains(event.target)) {
        setMenuAbierto(false);
      }
      if (userMenuRef.current && !userMenuRef.current.contains(event.target)) {
        setUserMenuAbierto(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Cerrar menú móvil al cambiar de vista
  const handleVistaChange = (vistaId) => {
    setVista(vistaId);
    setMenuAbierto(false);
  };

  return (
    <>
      {/* Barra de navegación fija */}
      <header className="fixed top-0 left-0 right-0 h-16 bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-sm z-50">
        <div className="h-full max-w-7xl mx-auto px-4 flex items-center justify-between">
          {/* Logo y Menú hamburguesa (móvil) */}
          <div className="flex items-center space-x-4">
            {/* Botón hamburguesa - visible en móvil */}
            <button
              onClick={() => setMenuAbierto(!menuAbierto)}
              className="lg:hidden p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
              aria-label="Abrir menú"
            >
              {menuAbierto ? (
                <X className="w-6 h-6 text-gray-600 dark:text-gray-300" />
              ) : (
                <Menu className="w-6 h-6 text-gray-600 dark:text-gray-300" />
              )}
            </button>

            {/* Logo */}
            <div className="flex items-center space-x-2">
              <div className="p-2 bg-blue-600 rounded-lg">
                <Truck className="w-5 h-5 text-white" />
              </div>
              <span className="font-bold text-lg text-gray-800 dark:text-white hidden sm:block">
                Distribuidora
              </span>
            </div>

            {/* Menú horizontal - visible en desktop */}
            <nav className="hidden lg:flex items-center space-x-1 ml-8">
              {menuItems.map(item => (
                <button
                  key={item.id}
                  onClick={() => handleVistaChange(item.id)}
                  className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-all ${
                    vista === item.id
                      ? 'bg-blue-600 text-white shadow-md'
                      : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700'
                  }`}
                >
                  <item.icon className="w-4 h-4" />
                  <span className="font-medium text-sm">{item.label}</span>
                </button>
              ))}
            </nav>
          </div>

          {/* Lado derecho: notificaciones, tema, usuario */}
          <div className="flex items-center space-x-2 sm:space-x-4">
            {/* Toggle tema */}
            <button
              onClick={toggleDarkMode}
              className="p-2 rounded-lg text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
              aria-label={darkMode ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro'}
            >
              {darkMode ? <Sun className="w-5 h-5" /> : <Moon className="w-5 h-5" />}
            </button>

            {/* Notificaciones */}
            <NotificationCenter />

            {/* Menú de usuario */}
            <div className="relative" ref={userMenuRef}>
              <button
                onClick={() => setUserMenuAbierto(!userMenuAbierto)}
                className="flex items-center space-x-2 p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
              >
                <div className="w-8 h-8 rounded-full bg-blue-100 dark:bg-blue-900 flex items-center justify-center">
                  <span className="text-sm font-semibold text-blue-600 dark:text-blue-400">
                    {perfil?.nombre?.charAt(0)?.toUpperCase() || 'U'}
                  </span>
                </div>
                <span className="hidden sm:block text-sm font-medium text-gray-700 dark:text-gray-300 max-w-24 truncate">
                  {perfil?.nombre?.split(' ')[0] || 'Usuario'}
                </span>
                <ChevronDown className={`w-4 h-4 text-gray-500 transition-transform ${userMenuAbierto ? 'rotate-180' : ''}`} />
              </button>

              {/* Dropdown de usuario */}
              {userMenuAbierto && (
                <div className="absolute right-0 mt-2 w-64 bg-white dark:bg-gray-800 rounded-xl shadow-lg border dark:border-gray-700 py-2 z-50">
                  <div className="px-4 py-3 border-b dark:border-gray-700">
                    <p className="font-medium text-gray-800 dark:text-white truncate">{perfil?.nombre}</p>
                    <p className="text-sm text-gray-500 dark:text-gray-400 truncate">{perfil?.email}</p>
                    <span className={`inline-block mt-2 text-xs px-2 py-1 rounded-full ${getRolColor(perfil?.rol)}`}>
                      {getRolLabel(perfil?.rol)}
                    </span>
                  </div>
                  <button
                    onClick={onLogout}
                    className="w-full flex items-center space-x-3 px-4 py-3 text-red-600 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
                  >
                    <LogOut className="w-5 h-5" />
                    <span>Cerrar sesión</span>
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>
      </header>

      {/* Menú desplegable móvil */}
      <div
        ref={menuRef}
        className={`fixed top-16 left-0 right-0 bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-lg z-40 lg:hidden transition-all duration-300 ease-in-out ${
          menuAbierto
            ? 'opacity-100 translate-y-0'
            : 'opacity-0 -translate-y-4 pointer-events-none'
        }`}
      >
        <nav className="max-w-7xl mx-auto p-4">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            {menuItems.map(item => (
              <button
                key={item.id}
                onClick={() => handleVistaChange(item.id)}
                className={`flex items-center space-x-3 px-4 py-3 rounded-xl transition-all ${
                  vista === item.id
                    ? 'bg-blue-600 text-white shadow-md'
                    : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 bg-gray-50 dark:bg-gray-700/50'
                }`}
              >
                <item.icon className="w-5 h-5" />
                <span className="font-medium">{item.label}</span>
              </button>
            ))}
          </div>
        </nav>
      </div>

      {/* Overlay para cerrar menú móvil */}
      {menuAbierto && (
        <div
          className="fixed inset-0 bg-black bg-opacity-25 z-30 lg:hidden"
          onClick={() => setMenuAbierto(false)}
        />
      )}
    </>
  );
}
