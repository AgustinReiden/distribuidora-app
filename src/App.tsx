/**
 * App.tsx
 *
 * Componente principal de la aplicacion.
 * Usa React Router para navegacion URL y Contexts para estado global.
 */
import { useEffect, lazy, Suspense, ReactElement, useState, useMemo, useCallback } from 'react';
import { BrowserRouter, useLocation, useNavigate, Navigate, Routes, Route } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import {
  AuthProvider,
  useAuth,
  useClientes,
  useProductos,
  usePedidos,
  useUsuarios,
  useDashboard,
  useBackup,
  usePagos,
  useMermas,
  useCompras,
  useRecorridos,
  useRendiciones,
  useSalvedades,
  setErrorNotifier
} from './hooks/supabase';
import { ThemeProvider } from './contexts/ThemeContext';
import { NotificationProvider, useNotification } from './contexts/NotificationContext';
import { AppDataProvider, type AppDataContextValue } from './contexts/AppDataContext';
import { useOptimizarRuta } from './hooks/useOptimizarRuta';
import { useOfflineSync } from './hooks/useOfflineSync';
import { useAppState, useAppDerivedState } from './hooks/useAppState';
import { useAppHandlers } from './hooks/useAppHandlers';
import type { FiltrosPedidosState, PerfilDB, PedidoDB, EstadisticasRecorridos, RendicionDBExtended } from './types/hooks';
import type { AppModalsAppState, AppModalsHandlers } from './components/AppModals';

// Componentes base
import LoginScreen from './components/auth/LoginScreen';
import ErrorBoundary from './components/ErrorBoundary';
import TopNavigation from './components/layout/TopNavigation';
import OfflineIndicator from './components/layout/OfflineIndicator';
import AppModals from './components/AppModals';
import PWAPrompt from './components/PWAPrompt';
import SkipLinks from './components/a11y/SkipLinks';

// Vistas con lazy loading
const VistaDashboard = lazy(() => import('./components/vistas/VistaDashboard'));
const VistaPedidos = lazy(() => import('./components/vistas/VistaPedidos'));
const VistaClientes = lazy(() => import('./components/vistas/VistaClientes'));
const VistaProductos = lazy(() => import('./components/vistas/VistaProductos'));
const VistaReportes = lazy(() => import('./components/vistas/VistaReportes'));
const VistaUsuarios = lazy(() => import('./components/vistas/VistaUsuarios'));
const VistaRecorridos = lazy(() => import('./components/vistas/VistaRecorridos'));
const VistaCompras = lazy(() => import('./components/vistas/VistaCompras'));
const VistaProveedores = lazy(() => import('./components/vistas/VistaProveedores'));
const VistaRendiciones = lazy(() => import('./components/vistas/VistaRendiciones'));
const VistaSalvedades = lazy(() => import('./components/vistas/VistaSalvedades'));

// Modales adicionales
import ModalRendicion from './components/modals/ModalRendicion';
import ModalEntregaConSalvedad from './components/modals/ModalEntregaConSalvedad';

function LoadingVista(): ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  );
}

// =============================================================================
// MAIN APP COMPONENT
// =============================================================================

function MainApp(): ReactElement {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const notify = useNotification();
  const location = useLocation();
  const navigate = useNavigate();

  // Obtener vista actual desde la URL
  const vista = location.pathname.replace('/', '') || 'dashboard';

  // Funcion para cambiar vista (mantiene compatibilidad)
  const _setVista = useCallback((newVista: string) => {
    navigate(`/${newVista}`);
  }, [navigate]);

  // Estado de la aplicacion (consolidado)
  const appState = useAppState(perfil);
  const { fechaRecorridos, setFechaRecorridos, modales, guardando, cargandoHistorial, busqueda, paginaActual, setPaginaActual } = appState;

  // Configurar notificador de errores
  useEffect(() => {
    setErrorNotifier((message: string) => notify.error(message));
  }, [notify]);

  // Hooks de datos
  const { clientes, agregarCliente, actualizarCliente, eliminarCliente, loading: loadingClientes } = useClientes();
  const { productos, agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock, actualizarPreciosMasivo, loading: loadingProductos, refetch: refetchProductos } = useProductos();
  const { pedidos, pedidosFiltrados, crearPedido, cambiarEstado, asignarTransportista, eliminarPedido, actualizarNotasPedido, actualizarEstadoPago, actualizarFormaPago, actualizarOrdenEntrega, actualizarItemsPedido, fetchHistorialPedido, fetchPedidosEliminados, filtros, setFiltros, loading: loadingPedidos, refetch: refetchPedidos } = usePedidos();
  const { usuarios, transportistas, actualizarUsuario, loading: loadingUsuarios } = useUsuarios();
  const dashboardUsuarioId = isPreventista && !isAdmin ? user?.id : null;
  const { metricas, reportePreventistas, reporteInicializado, calcularReportePreventistas, loading: loadingMetricas, loadingReporte, refetch: refetchMetricas, filtroPeriodo, cambiarPeriodo } = useDashboard(dashboardUsuarioId);
  const { exportando, descargarJSON, exportarPedidosExcel } = useBackup();
  const { loading: loadingOptimizacion, rutaOptimizada, error: errorOptimizacion, optimizarRuta, limpiarRuta } = useOptimizarRuta();
  const { registrarPago, obtenerResumenCuenta } = usePagos();
  const { mermas, registrarMerma, refetch: refetchMermas } = useMermas();
  const { compras, proveedores, registrarCompra, anularCompra, agregarProveedor, actualizarProveedor, loading: loadingCompras, refetch: refetchCompras, refetchProveedores } = useCompras();
  const { recorridos, loading: loadingRecorridos, fetchRecorridosHoy, fetchRecorridosPorFecha, crearRecorrido } = useRecorridos();
  const { isOnline, pedidosPendientes, mermasPendientes, sincronizando, guardarPedidoOffline, guardarMermaOffline, sincronizarPedidos, sincronizarMermas } = useOfflineSync();
  const { presentarRendicion } = useRendiciones();
  const { registrarSalvedad } = useSalvedades();

  // Estado para modal de rendicion
  const [modalRendicionOpen, setModalRendicionOpen] = useState(false);
  const [rendicionParaModal, setRendicionParaModal] = useState<RendicionDBExtended | null>(null);

  // Estado para modal de entrega con salvedad
  const [modalSalvedadOpen, setModalSalvedadOpen] = useState(false);
  const [pedidoParaSalvedad, setPedidoParaSalvedad] = useState<PedidoDB | null>(null);

  // Datos derivados
  const { categorias, pedidosParaMostrar, totalPaginas, pedidosPaginados } = useAppDerivedState(productos, pedidosFiltrados, busqueda, paginaActual);

  // Handlers (consolidados)
  const handlers = useAppHandlers({
    clientes, productos, pedidos, proveedores,
    agregarCliente, actualizarCliente, eliminarCliente,
    agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock,
    crearPedido: crearPedido as any,
    cambiarEstado,
    asignarTransportista: asignarTransportista as any,
    eliminarPedido: eliminarPedido as any,
    actualizarNotasPedido, actualizarEstadoPago, actualizarFormaPago,
    actualizarOrdenEntrega: actualizarOrdenEntrega as any,
    actualizarItemsPedido: actualizarItemsPedido as any,
    fetchHistorialPedido,
    actualizarUsuario,
    registrarPago: registrarPago as any,
    obtenerResumenCuenta: obtenerResumenCuenta as any,
    registrarMerma: registrarMerma as any,
    registrarCompra: registrarCompra as any,
    anularCompra, agregarProveedor, actualizarProveedor: actualizarProveedor as any,
    crearRecorrido: crearRecorrido as any,
    limpiarRuta,
    refetchProductos, refetchPedidos, refetchMetricas, refetchMermas, refetchCompras, refetchProveedores,
    appState,
    notify: notify as any,
    user, rutaOptimizada: rutaOptimizada as any,
    isOnline,
    guardarPedidoOffline: guardarPedidoOffline as any,
    guardarMermaOffline
  });

  // Cargar recorridos cuando se cambia a la vista
  useEffect(() => {
    if (vista === 'recorridos' && isAdmin) {
      const hoy = new Date().toISOString().split('T')[0];
      if (fechaRecorridos === hoy) fetchRecorridosHoy();
      else fetchRecorridosPorFecha(fechaRecorridos);
    }
  }, [vista, fechaRecorridos, isAdmin, fetchRecorridosHoy, fetchRecorridosPorFecha]);

  // Auto-sincronizar cuando vuelve la conexion
  useEffect(() => {
    const sincronizar = async (): Promise<void> => {
      try {
        if (pedidosPendientes.length > 0) {
          const resultadoPedidos = await sincronizarPedidos(crearPedido as any, descontarStock);
          if (resultadoPedidos.sincronizados > 0) {
            notify.success(`${resultadoPedidos.sincronizados} pedido(s) sincronizado(s)`);
            refetchPedidos();
            refetchProductos();
          }
          if (resultadoPedidos.errores.length > 0) {
            notify.error(`${resultadoPedidos.errores.length} pedido(s) no se pudieron sincronizar`);
          }
        }
        if (mermasPendientes.length > 0) {
          const resultadoMermas = await sincronizarMermas(registrarMerma as any);
          if (resultadoMermas.sincronizados > 0) {
            notify.success(`${resultadoMermas.sincronizados} merma(s) sincronizada(s)`);
            refetchMermas();
          }
        }
      } catch (err: unknown) {
        const errorMessage = err instanceof Error ? err.message : 'Error desconocido';
        notify.error('Error durante la sincronizacion: ' + errorMessage);
      }
    };

    if (isOnline && (pedidosPendientes.length > 0 || mermasPendientes.length > 0)) {
      sincronizar();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOnline]);

  const handleLogout = useCallback(async (): Promise<void> => {
    try { await logout(); } catch { /* error silenciado */ }
  }, [logout]);

  // Handler para sincronizacion manual
  const handleSincronizar = useCallback(async (): Promise<void> => {
    try {
      if (pedidosPendientes.length > 0) {
        const resultadoPedidos = await sincronizarPedidos(crearPedido as any, descontarStock);
        if (resultadoPedidos.sincronizados > 0) {
          notify.success(`${resultadoPedidos.sincronizados} pedido(s) sincronizado(s)`);
          refetchPedidos();
          refetchProductos();
        }
        if (resultadoPedidos.errores.length > 0) {
          notify.error(`${resultadoPedidos.errores.length} pedido(s) no se pudieron sincronizar`);
        }
      }
      if (mermasPendientes.length > 0) {
        const resultadoMermas = await sincronizarMermas(registrarMerma as any);
        if (resultadoMermas.sincronizados > 0) {
          notify.success(`${resultadoMermas.sincronizados} merma(s) sincronizada(s)`);
          refetchMermas();
        }
      }
    } catch (err: unknown) {
      const errorMessage = err instanceof Error ? err.message : 'Error desconocido';
      notify.error('Error durante la sincronizacion: ' + errorMessage);
    }
  }, [crearPedido, descontarStock, mermasPendientes.length, notify, pedidosPendientes.length, refetchMermas, refetchPedidos, refetchProductos, registrarMerma, sincronizarMermas, sincronizarPedidos]);

  // Memoizar el valor del contexto de datos
  const appDataValue = useMemo<AppDataContextValue>(() => ({
    clientes,
    productos,
    pedidos,
    pedidosFiltrados,
    usuarios,
    transportistas,
    proveedores: proveedores as any,
    compras: compras as any,
    mermas: mermas as any,
    recorridos: recorridos as any,
    metricas,
    reportePreventistas,
    reporteInicializado,
    filtros,
    filtroPeriodo,
    categorias,
    loading: {
      clientes: loadingClientes,
      productos: loadingProductos,
      pedidos: loadingPedidos,
      usuarios: loadingUsuarios,
      compras: loadingCompras,
      recorridos: loadingRecorridos,
      metricas: loadingMetricas,
      reporte: loadingReporte,
      optimizacion: loadingOptimizacion
    },
    user,
    perfil,
    isAdmin,
    isPreventista,
    isTransportista,
    isOnline,
    rutaOptimizada,
    errorOptimizacion
  }), [
    clientes, productos, pedidos, pedidosFiltrados, usuarios, transportistas,
    proveedores, compras, mermas, recorridos, metricas, reportePreventistas,
    reporteInicializado, filtros, filtroPeriodo, categorias,
    loadingClientes, loadingProductos, loadingPedidos, loadingUsuarios,
    loadingCompras, loadingRecorridos, loadingMetricas, loadingReporte, loadingOptimizacion,
    user, perfil, isAdmin, isPreventista, isTransportista, isOnline,
    rutaOptimizada, errorOptimizacion
  ]);

  // Determinar la ruta por defecto
  const defaultRoute = (isAdmin || isPreventista) ? '/dashboard' : '/pedidos';

  return (
    <AppDataProvider value={appDataValue}>
      <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
        <SkipLinks />
        <TopNavigation perfil={perfil} onLogout={handleLogout} />

        <main id="main-content" className="pt-20 pb-6 px-4" role="main">
          <div className="max-w-7xl mx-auto">
            <Suspense fallback={<LoadingVista />}>
              <Routes>
                {/* Ruta raíz - redirige según rol */}
                <Route path="/" element={<Navigate to={defaultRoute} replace />} />

                {/* Dashboard */}
                <Route path="/dashboard" element={
                  (isAdmin || isPreventista) ? (
                    <VistaDashboard metricas={metricas} loading={loadingMetricas} filtroPeriodo={filtroPeriodo} onCambiarPeriodo={cambiarPeriodo} onRefetch={refetchMetricas} onDescargarBackup={descargarJSON} exportando={exportando} isAdmin={isAdmin} isPreventista={isPreventista} totalClientes={clientes.length} />
                  ) : <Navigate to="/pedidos" replace />
                } />

                {/* Pedidos */}
                <Route path="/pedidos" element={
                  <VistaPedidos
                    pedidos={pedidos} pedidosParaMostrar={pedidosParaMostrar} pedidosPaginados={pedidosPaginados}
                    paginaActual={paginaActual} totalPaginas={totalPaginas} busqueda={busqueda} filtros={filtros}
                    isAdmin={isAdmin} isPreventista={isPreventista} isTransportista={isTransportista} userId={user?.id ?? ''}
                    clientes={clientes} productos={productos} transportistas={transportistas} loading={loadingPedidos} exportando={exportando}
                    onBusquedaChange={handlers.handleBusquedaChange}
                    onFiltrosChange={(nuevosFiltros: Partial<FiltrosPedidosState>) => handlers.handleFiltrosChange(nuevosFiltros, filtros, setFiltros)}
                    onPageChange={setPaginaActual}
                    onNuevoPedido={() => modales.pedido.setOpen(true)}
                    onOptimizarRuta={() => modales.optimizarRuta.setOpen(true)}
                    onExportarPDF={() => modales.exportarPDF.setOpen(true)}
                    onExportarExcel={() => exportarPedidosExcel(pedidosParaMostrar, { ...filtros, busqueda, fechaDesde: filtros.fechaDesde ?? undefined, fechaHasta: filtros.fechaHasta ?? undefined }, transportistas)}
                    onModalFiltroFecha={() => modales.filtroFecha.setOpen(true)}
                    onVerHistorial={handlers.handleVerHistorial}
                    onEditarPedido={handlers.handleEditarPedido}
                    onMarcarEnPreparacion={handlers.handleMarcarEnPreparacion}
                    onVolverAPendiente={handlers.handleVolverAPendiente}
                    onAsignarTransportista={(pedido) => { appState.setPedidoAsignando(pedido); modales.asignar.setOpen(true); }}
                    onMarcarEntregado={handlers.handleMarcarEntregado}
                    onMarcarEntregadoConSalvedad={(pedido) => { setPedidoParaSalvedad(pedido); setModalSalvedadOpen(true); }}
                    onDesmarcarEntregado={handlers.handleDesmarcarEntregado}
                    onEliminarPedido={(pedido: PedidoDB) => handlers.handleEliminarPedido(pedido.id)}
                    onVerPedidosEliminados={() => modales.pedidosEliminados.setOpen(true)}
                  />
                } />

                {/* Clientes */}
                <Route path="/clientes" element={
                  <VistaClientes
                    clientes={clientes} loading={loadingClientes} isAdmin={isAdmin} isPreventista={isPreventista}
                    onNuevoCliente={() => modales.cliente.setOpen(true)}
                    onEditarCliente={(cliente) => { appState.setClienteEditando(cliente); modales.cliente.setOpen(true); }}
                    onEliminarCliente={handlers.handleEliminarCliente}
                    onVerFichaCliente={handlers.handleVerFichaCliente}
                  />
                } />

                {/* Productos */}
                <Route path="/productos" element={
                  <VistaProductos
                    productos={productos} loading={loadingProductos} isAdmin={isAdmin}
                    onNuevoProducto={() => modales.producto.setOpen(true)}
                    onEditarProducto={(producto) => { appState.setProductoEditando(producto); modales.producto.setOpen(true); }}
                    onEliminarProducto={handlers.handleEliminarProducto}
                    onBajaStock={handlers.handleAbrirMerma}
                    onVerHistorialMermas={handlers.handleVerHistorialMermas}
                    onImportarPrecios={() => modales.importarPrecios.setOpen(true)}
                  />
                } />

                {/* Reportes - solo admin */}
                <Route path="/reportes" element={
                  isAdmin ? (
                    <VistaReportes reportePreventistas={reportePreventistas} reporteInicializado={reporteInicializado} loading={loadingReporte} onCalcularReporte={calcularReportePreventistas} onVerFichaCliente={handlers.handleVerFichaCliente} />
                  ) : <Navigate to="/pedidos" replace />
                } />

                {/* Usuarios - solo admin */}
                <Route path="/usuarios" element={
                  isAdmin ? (
                    <VistaUsuarios usuarios={usuarios} loading={loadingUsuarios} onEditarUsuario={(usuario: PerfilDB) => { appState.setUsuarioEditando(usuario); modales.usuario.setOpen(true); }} />
                  ) : <Navigate to="/pedidos" replace />
                } />

                {/* Recorridos - solo admin */}
                <Route path="/recorridos" element={
                  isAdmin ? (
                    <VistaRecorridos
                      recorridos={recorridos} loading={loadingRecorridos} fechaSeleccionada={fechaRecorridos} estadisticas={appState.estadisticasRecorridos as EstadisticasRecorridos}
                      onRefresh={async () => { const hoy = new Date().toISOString().split('T')[0]; if (fechaRecorridos === hoy) await fetchRecorridosHoy(); else await fetchRecorridosPorFecha(fechaRecorridos); }}
                      onFechaChange={async (fecha: string) => { setFechaRecorridos(fecha); const hoy = new Date().toISOString().split('T')[0]; if (fecha === hoy) await fetchRecorridosHoy(); else await fetchRecorridosPorFecha(fecha); }}
                    />
                  ) : <Navigate to="/pedidos" replace />
                } />

                {/* Compras - solo admin */}
                <Route path="/compras" element={
                  isAdmin ? (
                    <VistaCompras compras={compras as any} proveedores={proveedores as any} loading={loadingCompras} isAdmin={isAdmin} onNuevaCompra={handlers.handleNuevaCompra} onVerDetalle={handlers.handleVerDetalleCompra as any} onAnularCompra={handlers.handleAnularCompra} />
                  ) : <Navigate to="/pedidos" replace />
                } />

                {/* Proveedores - solo admin */}
                <Route path="/proveedores" element={
                  isAdmin ? (
                    <VistaProveedores proveedores={proveedores} compras={compras} loading={loadingCompras} isAdmin={isAdmin} onNuevoProveedor={handlers.handleNuevoProveedor} onEditarProveedor={handlers.handleEditarProveedor} onEliminarProveedor={handlers.handleEliminarProveedor} onToggleActivo={handlers.handleToggleActivoProveedor} />
                  ) : <Navigate to="/pedidos" replace />
                } />

                {/* Rendiciones - solo admin */}
                <Route path="/rendiciones" element={
                  isAdmin ? <VistaRendiciones /> : <Navigate to="/pedidos" replace />
                } />

                {/* Salvedades - solo admin */}
                <Route path="/salvedades" element={
                  isAdmin ? <VistaSalvedades /> : <Navigate to="/pedidos" replace />
                } />

                {/* Fallback */}
                <Route path="*" element={<Navigate to={defaultRoute} replace />} />
              </Routes>
            </Suspense>
          </div>
        </main>

        {/* Modales */}
        <AppModals
          appState={{ ...appState, filtros, setFiltros } as unknown as AppModalsAppState}
          handlers={handlers as unknown as AppModalsHandlers}
          clientes={clientes} productos={productos} pedidos={pedidos} usuarios={usuarios}
          transportistas={transportistas} proveedores={proveedores as any} mermas={mermas as any} categorias={categorias}
          fetchPedidosEliminados={fetchPedidosEliminados as any} actualizarItemsPedido={actualizarItemsPedido as any} actualizarPreciosMasivo={actualizarPreciosMasivo} optimizarRuta={optimizarRuta as any}
          guardando={guardando} cargandoHistorial={cargandoHistorial} loadingOptimizacion={loadingOptimizacion} rutaOptimizada={rutaOptimizada as any} errorOptimizacion={errorOptimizacion}
          user={user} isAdmin={isAdmin} isPreventista={isPreventista} isOnline={isOnline}
        />

        {/* Indicador de estado offline */}
        <OfflineIndicator isOnline={isOnline} pedidosPendientes={pedidosPendientes as any} mermasPendientes={mermasPendientes as any} sincronizando={sincronizando} onSincronizar={handleSincronizar} clientes={clientes as any} />

        {/* PWA Prompt */}
        <PWAPrompt />

        {/* Modal de Rendicion */}
        {modalRendicionOpen && rendicionParaModal && (
          <ModalRendicion
            rendicion={rendicionParaModal}
            onPresentar={async (data) => {
              const result = await presentarRendicion(data);
              if (result.success) {
                setModalRendicionOpen(false);
                setRendicionParaModal(null);
                notify.success('Rendicion presentada correctamente');
              }
              return result;
            }}
            onClose={() => {
              setModalRendicionOpen(false);
              setRendicionParaModal(null);
            }}
          />
        )}

        {/* Modal de Entrega con Salvedad */}
        {modalSalvedadOpen && pedidoParaSalvedad && (
          <ModalEntregaConSalvedad
            pedido={pedidoParaSalvedad}
            onSave={async (salvedades) => {
              const results = await Promise.all(
                salvedades.map(s => registrarSalvedad(s))
              );
              return results;
            }}
            onMarcarEntregado={async () => {
              await cambiarEstado(pedidoParaSalvedad.id, 'entregado');
              await refetchPedidos();
              refetchMetricas();
              notify.success(`Pedido #${pedidoParaSalvedad.id} entregado con salvedades registradas`, { persist: true });
            }}
            onClose={() => {
              setModalSalvedadOpen(false);
              setPedidoParaSalvedad(null);
            }}
          />
        )}
      </div>
    </AppDataProvider>
  );
}

// =============================================================================
// APP CONTENT (Authentication Check)
// =============================================================================

function AppContent(): ReactElement {
  const { user, loading } = useAuth();
  if (loading) {
    return (
      <div className="min-h-screen bg-gray-100 dark:bg-gray-900 flex items-center justify-center transition-colors">
        <Loader2 className="w-8 h-8 animate-spin text-blue-600" aria-label="Cargando" />
      </div>
    );
  }
  return user ? <MainApp /> : <LoginScreen />;
}

// =============================================================================
// ROOT APP
// =============================================================================

export default function App(): ReactElement {
  return (
    <ErrorBoundary>
      <BrowserRouter>
        <ThemeProvider>
          <AuthProvider>
            <NotificationProvider>
              <AppContent />
            </NotificationProvider>
          </AuthProvider>
        </ThemeProvider>
      </BrowserRouter>
    </ErrorBoundary>
  );
}
