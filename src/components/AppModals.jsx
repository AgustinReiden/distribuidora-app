/**
 * Componente consolidado para todos los modales de la aplicación
 * Extrae el renderizado de modales de App.jsx para mejor organización
 */
import React from 'react';
import { ModalConfirmacion, ModalFiltroFecha, ModalCliente, ModalProducto, ModalUsuario, ModalAsignarTransportista, ModalPedido, ModalHistorialPedido, ModalEditarPedido, ModalExportarPDF, ModalGestionRutas } from './Modals.jsx';
import ModalFichaCliente from './modals/ModalFichaCliente.jsx';
import ModalRegistrarPago from './modals/ModalRegistrarPago.jsx';
import ModalMermaStock from './modals/ModalMermaStock.jsx';
import ModalHistorialMermas from './modals/ModalHistorialMermas.jsx';
import ModalCompra from './modals/ModalCompra.jsx';
import ModalDetalleCompra from './modals/ModalDetalleCompra.jsx';
import ModalProveedor from './modals/ModalProveedor.jsx';
import ModalImportarPrecios from './modals/ModalImportarPrecios.jsx';
import ModalPedidosEliminados from './modals/ModalPedidosEliminados.jsx';
import { generarOrdenPreparacion, generarHojaRuta } from '../lib/pdfExport.js';

export default function AppModals({
  // Estado de la app
  appState,
  handlers,

  // Datos
  clientes,
  productos,
  pedidos,
  usuarios,
  transportistas,
  proveedores,
  mermas,
  categorias,

  // Funciones de datos
  fetchPedidosEliminados,
  actualizarItemsPedido,
  actualizarPreciosMasivo,
  optimizarRuta,

  // Estado de carga
  guardando,
  cargandoHistorial,
  loadingOptimizacion,
  rutaOptimizada,
  errorOptimizacion,

  // Usuario y permisos
  user,
  isAdmin,
  isPreventista,
  isOnline
}) {
  const {
    modales,
    clienteEditando,
    setClienteEditando,
    productoEditando,
    setProductoEditando,
    usuarioEditando,
    setUsuarioEditando,
    pedidoAsignando,
    setPedidoAsignando,
    pedidoHistorial,
    setPedidoHistorial,
    historialCambios,
    setHistorialCambios,
    pedidoEditando,
    setPedidoEditando,
    clienteFicha,
    setClienteFicha,
    clientePago,
    setClientePago,
    saldoPendienteCliente,
    productoMerma,
    setProductoMerma,
    compraDetalle,
    setCompraDetalle,
    proveedorEditando,
    setProveedorEditando,
    nuevoPedido,
    setCargandoHistorial,
    filtros,
    setFiltros
  } = appState;

  const zonasExistentes = [...new Set(clientes.map(c => c.zona).filter(Boolean))];

  return (
    <>
      {/* Modal de Confirmación */}
      <ModalConfirmacion
        config={modales.confirm.config}
        onClose={() => modales.confirm.setConfig({ visible: false })}
      />

      {/* Modal de Filtro de Fecha */}
      {modales.filtroFecha.open && (
        <ModalFiltroFecha
          filtros={filtros}
          onApply={(nuevosFiltros) => handlers.handleFiltrosChange(nuevosFiltros, filtros, setFiltros)}
          onClose={() => modales.filtroFecha.setOpen(false)}
        />
      )}

      {/* Modal de Cliente */}
      {modales.cliente.open && (
        <ModalCliente
          cliente={clienteEditando}
          onSave={handlers.handleGuardarCliente}
          onClose={() => { modales.cliente.setOpen(false); setClienteEditando(null); }}
          guardando={guardando}
          isAdmin={isAdmin}
          zonasExistentes={zonasExistentes}
        />
      )}

      {/* Modal de Producto */}
      {modales.producto.open && (
        <ModalProducto
          producto={productoEditando}
          categorias={categorias}
          onSave={handlers.handleGuardarProducto}
          onClose={() => { modales.producto.setOpen(false); setProductoEditando(null); }}
          guardando={guardando}
        />
      )}

      {/* Modal de Pedido */}
      {modales.pedido.open && (
        <ModalPedido
          productos={productos}
          clientes={clientes}
          categorias={categorias}
          nuevoPedido={nuevoPedido}
          onClose={() => { modales.pedido.setOpen(false); appState.resetNuevoPedido(); }}
          onClienteChange={handlers.handleClienteChange}
          onAgregarItem={handlers.agregarItemPedido}
          onActualizarCantidad={handlers.actualizarCantidadItem}
          onCrearCliente={handlers.handleCrearClienteEnPedido}
          onGuardar={handlers.handleGuardarPedidoConOffline}
          isOffline={!isOnline}
          onNotasChange={handlers.handleNotasChange}
          onFormaPagoChange={handlers.handleFormaPagoChange}
          onEstadoPagoChange={handlers.handleEstadoPagoChange}
          onMontoPagadoChange={handlers.handleMontoPagadoChange}
          guardando={guardando}
          isAdmin={isAdmin}
          isPreventista={isPreventista}
        />
      )}

      {/* Modal de Usuario */}
      {modales.usuario.open && (
        <ModalUsuario
          usuario={usuarioEditando}
          onSave={handlers.handleGuardarUsuario}
          onClose={() => { modales.usuario.setOpen(false); setUsuarioEditando(null); }}
          guardando={guardando}
        />
      )}

      {/* Modal de Asignar Transportista */}
      {modales.asignar.open && (
        <ModalAsignarTransportista
          pedido={pedidoAsignando}
          transportistas={transportistas}
          onSave={handlers.handleAsignarTransportista}
          onClose={() => { modales.asignar.setOpen(false); setPedidoAsignando(null); }}
          guardando={guardando}
        />
      )}

      {/* Modal de Historial de Pedido */}
      {modales.historial.open && (
        <ModalHistorialPedido
          pedido={pedidoHistorial}
          historial={historialCambios}
          onClose={() => { modales.historial.setOpen(false); setPedidoHistorial(null); setHistorialCambios([]); setCargandoHistorial(false); }}
          loading={cargandoHistorial}
        />
      )}

      {/* Modal de Editar Pedido */}
      {modales.editarPedido.open && (
        <ModalEditarPedido
          pedido={pedidoEditando}
          productos={productos}
          isAdmin={isAdmin}
          onSave={handlers.handleGuardarEdicionPedido}
          onSaveItems={async (items) => {
            await actualizarItemsPedido(pedidoEditando.id, items, user?.id);
            handlers.refetchProductos?.();
          }}
          onClose={() => { modales.editarPedido.setOpen(false); setPedidoEditando(null); }}
          guardando={guardando}
        />
      )}

      {/* Modal de Exportar PDF */}
      {modales.exportarPDF.open && (
        <ModalExportarPDF
          pedidos={pedidos}
          transportistas={transportistas}
          onExportarOrdenPreparacion={generarOrdenPreparacion}
          onExportarHojaRuta={generarHojaRuta}
          onClose={() => modales.exportarPDF.setOpen(false)}
        />
      )}

      {/* Modal de Gestión de Rutas */}
      {modales.optimizarRuta.open && (
        <ModalGestionRutas
          transportistas={transportistas}
          pedidos={pedidos}
          onOptimizar={(transportistaId, pedidosData) => optimizarRuta(transportistaId, pedidosData)}
          onAplicarOrden={handlers.handleAplicarOrdenOptimizado}
          onExportarPDF={handlers.handleExportarHojaRutaOptimizada}
          onClose={handlers.handleCerrarModalOptimizar}
          loading={loadingOptimizacion}
          guardando={guardando}
          rutaOptimizada={rutaOptimizada}
          error={errorOptimizacion}
        />
      )}

      {/* Modal de Ficha de Cliente */}
      {modales.fichaCliente.open && clienteFicha && (
        <ModalFichaCliente
          cliente={clienteFicha}
          onClose={() => { modales.fichaCliente.setOpen(false); setClienteFicha(null); }}
          onRegistrarPago={handlers.handleAbrirRegistrarPago}
        />
      )}

      {/* Modal de Registrar Pago */}
      {modales.registrarPago.open && clientePago && (
        <ModalRegistrarPago
          cliente={clientePago}
          saldoPendiente={saldoPendienteCliente}
          pedidos={pedidos}
          onClose={() => { modales.registrarPago.setOpen(false); setClientePago(null); }}
          onConfirmar={handlers.handleRegistrarPago}
          onGenerarRecibo={handlers.handleGenerarReciboPago}
        />
      )}

      {/* Modal de Merma de Stock */}
      {modales.mermaStock.open && productoMerma && (
        <ModalMermaStock
          producto={productoMerma}
          onSave={handlers.handleRegistrarMerma}
          onClose={() => { modales.mermaStock.setOpen(false); setProductoMerma(null); }}
          isOffline={!isOnline}
        />
      )}

      {/* Modal de Historial de Mermas */}
      {modales.historialMermas.open && (
        <ModalHistorialMermas
          mermas={mermas}
          productos={productos}
          usuarios={usuarios}
          onClose={() => modales.historialMermas.setOpen(false)}
        />
      )}

      {/* Modal de Compra */}
      {modales.compra.open && (
        <ModalCompra
          productos={productos}
          proveedores={proveedores}
          onSave={handlers.handleRegistrarCompra}
          onClose={() => modales.compra.setOpen(false)}
        />
      )}

      {/* Modal de Detalle de Compra */}
      {modales.detalleCompra.open && compraDetalle && (
        <ModalDetalleCompra
          compra={compraDetalle}
          onClose={() => { modales.detalleCompra.setOpen(false); setCompraDetalle(null); }}
          onAnular={handlers.handleAnularCompra}
        />
      )}

      {/* Modal de Proveedor */}
      {modales.proveedor.open && (
        <ModalProveedor
          proveedor={proveedorEditando}
          onSave={handlers.handleGuardarProveedor}
          onClose={() => { modales.proveedor.setOpen(false); setProveedorEditando(null); }}
          guardando={guardando}
        />
      )}

      {/* Modal de Importar Precios */}
      {modales.importarPrecios.open && (
        <ModalImportarPrecios
          productos={productos}
          onActualizarPrecios={actualizarPreciosMasivo}
          onClose={() => modales.importarPrecios.setOpen(false)}
        />
      )}

      {/* Modal de Pedidos Eliminados */}
      {modales.pedidosEliminados.open && (
        <ModalPedidosEliminados
          onFetch={fetchPedidosEliminados}
          onClose={() => modales.pedidosEliminados.setOpen(false)}
        />
      )}
    </>
  );
}
