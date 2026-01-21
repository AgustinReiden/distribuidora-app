import React, { useEffect, lazy, Suspense } from 'react';
import { Loader2 } from 'lucide-react';
import { AuthProvider, useAuth, useClientes, useProductos, usePedidos, useUsuarios, useDashboard, useBackup, usePagos, useMermas, useCompras, useRecorridos, setErrorNotifier } from './hooks/supabase';
import { ThemeProvider } from './contexts/ThemeContext';
import { NotificationProvider, useNotification } from './contexts/NotificationContext';
import { useOptimizarRuta } from './hooks/useOptimizarRuta.js';
import { useOfflineSync } from './hooks/useOfflineSync.js';
import { useAppState, useAppDerivedState } from './hooks/useAppState.js';
import { useAppHandlers } from './hooks/useAppHandlers.js';

// Componentes base
import LoginScreen from './components/auth/LoginScreen';
import ErrorBoundary from './components/ErrorBoundary';
import TopNavigation from './components/layout/TopNavigation';
import OfflineIndicator from './components/layout/OfflineIndicator.jsx';
import AppModals from './components/AppModals.jsx';
import PWAPrompt from './components/PWAPrompt.jsx';
import SkipLinks from './components/a11y/SkipLinks.jsx';

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

function LoadingVista() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  );
}

function MainApp() {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const notify = useNotification();

  // Estado de la aplicación (consolidado)
  const appState = useAppState(perfil);
  const { vista, setVista, fechaRecorridos, setFechaRecorridos, modales, guardando, cargandoHistorial, busqueda, paginaActual, setPaginaActual } = appState;

  // Configurar notificador de errores
  useEffect(() => {
    setErrorNotifier((message) => notify.error(message));
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

  // Handlers (consolidados)
  const handlers = useAppHandlers({
    clientes, productos, pedidos, proveedores,
    agregarCliente, actualizarCliente, eliminarCliente,
    agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock, actualizarPreciosMasivo,
    crearPedido, cambiarEstado, asignarTransportista, eliminarPedido, actualizarNotasPedido, actualizarEstadoPago, actualizarFormaPago, actualizarOrdenEntrega, actualizarItemsPedido, fetchHistorialPedido,
    actualizarUsuario, registrarPago, obtenerResumenCuenta, registrarMerma, registrarCompra, anularCompra, agregarProveedor, actualizarProveedor, crearRecorrido, limpiarRuta,
    refetchProductos, refetchPedidos, refetchMetricas, refetchMermas, refetchCompras, refetchProveedores,
    appState, notify, user, rutaOptimizada, isOnline, guardarPedidoOffline, guardarMermaOffline
  });

  // Cargar recorridos cuando se cambia a la vista
  useEffect(() => {
    if (vista === 'recorridos' && isAdmin) {
      const hoy = new Date().toISOString().split('T')[0];
      if (fechaRecorridos === hoy) fetchRecorridosHoy();
      else fetchRecorridosPorFecha(fechaRecorridos);
    }
  }, [vista, fechaRecorridos, isAdmin, fetchRecorridosHoy, fetchRecorridosPorFecha]);

  // Auto-sincronizar cuando vuelve la conexión
  useEffect(() => {
    const sincronizar = async () => {
      try {
        if (pedidosPendientes.length > 0) {
          const resultadoPedidos = await sincronizarPedidos(crearPedido, descontarStock);
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
      } catch (err) {
        notify.error('Error durante la sincronización: ' + err.message);
      }
    };

    if (isOnline && (pedidosPendientes.length > 0 || mermasPendientes.length > 0)) {
      sincronizar();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOnline]);

  const handleLogout = async () => {
    try { await logout(); } catch { /* error silenciado */ }
  };

  // Handler para sincronización manual
  const handleSincronizar = async () => {
    try {
      if (pedidosPendientes.length > 0) {
        const resultadoPedidos = await sincronizarPedidos(crearPedido, descontarStock);
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
    } catch (err) {
      notify.error('Error durante la sincronización: ' + err.message);
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
                isAdmin={isAdmin} isPreventista={isPreventista} isTransportista={isTransportista} userId={user?.id}
                clientes={clientes} productos={productos} transportistas={transportistas} loading={loadingPedidos} exportando={exportando}
                onBusquedaChange={handlers.handleBusquedaChange}
                onFiltrosChange={(nuevosFiltros) => handlers.handleFiltrosChange(nuevosFiltros, filtros, setFiltros)}
                onPageChange={setPaginaActual}
                onNuevoPedido={() => modales.pedido.setOpen(true)}
                onOptimizarRuta={() => modales.optimizarRuta.setOpen(true)}
                onExportarPDF={() => modales.exportarPDF.setOpen(true)}
                onExportarExcel={() => exportarPedidosExcel(pedidosParaMostrar, { ...filtros, busqueda }, transportistas)}
                onModalFiltroFecha={() => modales.filtroFecha.setOpen(true)}
                onVerHistorial={handlers.handleVerHistorial}
                onEditarPedido={handlers.handleEditarPedido}
                onMarcarEnPreparacion={handlers.handleMarcarEnPreparacion}
                onAsignarTransportista={(pedido) => { appState.setPedidoAsignando(pedido); modales.asignar.setOpen(true); }}
                onMarcarEntregado={handlers.handleMarcarEntregado}
                onDesmarcarEntregado={handlers.handleDesmarcarEntregado}
                onEliminarPedido={handlers.handleEliminarPedido}
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
              <VistaUsuarios usuarios={usuarios} loading={loadingUsuarios} onEditarUsuario={(usuario) => { appState.setUsuarioEditando(usuario); modales.usuario.setOpen(true); }} />
            )}

            {vista === 'recorridos' && isAdmin && (
              <VistaRecorridos
                recorridos={recorridos} loading={loadingRecorridos} fechaSeleccionada={fechaRecorridos} estadisticas={appState.estadisticasRecorridos}
                onRefresh={async () => { const hoy = new Date().toISOString().split('T')[0]; if (fechaRecorridos === hoy) await fetchRecorridosHoy(); else await fetchRecorridosPorFecha(fechaRecorridos); }}
                onFechaChange={async (fecha) => { setFechaRecorridos(fecha); const hoy = new Date().toISOString().split('T')[0]; if (fecha === hoy) await fetchRecorridosHoy(); else await fetchRecorridosPorFecha(fecha); }}
              />
            )}

            {vista === 'compras' && isAdmin && (
              <VistaCompras compras={compras} proveedores={proveedores} loading={loadingCompras} isAdmin={isAdmin} onNuevaCompra={handlers.handleNuevaCompra} onVerDetalle={handlers.handleVerDetalleCompra} onAnularCompra={handlers.handleAnularCompra} />
            )}

            {vista === 'proveedores' && isAdmin && (
              <VistaProveedores proveedores={proveedores} compras={compras} loading={loadingCompras} isAdmin={isAdmin} onNuevoProveedor={handlers.handleNuevoProveedor} onEditarProveedor={handlers.handleEditarProveedor} onEliminarProveedor={handlers.handleEliminarProveedor} onToggleActivo={handlers.handleToggleActivoProveedor} />
            )}
          </Suspense>
        </div>
      </main>

      {/* Modales */}
      <AppModals
        appState={{ ...appState, filtros, setFiltros }}
        handlers={handlers}
        clientes={clientes} productos={productos} pedidos={pedidos} usuarios={usuarios}
        transportistas={transportistas} proveedores={proveedores} mermas={mermas} categorias={categorias}
        fetchPedidosEliminados={fetchPedidosEliminados} actualizarItemsPedido={actualizarItemsPedido} actualizarPreciosMasivo={actualizarPreciosMasivo} optimizarRuta={optimizarRuta}
        guardando={guardando} cargandoHistorial={cargandoHistorial} loadingOptimizacion={loadingOptimizacion} rutaOptimizada={rutaOptimizada} errorOptimizacion={errorOptimizacion}
        user={user} isAdmin={isAdmin} isPreventista={isPreventista} isOnline={isOnline}
      />

      {/* Indicador de estado offline */}
      <OfflineIndicator isOnline={isOnline} pedidosPendientes={pedidosPendientes} mermasPendientes={mermasPendientes} sincronizando={sincronizando} onSincronizar={handleSincronizar} clientes={clientes} />

      {/* PWA Prompt */}
      <PWAPrompt />
    </div>
  );
}

export default function App() {
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

function AppContent() {
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
