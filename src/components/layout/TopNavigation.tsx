import React, { useState, useRef, useEffect } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import type { LucideIcon } from 'lucide-react';
import {
  Truck, Menu, X, LogOut, Moon, Sun, ChevronDown,
  BarChart3, ShoppingCart, Users, Package, TrendingUp,
  UserCog, Route, ShoppingBag, Building2, Banknote, AlertTriangle, Database, Tag
} from 'lucide-react';
import { getRolColor, getRolLabel } from '../../utils/formatters';
import { useTheme } from '../../contexts/ThemeContext';
import { NotificationCenter } from '../../contexts/NotificationContext';
import type { PerfilDB, RolUsuario } from '../../types';

// =============================================================================
// INTERFACES Y TIPOS
// =============================================================================

export interface TopNavigationProps {
  perfil: PerfilDB | null;
  onLogout: () => void;
}

interface MenuItem {
  id: string;
  icon: LucideIcon;
  label: string;
  roles: RolUsuario[];
}

interface MenuGroup {
  id: string;
  label: string | null;
  icon?: LucideIcon;
  roles?: RolUsuario[];
  items: MenuItem[];
}

// =============================================================================
// CONFIGURACION DEL MENU
// =============================================================================

const menuGroups: MenuGroup[] = [
  {
    id: 'principal',
    label: null, // Items sin grupo (se muestran directo)
    items: [
      { id: 'dashboard', icon: BarChart3, label: 'Dashboard', roles: ['admin', 'preventista'] },
      { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'preventista', 'transportista'] },
    ]
  },
  {
    id: 'comercial',
    label: 'Comercial',
    icon: Users,
    roles: ['admin', 'preventista'],
    items: [
      { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'preventista'] },
      { id: 'recorrido-preventista', icon: Route, label: 'Recorrido Preventista', roles: ['admin'] },
      { id: 'reportes', icon: TrendingUp, label: 'Reportes', roles: ['admin'] },
      { id: 'analytics', icon: Database, label: 'Centro de Analisis', roles: ['admin'] },
    ]
  },
  {
    id: 'inventario',
    label: 'Inventario',
    icon: Package,
    roles: ['admin', 'preventista'],
    items: [
      { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'preventista'] },
      { id: 'compras', icon: ShoppingBag, label: 'Compras', roles: ['admin'] },
      { id: 'proveedores', icon: Building2, label: 'Proveedores', roles: ['admin'] },
      { id: 'precios-mayoristas', icon: Tag, label: 'Precios Mayoristas', roles: ['admin'] },
    ]
  },
  {
    id: 'operaciones',
    label: 'Operaciones',
    icon: Route,
    roles: ['admin'],
    items: [
      { id: 'recorridos', icon: Route, label: 'Recorridos', roles: ['admin'] },
      { id: 'rendiciones', icon: Banknote, label: 'Rendiciones', roles: ['admin'] },
      { id: 'salvedades', icon: AlertTriangle, label: 'Salvedades', roles: ['admin'] },
      { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
    ]
  }
];

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

export default function TopNavigation({
  perfil,
  onLogout
}: TopNavigationProps): React.ReactElement {
  const navigate = useNavigate();
  const location = useLocation();
  const { darkMode, toggleDarkMode } = useTheme();
  const [menuAbierto, setMenuAbierto] = useState<boolean>(false);
  const [userMenuAbierto, setUserMenuAbierto] = useState<boolean>(false);
  const [dropdownAbierto, setDropdownAbierto] = useState<string | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const userMenuRef = useRef<HTMLDivElement>(null);
  const dropdownRefs = useRef<Record<string, HTMLDivElement | null>>({});

  // Obtener la vista actual desde la ruta
  const vista = location.pathname.replace('/', '') || 'dashboard';

  // Filtrar grupos y items por rol
  const getMenuFiltrado = (): MenuGroup[] => {
    const userRol = perfil?.rol;
    if (!userRol) return [];

    return menuGroups.map(group => ({
      ...group,
      items: group.items.filter(item => item.roles.includes(userRol))
    })).filter(group => {
      // Filtrar grupos vacios o sin permiso
      if (group.items.length === 0) return false;
      if (group.roles && !group.roles.some(r => r === userRol)) return false;
      return true;
    });
  };

  const menuFiltrado = getMenuFiltrado();

  // Cerrar menus al hacer click fuera
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent): void => {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
        setMenuAbierto(false);
      }
      if (userMenuRef.current && !userMenuRef.current.contains(event.target as Node)) {
        setUserMenuAbierto(false);
      }
      // Cerrar dropdowns
      const clickedInsideDropdown = Object.values(dropdownRefs.current).some(
        ref => ref && ref.contains(event.target as Node)
      );
      if (!clickedInsideDropdown) {
        setDropdownAbierto(null);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const handleVistaChange = (vistaId: string): void => {
    navigate(`/${vistaId}`);
    setMenuAbierto(false);
    setDropdownAbierto(null);
  };

  const toggleDropdown = (groupId: string): void => {
    setDropdownAbierto(dropdownAbierto === groupId ? null : groupId);
  };

  // Verificar si un grupo tiene la vista activa
  const grupoTieneVistaActiva = (group: MenuGroup): boolean => {
    return group.items.some(item => item.id === vista);
  };

  const setDropdownRef = (groupId: string) => (el: HTMLDivElement | null): void => {
    dropdownRefs.current[groupId] = el;
  };

  return (
    <>
      {/* Barra de navegacion fija */}
      <header className="fixed top-0 left-0 right-0 h-16 bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-sm z-50">
        <div className="h-full max-w-7xl mx-auto px-4 flex items-center justify-between">
          {/* Logo y Menu hamburguesa (movil) */}
          <div className="flex items-center space-x-4">
            {/* Boton hamburguesa - visible en movil */}
            <button
              onClick={() => setMenuAbierto(!menuAbierto)}
              className="lg:hidden p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
              aria-label={menuAbierto ? 'Cerrar menu' : 'Abrir menu'}
              aria-expanded={menuAbierto}
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

            {/* Menu horizontal - visible en desktop */}
            <nav id="main-navigation" className="hidden lg:flex items-center space-x-1 ml-8" aria-label="Navegacion principal">
              {menuFiltrado.map(group => {
                // Items sin grupo (se muestran directo)
                if (!group.label) {
                  return group.items.map(item => {
                    const ItemIcon = item.icon;
                    return (
                      <button
                        key={item.id}
                        onClick={() => handleVistaChange(item.id)}
                        className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-all ${
                          vista === item.id
                            ? 'bg-blue-600 text-white shadow-md'
                            : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700'
                        }`}
                      >
                        <ItemIcon className="w-4 h-4" />
                        <span className="font-medium text-sm">{item.label}</span>
                      </button>
                    );
                  });
                }

                // Grupos con dropdown
                const GroupIcon = group.icon!;
                const isActive = grupoTieneVistaActiva(group);
                const isOpen = dropdownAbierto === group.id;

                return (
                  <div
                    key={group.id}
                    className="relative"
                    ref={setDropdownRef(group.id)}
                  >
                    <button
                      onClick={() => toggleDropdown(group.id)}
                      aria-expanded={isOpen}
                      aria-haspopup="true"
                      className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-all ${
                        isActive
                          ? 'bg-blue-100 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400'
                          : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700'
                      }`}
                    >
                      <GroupIcon className="w-4 h-4" />
                      <span className="font-medium text-sm">{group.label}</span>
                      <ChevronDown className={`w-3 h-3 transition-transform ${isOpen ? 'rotate-180' : ''}`} />
                    </button>

                    {/* Dropdown */}
                    {isOpen && (
                      <div role="menu" className="absolute top-full left-0 mt-1 w-48 bg-white dark:bg-gray-800 rounded-xl shadow-lg border dark:border-gray-700 py-2 z-50">
                        {group.items.map(item => {
                          const ItemIcon = item.icon;
                          return (
                            <button
                              key={item.id}
                              role="menuitem"
                              onClick={() => handleVistaChange(item.id)}
                              className={`w-full flex items-center space-x-3 px-4 py-2.5 transition-colors ${
                                vista === item.id
                                  ? 'bg-blue-50 dark:bg-blue-900/20 text-blue-600 dark:text-blue-400'
                                  : 'text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
                              }`}
                            >
                              <ItemIcon className="w-4 h-4" />
                              <span className="font-medium text-sm">{item.label}</span>
                            </button>
                          );
                        })}
                      </div>
                    )}
                  </div>
                );
              })}
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

            {/* Menu de usuario */}
            <div className="relative" ref={userMenuRef}>
              <button
                onClick={() => setUserMenuAbierto(!userMenuAbierto)}
                aria-expanded={userMenuAbierto}
                aria-haspopup="true"
                aria-label="Menu de usuario"
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
                    <span className={`inline-block mt-2 text-xs px-2 py-1 rounded-full ${getRolColor(perfil?.rol || '')}`}>
                      {getRolLabel(perfil?.rol || '')}
                    </span>
                  </div>
                  <button
                    onClick={onLogout}
                    className="w-full flex items-center space-x-3 px-4 py-3 text-red-600 hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
                  >
                    <LogOut className="w-5 h-5" />
                    <span>Cerrar sesion</span>
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>
      </header>

      {/* Menu desplegable movil */}
      <div
        ref={menuRef}
        className={`fixed top-16 left-0 right-0 bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-lg z-40 lg:hidden transition-all duration-300 ease-in-out ${
          menuAbierto
            ? 'opacity-100 translate-y-0'
            : 'opacity-0 -translate-y-4 pointer-events-none'
        }`}
      >
        <nav className="max-w-7xl mx-auto p-4 space-y-4">
          {menuFiltrado.map(group => {
            const GroupIcon = group.icon;
            return (
              <div key={group.id}>
                {/* Titulo del grupo */}
                {group.label && GroupIcon && (
                  <div className="flex items-center gap-2 px-2 mb-2">
                    <GroupIcon className="w-4 h-4 text-gray-400" />
                    <span className="text-xs font-semibold text-gray-400 uppercase tracking-wider">
                      {group.label}
                    </span>
                  </div>
                )}

                {/* Items del grupo */}
                <div className="grid grid-cols-2 gap-2">
                  {group.items.map(item => {
                    const ItemIcon = item.icon;
                    return (
                      <button
                        key={item.id}
                        onClick={() => handleVistaChange(item.id)}
                        className={`flex items-center space-x-3 px-4 py-3 rounded-xl transition-all ${
                          vista === item.id
                            ? 'bg-blue-600 text-white shadow-md'
                            : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 bg-gray-50 dark:bg-gray-700/50'
                        }`}
                      >
                        <ItemIcon className="w-5 h-5" />
                        <span className="font-medium">{item.label}</span>
                      </button>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </nav>
      </div>

      {/* Overlay para cerrar menu movil */}
      {menuAbierto && (
        <div
          className="fixed inset-0 bg-black bg-opacity-25 z-30 lg:hidden"
          onClick={() => setMenuAbierto(false)}
          aria-hidden="true"
        />
      )}
    </>
  );
}
