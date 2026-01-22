import { useEffect, lazy, Suspense, ReactElement } from 'react';
import { Loader2 } from 'lucide-react';
import { AuthProvider, useAuth, useClientes, useProductos, usePedidos, useUsuarios, useDashboard, useBackup, usePagos, useMermas, useCompras, useRecorridos, setErrorNotifier } from './hooks/supabase';
import { ThemeProvider } from './contexts/ThemeContext';
import { NotificationProvider, useNotification } from './contexts/NotificationContext';
import { useOptimizarRuta } from './hooks/useOptimizarRuta';
import { useOfflineSync } from './hooks/useOfflineSync';
import { useAppState, useAppDerivedState } from './hooks/useAppState';
import { useAppHandlers } from './hooks/useAppHandlers';
import type { FiltrosPedidosState, PerfilDB, PedidoDB, EstadisticasRecorridos } from './types/hooks';
import type { AppModalsProps, AppModalsAppState, AppModalsHandlers } from './components/AppModals';

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

function LoadingVista(): ReactElement {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  );
}

function MainApp(): ReactElement {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const notify = useNotification();

  // Estado de la aplicacion (consolidado)
  const appState = useAppState(perfil);
  const { vista, setVista, fechaRecorridos, setFechaRecorridos, modales, guardando, cargandoHistorial, busqueda, paginaActual, setPaginaActual } = appState;

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

  // Datos derivados
  const { categorias, pedidosParaMostrar, totalPaginas, pedidosPaginados } = useAppDerivedState(productos, pedidosFiltrados, busqueda, paginaActual);

  // Handlers (consolidados) - using type assertions for hook compatibility
  /* eslint-disable @typescript-eslint/no-explicit-any */
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
  /* eslint-enable @typescript-eslint/no-explicit-any */

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
          const resultadoMermas = await sincronizarMermas(registrarMerma);
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

  const handleLogout = async (): Promise<void> => {
    try { await logout(); } catch { /* error silenciado */ }
  };

  // Handler para sincronizacion manual
  const handleSincronizar = async (): Promise<void> => {
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
        const resultadoMermas = await sincronizarMermas(registrarMerma);
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

  return (
    <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
      <SkipLinks />
      <TopNavigation vista={vista} setVista={setVista} perfil={perfil} onLogout={handleLogout} />

      <main id="main-content" className="pt-20 pb-6 px-4" role="main">
        <div className="max-w-7xl mx-auto">
          <Suspense fallback={<LoadingVista />}>
            {vista === 'dashboard' && (isAdmin || isPreventista) && (
              <VistaDashboard metricas={metricas} loading={loadingMetricas} filtroPeriodo={filtroPeriodo} onCambiarPeriodo={cambiarPeriodo} onRefetch={refetchMetricas} onDescargarBackup={descargarJSON} exportando={exportando} isAdmin={isAdmin} isPreventista={isPreventista} totalClientes={clientes.length} />
            )}

            {vista === 'pedidos' && (
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
                onAsignarTransportista={(pedido) => { appState.setPedidoAsignando(pedido); modales.asignar.setOpen(true); }}
                onMarcarEntregado={handlers.handleMarcarEntregado}
                onDesmarcarEntregado={handlers.handleDesmarcarEntregado}
                onEliminarPedido={(pedido: PedidoDB) => handlers.handleEliminarPedido(pedido.id)}
                onVerPedidosEliminados={() => modales.pedidosEliminados.setOpen(true)}
              />
            )}

            {vista === 'clientes' && (
              <VistaClientes
                clientes={clientes} loading={loadingClientes} isAdmin={isAdmin} isPreventista={isPreventista}
                onNuevoCliente={() => modales.cliente.setOpen(true)}
                onEditarCliente={(cliente) => { appState.setClienteEditando(cliente); modales.cliente.setOpen(true); }}
                onEliminarCliente={handlers.handleEliminarCliente}
                onVerFichaCliente={handlers.handleVerFichaCliente}
              />
            )}

            {vista === 'productos' && (
              <VistaProductos
                productos={productos} loading={loadingProductos} isAdmin={isAdmin}
                onNuevoProducto={() => modales.producto.setOpen(true)}
                onEditarProducto={(producto) => { appState.setProductoEditando(producto); modales.producto.setOpen(true); }}
                onEliminarProducto={handlers.handleEliminarProducto}
                onBajaStock={handlers.handleAbrirMerma}
                onVerHistorialMermas={handlers.handleVerHistorialMermas}
                onImportarPrecios={() => modales.importarPrecios.setOpen(true)}
              />
            )}

            {vista === 'reportes' && isAdmin && (
              <VistaReportes reportePreventistas={reportePreventistas} reporteInicializado={reporteInicializado} loading={loadingReporte} onCalcularReporte={calcularReportePreventistas} onVerFichaCliente={handlers.handleVerFichaCliente} />
            )}

            {vista === 'usuarios' && isAdmin && (
              <VistaUsuarios usuarios={usuarios} loading={loadingUsuarios} onEditarUsuario={(usuario: PerfilDB) => { appState.setUsuarioEditando(usuario); modales.usuario.setOpen(true); }} />
            )}

            {vista === 'recorridos' && isAdmin && (
              <VistaRecorridos
                recorridos={recorridos} loading={loadingRecorridos} fechaSeleccionada={fechaRecorridos} estadisticas={appState.estadisticasRecorridos as EstadisticasRecorridos}
                onRefresh={async () => { const hoy = new Date().toISOString().split('T')[0]; if (fechaRecorridos === hoy) await fetchRecorridosHoy(); else await fetchRecorridosPorFecha(fechaRecorridos); }}
                onFechaChange={async (fecha: string) => { setFechaRecorridos(fecha); const hoy = new Date().toISOString().split('T')[0]; if (fecha === hoy) await fetchRecorridosHoy(); else await fetchRecorridosPorFecha(fecha); }}
              />
            )}

            {vista === 'compras' && isAdmin && (
              /* eslint-disable @typescript-eslint/no-explicit-any */
              <VistaCompras compras={compras as any} proveedores={proveedores as any} loading={loadingCompras} isAdmin={isAdmin} onNuevaCompra={handlers.handleNuevaCompra} onVerDetalle={handlers.handleVerDetalleCompra as any} onAnularCompra={handlers.handleAnularCompra} />
              /* eslint-enable @typescript-eslint/no-explicit-any */
            )}

            {vista === 'proveedores' && isAdmin && (
              <VistaProveedores proveedores={proveedores} compras={compras} loading={loadingCompras} isAdmin={isAdmin} onNuevoProveedor={handlers.handleNuevoProveedor} onEditarProveedor={handlers.handleEditarProveedor} onEliminarProveedor={handlers.handleEliminarProveedor} onToggleActivo={handlers.handleToggleActivoProveedor} />
            )}
          </Suspense>
        </div>
      </main>

      {/* Modales */}
      {/* eslint-disable @typescript-eslint/no-explicit-any */}
      <AppModals
        appState={{ ...appState, filtros, setFiltros } as unknown as AppModalsAppState}
        handlers={handlers as unknown as AppModalsHandlers}
        clientes={clientes} productos={productos} pedidos={pedidos} usuarios={usuarios}
        transportistas={transportistas} proveedores={proveedores as any} mermas={mermas as any} categorias={categorias}
        fetchPedidosEliminados={fetchPedidosEliminados as any} actualizarItemsPedido={actualizarItemsPedido as any} actualizarPreciosMasivo={actualizarPreciosMasivo} optimizarRuta={optimizarRuta as any}
        guardando={guardando} cargandoHistorial={cargandoHistorial} loadingOptimizacion={loadingOptimizacion} rutaOptimizada={rutaOptimizada as any} errorOptimizacion={errorOptimizacion}
        user={user} isAdmin={isAdmin} isPreventista={isPreventista} isOnline={isOnline}
      />
      {/* eslint-enable @typescript-eslint/no-explicit-any */}

      {/* Indicador de estado offline */}
      {/* eslint-disable @typescript-eslint/no-explicit-any */}
      <OfflineIndicator isOnline={isOnline} pedidosPendientes={pedidosPendientes as any} mermasPendientes={mermasPendientes as any} sincronizando={sincronizando} onSincronizar={handleSincronizar} clientes={clientes as any} />
      {/* eslint-enable @typescript-eslint/no-explicit-any */}

      {/* PWA Prompt */}
      <PWAPrompt />
    </div>
  );
}

export default function App(): ReactElement {
  return (
    <ErrorBoundary>
      <ThemeProvider>
        <AuthProvider>
          <NotificationProvider>
            <AppContent />
          </NotificationProvider>
        </AuthProvider>
      </ThemeProvider>
    </ErrorBoundary>
  );
}

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
