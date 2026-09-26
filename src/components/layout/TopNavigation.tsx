import React, { useState, useRef, useEffect, useId } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import type { LucideIcon } from 'lucide-react';
import {
  Truck, Menu, X, LogOut, Moon, Sun, ChevronDown,
  BarChart3, ShoppingCart, Users, Package, TrendingUp,
  UserCog,
  Settings, Route, ShoppingBag, Building2, Banknote, AlertTriangle, Database, Percent, ArrowRightLeft, Gift, Send, MapPin, Clock, Target, ClipboardCheck, CalendarClock
} from 'lucide-react';
import { getRolLabel } from '../../utils/formatters';
import { useTheme } from '../../contexts/ThemeContext';
import { useAuthData } from '../../contexts/AuthDataContext';
import DbNotificationBell from './DbNotificationBell';
import SucursalSelector from './SucursalSelector';
import VincularTelegramButton from '../perfil/VincularTelegramButton';
import { BUILD_ACTUAL } from '../../hooks/useActualizacionDisponible';
import { Button } from '../ui/Button';
import { Badge } from '../ui/Badge';
import { toneDeRol } from '../../lib/estadoTones';
import type { PerfilDB, RolUsuario } from '../../types';

// =============================================================================
// INTERFACES Y TIPOS
// =============================================================================

export interface TopNavigationProps {
  perfil: PerfilDB | null;
  onLogout: () => void | Promise<void>;
}

interface MenuItem {
  id: string;
  icon: LucideIcon;
  label: string;
  roles: RolUsuario[];
  hidden?: boolean;
  /**
   * La <Route> de este id en App.tsx NO tiene gate: la abre cualquier rol. Por
   * eso se filtra por la union de roles efectivos (el rol extra suma) y no por
   * el rol primario como el resto (#731).
   */
  sinGate?: true;
}

interface MenuGroup {
  id: string;
  label: string | null;
  icon?: LucideIcon;
  /**
   * Union de los roles de sus items. El filtro no la usa: un grupo se ve si le
   * queda algun item visible, asi que un item nuevo no puede esconder su grupo
   * entero por olvidarse de sumar su rol aca.
   */
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
      { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'encargado', 'preventista', 'transportista', 'deposito'], sinGate: true },
      // El admin no la usa: la suya va al final de Operaciones (#799), y eso le
      // deja lugar a la barra completa desde xl.
      { id: 'mis-entregas', icon: ClipboardCheck, label: 'Mis entregas', roles: ['encargado', 'preventista'] },
    ]
  },
  {
    id: 'comercial',
    label: 'Comercial',
    icon: Users,
    roles: ['admin', 'encargado', 'preventista'],
    items: [
      { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'encargado', 'preventista'], sinGate: true },
      { id: 'recorrido-preventista', icon: Route, label: 'Recorrido Preventista', roles: ['admin'], hidden: true },
      { id: 'reportes', icon: TrendingUp, label: 'Reportes', roles: ['admin'] },
      { id: 'reportes-gerenciales', icon: BarChart3, label: 'Reportes Gerenciales', roles: ['admin'] },
      // La pantalla es un boton que baja el Excel para Power BI: el label dice eso.
      { id: 'analytics', icon: Database, label: 'Exportar a Power BI', roles: ['admin'] },
      { id: 'comisiones', icon: Percent, label: 'Comisiones', roles: ['admin'] },
      { id: 'metas', icon: Target, label: 'Objetivos', roles: ['admin'] },
    ]
  },
  {
    id: 'inventario',
    label: 'Inventario',
    icon: Package,
    roles: ['admin', 'encargado', 'preventista', 'deposito'],
    items: [
      { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'encargado', 'preventista', 'deposito'], sinGate: true },
      { id: 'compras', icon: ShoppingBag, label: 'Compras', roles: ['admin', 'encargado'] },
      { id: 'vencimientos', icon: CalendarClock, label: 'Vencimientos', roles: ['admin', 'encargado', 'deposito'] },
      { id: 'proveedores', icon: Building2, label: 'Proveedores', roles: ['admin'] },
      // Condiciones Mayoristas salio de aca: ahora es una pestaña dentro de Productos.
      { id: 'promociones', icon: Gift, label: 'Promociones', roles: ['admin'] },
      { id: 'transferencias', icon: ArrowRightLeft, label: 'Mov. Sucursales', roles: ['admin', 'encargado'] },
    ]
  },
  {
    id: 'operaciones',
    label: 'Operaciones',
    icon: Route,
    roles: ['admin', 'encargado'],
    items: [
      { id: 'recorridos', icon: Route, label: 'Recorridos', roles: ['admin', 'encargado'] },
      { id: 'rendiciones', icon: Banknote, label: 'Rendiciones', roles: ['admin', 'encargado'] },
      { id: 'salvedades', icon: AlertTriangle, label: 'Salvedades', roles: ['admin', 'encargado'] },
      { id: 'geolocalizacion', icon: MapPin, label: 'Geolocalización', roles: ['admin'] },
      { id: 'horarios-clientes', icon: Clock, label: 'Horarios a revisar', roles: ['admin', 'encargado'] },
      // Mismo id y misma ruta que el de la barra, con roles disjuntos: a cada
      // rol primario le toca uno solo, y las keys no chocan porque cada lista
      // de items se renderiza aparte.
      { id: 'mis-entregas', icon: ClipboardCheck, label: 'Mis entregas', roles: ['admin'] },
    ]
  }
];

// Administracion no es un grupo de la barra: vive en el menu del usuario
// (#713). Las tres <Route> tienen gate, asi que se filtran con la misma regla
// que el resto: por el rol primario.
const itemsAdministracion: MenuItem[] = [
  { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
  { id: 'configuracion', icon: Settings, label: 'Configuración', roles: ['admin', 'encargado'] },
  { id: 'bot-telegram', icon: Send, label: 'Bot Telegram', roles: ['admin'] },
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
  const { rolesEfectivos } = useAuthData();
  const [menuAbierto, setMenuAbierto] = useState<boolean>(false);
  const [userMenuAbierto, setUserMenuAbierto] = useState<boolean>(false);
  const [dropdownAbierto, setDropdownAbierto] = useState<string | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const hamburguesaRef = useRef<HTMLButtonElement>(null);
  const userMenuRef = useRef<HTMLDivElement>(null);
  const dropdownRefs = useRef<Record<string, HTMLDivElement | null>>({});
  const idTituloAdministracion = useId();

  // Obtener la vista actual desde la ruta
  const vista = location.pathname.replace('/', '') || 'dashboard';

  // Filtrar items por rol.
  //
  // Usa los roles EFECTIVOS (rol de la sucursal activa + capacidades extra de
  // la mig 155), no `perfil.rol`: el rol global ignoraba el rol por sucursal.
  //
  // Pero no la union a secas: las <Route> de App.tsx calculan isAdmin /
  // isPreventista / isEncargado sobre el rol PRIMARIO (el primero de
  // rolesEfectivos) y solo suman los extras en isTransportista. Un item con
  // gate se ofrece si lo habilita el rol primario (o el transportista, que si
  // suma); ofrecer lo que el router rebota es un click que termina en /pedidos
  // sin explicacion (#731). Las rutas `sinGate` las abre cualquiera, y ahi el
  // rol extra si suma: el transportista que tambien vende ve Clientes.
  const rolPrimario = rolesEfectivos[0];
  const tieneTransportista = rolesEfectivos.includes('transportista');
  const puedeVer = (item: MenuItem): boolean => {
    if (item.hidden) return false;
    if (item.sinGate) return item.roles.some(r => rolesEfectivos.includes(r));
    return item.roles.includes(rolPrimario) || (item.roles.includes('transportista') && tieneTransportista);
  };

  const getMenuFiltrado = (): MenuGroup[] => {
    if (rolesEfectivos.length === 0) return [];

    // Un grupo se ve si le queda algun item visible (ver MenuGroup.roles).
    return menuGroups.map(group => ({
      ...group,
      items: group.items.filter(puedeVer)
    })).filter(group => group.items.length > 0);
  };

  const menuFiltrado = getMenuFiltrado();
  const administracionVisible = rolesEfectivos.length === 0 ? [] : itemsAdministracion.filter(puedeVer);

  // Cerrar menus al hacer click fuera
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent): void => {
      // La hamburguesa vive en el header, fuera de menuRef: si su mousedown
      // cerrara el menu, el onClick del mismo toque lo volveria a abrir (#730).
      // Ese boton se alterna solo con su onClick.
      const enHamburguesa = hamburguesaRef.current?.contains(event.target as Node) ?? false;
      if (menuRef.current && !menuRef.current.contains(event.target as Node) && !enHamburguesa) {
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

  const handleAdministracion = (vistaId: string): void => {
    setUserMenuAbierto(false);
    handleVistaChange(vistaId);
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
        {/* La barra completa aparece desde xl (1280 px, #799). Con `lg` la del
            admin desbordaba el header (#713); desde que "Mis entregas" del
            admin vive en Operaciones, entra en xl con la compactacion de abajo,
            que rige solo entre xl y 2xl: botones de la barra con `px-2`, lado
            derecho con `space-x-2`, el logo sin los 16 px de margen y el
            nombre del avatar cortado en 64 px. Desde 2xl todo vuelve al aire
            de siempre. Debajo de xl manda la hamburguesa. */}
        <div className="h-full max-w-7xl xl:max-w-screen-2xl mx-auto px-4 flex items-center justify-between">
          {/* Logo, hamburguesa y barra.
              `main-navigation` es el destino del skip link "Ir a la navegacion"
              (SkipLinks.tsx). Va en este contenedor y no en el <nav> de la
              barra porque el <nav> esta oculto debajo de xl: desde aca el
              siguiente Tab cae en la hamburguesa o en la barra, segun el ancho.
              `gap-4` y no `space-x-4`: el margen de `space-x` lo ponia el
              hermano anterior aunque estuviera oculto, y con la hamburguesa
              en `display: none` el logo arrancaba 16 px corrido. Entre xl y 2xl
              esos 16 px son parte de la compactacion; desde 2xl el `2xl:ml-4`
              del logo los repone y la barra queda donde estuvo siempre. */}
          <div id="main-navigation" className="flex items-center gap-4">
            {/* Boton hamburguesa - visible debajo de xl */}
            <Button
              ref={hamburguesaRef}
              variant="ghost"
              size="icon"
              onClick={() => setMenuAbierto(!menuAbierto)}
              className="xl:hidden"
              aria-label={menuAbierto ? 'Cerrar menu' : 'Abrir menu'}
              aria-expanded={menuAbierto}
            >
              {menuAbierto ? (
                <X className="w-6 h-6 text-gray-600 dark:text-gray-300" />
              ) : (
                <Menu className="w-6 h-6 text-gray-600 dark:text-gray-300" />
              )}
            </Button>

            {/* Logo */}
            <div className="flex items-center space-x-2 2xl:ml-4">
              <div className="p-2 bg-blue-600 rounded-lg">
                <Truck className="w-5 h-5 text-white" />
              </div>
              <span className="font-bold text-lg text-gray-800 dark:text-white hidden sm:block">
                Distribuidora
              </span>
            </div>

            {/* Menu horizontal - visible desde xl. Sin `ml-8`: con `space-x-4`
                en el padre nunca rigio (el margen de `space-x` le ganaba), y
                con `gap-4` sumaria 32 px que la barra no tiene. Los botones de
                primer nivel van con `px-2` hasta 2xl. Medido en la galeria: sin
                compactar (como desde 2xl) el admin pide 1300 px; compactada, la
                mas ancha es la del encargado ("Mis entregas" suelta y ademas
                Operaciones), con 1223 px y 1246 con un nombre que llena el
                avatar; la del admin, 1221 y 1234. En una ventana de 1280 con
                barra de scroll clasica quedan ~1263. */}
            <nav className="hidden xl:flex items-center space-x-1" aria-label="Navegacion principal">
              {menuFiltrado.map(group => {
                // Items sin grupo (se muestran directo)
                if (!group.label) {
                  return group.items.map(item => {
                    const ItemIcon = item.icon;
                    return (
                      <button
                        key={item.id}
                        onClick={() => handleVistaChange(item.id)}
                        className={`flex items-center space-x-2 px-2 2xl:px-3 py-2 rounded-lg transition-colors ${
                          vista === item.id
                            ? 'bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-200 font-semibold'
                            : 'text-gray-600 dark:text-gray-300 font-medium hover:bg-gray-100 dark:hover:bg-gray-700/60'
                        }`}
                      >
                        <ItemIcon className={`w-4 h-4 ${vista === item.id ? 'text-blue-600 dark:text-blue-300' : ''}`} />
                        <span className="text-sm">{item.label}</span>
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
                      className={`flex items-center space-x-2 px-2 2xl:px-3 py-2 rounded-lg transition-colors ${
                        isActive
                          ? 'bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-200 font-semibold'
                          : 'text-gray-600 dark:text-gray-300 font-medium hover:bg-gray-100 dark:hover:bg-gray-700/60'
                      }`}
                    >
                      <GroupIcon className={`w-4 h-4 ${isActive ? 'text-blue-600 dark:text-blue-300' : ''}`} />
                      <span className="text-sm">{group.label}</span>
                      <ChevronDown className={`w-3 h-3 transition-transform ${isOpen ? 'rotate-180' : ''} ${isActive ? 'text-blue-600 dark:text-blue-300' : ''}`} />
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
                              className={`w-full flex items-center space-x-3 px-4 py-2.5 transition-colors border-l-2 ${
                                vista === item.id
                                  ? 'bg-blue-50/70 dark:bg-blue-900/20 text-blue-700 dark:text-blue-200 border-blue-500'
                                  : 'text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 border-transparent'
                              }`}
                            >
                              <ItemIcon className={`w-4 h-4 ${vista === item.id ? 'text-blue-600 dark:text-blue-300' : ''}`} />
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

          {/* Lado derecho: notificaciones, tema, usuario. Entre xl y 2xl, con
              la barra al lado, va apretado como en el celular (#799). */}
          <div className="flex items-center space-x-2 sm:space-x-4 xl:space-x-2 2xl:space-x-4">
            {/* Toggle tema */}
            <Button
              variant="ghost"
              size="icon"
              onClick={toggleDarkMode}
              aria-label={darkMode ? 'Cambiar a modo claro' : 'Cambiar a modo oscuro'}
            >
              {darkMode ? <Sun className="w-5 h-5" /> : <Moon className="w-5 h-5" />}
            </Button>

            {/* Notificaciones (persistentes, DB) */}
            <DbNotificationBell />

            {/* Sucursal */}
            <SucursalSelector />

            {/* Menu de usuario */}
            <div className="relative" ref={userMenuRef}>
              <Button
                variant="ghost"
                onClick={() => setUserMenuAbierto(!userMenuAbierto)}
                aria-expanded={userMenuAbierto}
                aria-haspopup="true"
                aria-label="Menu de usuario"
                className="h-auto p-2"
              >
                <div className="w-8 h-8 rounded-full bg-blue-100 dark:bg-blue-900 flex items-center justify-center">
                  <span className="text-sm font-semibold text-blue-600 dark:text-blue-400">
                    {perfil?.nombre?.charAt(0)?.toUpperCase() || 'U'}
                  </span>
                </div>
                {/* Entre xl y 2xl el nombre se corta antes (64 px y no 96): con
                    un nombre largo la barra del encargado, la mas ancha en xl
                    (tiene "Mis entregas" y Operaciones), no entraba en una
                    ventana de 1280 con barra de scroll clasica (#799). */}
                <span className="hidden sm:block text-sm font-medium text-gray-700 dark:text-gray-300 max-w-24 xl:max-w-16 2xl:max-w-24 truncate">
                  {perfil?.nombre?.split(' ')[0] || 'Usuario'}
                </span>
                <ChevronDown className={`w-4 h-4 text-gray-500 transition-transform ${userMenuAbierto ? 'rotate-180' : ''}`} />
              </Button>

              {/* Dropdown de usuario. Con "Administración" (#713) el del admin
                  mide unos 400 px y cuelga de un header `fixed`: sin tope de
                  alto ni scroll propio, en una pantalla baja (celular apaisado,
                  zoom al 200 %) "Cerrar sesion" queda debajo de la ventana y no
                  hay forma de llegar. 5rem = header + mt-2 + aire.
                  El scroll recorta tambien a los costados, y los botones miden
                  lo mismo que el desplegable: con el anillo de foco por fuera
                  (`ring-offset-2`) se perdian los lados. Por eso los tres van
                  con `focus-visible:ring-inset focus-visible:ring-offset-0`, y
                  el `px-1.5` del contenedor deja lugar al contorno de 3 px + 2
                  de separacion que pone high-contrast.css en :focus. */}
              {userMenuAbierto && (
                <div className="absolute right-0 mt-2 w-64 max-h-[calc(100dvh-5rem)] overflow-y-auto overscroll-contain bg-white dark:bg-gray-800 rounded-xl shadow-lg border dark:border-gray-700 py-2 px-1.5 z-50">
                  <div className="px-4 py-3 border-b dark:border-gray-700">
                    <p className="font-medium text-gray-800 dark:text-white truncate">{perfil?.nombre}</p>
                    <p className="text-sm text-gray-500 dark:text-gray-400 truncate">{perfil?.email}</p>
                    <Badge tone={toneDeRol(perfil?.rol || '')} className="mt-2 py-1 font-normal">
                      {getRolLabel(perfil?.rol || '')}
                    </Badge>
                  </div>
                  {/* Vincular Telegram (Phase 1 MVP del bot) */}
                  <VincularTelegramButton
                    className="w-full flex items-center space-x-3 px-4 py-3 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors focus-visible:ring-inset focus-visible:ring-offset-0"
                  />
                  {/* Administracion (#713): no es un grupo de la barra. */}
                  {administracionVisible.length > 0 && (
                    <div
                      role="group"
                      aria-labelledby={idTituloAdministracion}
                      className="py-1 border-y dark:border-gray-700"
                    >
                      <p
                        id={idTituloAdministracion}
                        className="px-4 pt-2 pb-1 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                      >
                        Administración
                      </p>
                      {administracionVisible.map(item => {
                        const ItemIcon = item.icon;
                        const activo = vista === item.id;
                        return (
                          <Button
                            key={item.id}
                            variant="ghost"
                            onClick={() => handleAdministracion(item.id)}
                            aria-current={activo ? 'page' : undefined}
                            className={`w-full h-auto justify-start gap-3 px-4 py-2.5 focus-visible:ring-inset focus-visible:ring-offset-0 ${
                              activo
                                ? 'bg-blue-50/70 dark:bg-blue-900/20 text-blue-700 dark:text-blue-200'
                                : 'text-gray-700 dark:text-gray-200'
                            }`}
                          >
                            <ItemIcon className="w-5 h-5" />
                            <span>{item.label}</span>
                          </Button>
                        );
                      })}
                    </div>
                  )}
                  <Button
                    variant="ghost"
                    onClick={onLogout}
                    className="w-full h-auto justify-start gap-3 px-4 py-3 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20 focus-visible:ring-inset focus-visible:ring-offset-0"
                  >
                    <LogOut className="w-5 h-5" />
                    <span>Cerrar sesion</span>
                  </Button>
                  {/* Sin esto, cuando alguien reporta "me sale distinto" no hay
                      forma de saber que build esta corriendo. */}
                  <p className="px-4 pt-2 border-t dark:border-gray-700 text-[11px] text-gray-400 dark:text-gray-500">
                    Version {BUILD_ACTUAL}
                  </p>
                </div>
              )}
            </div>
          </div>
        </div>
      </header>

      {/* Menu desplegable (debajo de xl). Lo usan tambien las notebooks de
          menos de 1280 px, y el del admin mide unos 800 px: con tope de alto y
          scroll propio no se corta en una pantalla baja. `invisible` cerrado lo
          saca del orden de Tab y del arbol de accesibilidad; la opacidad sola
          no. */}
      <div
        ref={menuRef}
        className={`fixed top-16 left-0 right-0 max-h-[calc(100dvh-4rem)] overflow-y-auto overscroll-contain bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-lg z-40 xl:hidden transition-all duration-300 ease-in-out ${
          menuAbierto
            ? 'opacity-100 translate-y-0'
            : 'opacity-0 -translate-y-4 pointer-events-none invisible'
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
          className="fixed inset-0 bg-black bg-opacity-25 z-30 xl:hidden"
          onClick={() => setMenuAbierto(false)}
          aria-hidden="true"
        />
      )}
    </>
  );
}
