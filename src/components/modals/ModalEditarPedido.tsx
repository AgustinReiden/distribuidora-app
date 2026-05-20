import { lazy, Suspense, useState, memo, useEffect, useMemo } from 'react';
import { Loader2, AlertCircle, Package, Plus, Minus, Trash2, Search, X, ShoppingCart, Pencil, Gift, RefreshCw, UserCheck } from 'lucide-react';
import ModalBase from './ModalBase';
import ModalConfirmacion, { type ModalConfirmacionConfig } from './ModalConfirmacion';
import { formatPrecio } from '../../utils/formatters';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalEditarPedidoSchema } from '../../lib/schemas';
import { usePromocionPedido } from '../../hooks/usePromocionPedido';
import { useRendiciones } from '../../hooks/supabase/useRendiciones';
import { usePromocionesListQuery, usePedidoSustitucionesQuery } from '../../hooks/queries/usePromocionesQuery';
import { usePreventistasAsignablesQuery } from '../../hooks/queries/useUsuariosQuery';
import { calcularNetoVenta, parsePrecio } from '../../utils/calculations';
import type { PedidoDB, ProductoDB, PedidoItemDB } from '../../types';

const ModalSustituirRegalo = lazy(() => import('./ModalSustituirRegalo'));

/** Item del pedido para edición. Incluye fiscales opcionales que se pueblan al guardar. */
export interface PedidoEditItem {
  productoId: string;
  nombre: string;
  cantidad: number;
  precioUnitario: number;
  cantidadOriginal: number;
  esNuevo?: boolean;
  precioOverride?: boolean;
  esBonificacion?: boolean;
  promocionId?: string;
  neto_unitario?: number;
  iva_unitario?: number;
  impuestos_internos_unitario?: number;
  porcentaje_iva?: number;
}

/** Datos a guardar del pedido. Pago se gestiona en ModalRegistrarPago. */
export interface PedidoSaveData {
  notas: string;
  fecha?: string;
  fechaEntrega?: string;
  fechaEntregaProgramada?: string;
}

/** Props del componente ModalEditarPedido */
export interface ModalEditarPedidoProps {
  /** Pedido a editar */
  pedido: PedidoDB | null;
  /** Lista de productos disponibles */
  productos?: ProductoDB[];
  /** Permite agregar/eliminar items y modificar cantidades. Default: isAdmin. */
  canEditItems?: boolean;
  /** Permite editar precios unitarios. Default: isAdmin. */
  canEditPrices?: boolean;
  /** Permite cambiar fecha de pedido / entrega / entrega programada. Default: isAdmin. */
  canEditFechaEntrega?: boolean;
  /** Permite sustituir el producto de un regalo de promo. Default: false. Solo admin/encargado. */
  canSustituirRegalo?: boolean;
  /** Permite reasignar el preventista del pedido. Default: false. Solo admin. */
  canEditPreventista?: boolean;
  /** @deprecated usar canEditItems/canEditPrices/canEditFechaEntrega. Mantiene compat. */
  isAdmin?: boolean;
  /** Callback al guardar datos */
  onSave: (data: PedidoSaveData) => void | Promise<void>;
  /** Callback al guardar items */
  onSaveItems?: (items: PedidoEditItem[]) => Promise<void>;
  /** Callback al cambiar el preventista asignado al pedido (solo admin) */
  onCambiarPreventista?: (nuevoPreventistaId: string) => Promise<void>;
  /** Callback al cerrar */
  onClose: () => void;
  /** Indica si está guardando */
  guardando: boolean;
}

const ModalEditarPedido = memo(function ModalEditarPedido({
  pedido,
  productos = [],
  canEditItems,
  canEditPrices,
  canEditFechaEntrega,
  canSustituirRegalo = false,
  canEditPreventista = false,
  isAdmin = false,
  onSave,
  onSaveItems,
  onCambiarPreventista,
  onClose,
  guardando
}: ModalEditarPedidoProps) {
  // Resolver flags de permiso. Si el caller pasa los flags nuevos los usamos;
  // si no, fallback al isAdmin legacy.
  const puedeEditarItems = canEditItems ?? isAdmin;
  const puedeEditarPrecios = canEditPrices ?? isAdmin;
  const puedeEditarFechas = canEditFechaEntrega ?? isAdmin;
  const puedeEditarPreventista = canEditPreventista;

  const [notas, setNotas] = useState<string>(pedido?.notas || "");
  const [fecha, setFecha] = useState<string>(pedido?.fecha || "");
  const fechaEntregaOriginal = pedido?.fecha_entrega ? pedido.fecha_entrega.split('T')[0] : "";
  const [fechaEntrega, setFechaEntrega] = useState<string>(fechaEntregaOriginal);
  const fechaEntregaProgramadaOriginal = pedido?.fecha_entrega_programada || "";
  const [fechaEntregaProgramada, setFechaEntregaProgramada] = useState<string>(fechaEntregaProgramadaOriginal);
  const [errorValidacion, setErrorValidacion] = useState<string>('');
  const [confirmConfig, setConfirmConfig] = useState<ModalConfirmacionConfig | null>(null);

  // Zod validation (solo notas; el pago se maneja en ModalRegistrarPago)
  const { validate } = useZodValidation(modalEditarPedidoSchema);

  // Consulta de control de rendición (para warning al cambiar fecha_entrega)
  const { consultarControl } = useRendiciones();

  // Estado para edición de items (solo admin)
  const [items, setItems] = useState<PedidoEditItem[]>([]);
  const [itemsOriginales, setItemsOriginales] = useState<PedidoEditItem[]>([]);
  const [mostrarBuscador, setMostrarBuscador] = useState<boolean>(false);
  const [busquedaProducto, setBusquedaProducto] = useState<string>('');
  const [itemsModificados, setItemsModificados] = useState<boolean>(false);
  const [errorStock, setErrorStock] = useState<string | null>(null);
  const [editingPriceId, setEditingPriceId] = useState<string | null>(null);
  const [editingPriceValue, setEditingPriceValue] = useState<string>('');

  // Sustitucion de regalos: el row persistido a editar (id real de pedido_items).
  const [sustItemTarget, setSustItemTarget] = useState<PedidoItemDB | null>(null);

  // Verificar si el pedido está entregado (no editable)
  const pedidoEntregado = pedido?.estado === 'entregado';

  // Regalos persistidos en DB (items con es_bonificacion=true). A diferencia
  // de las bonificacionesCalculadas que se recalculan localmente, estas son
  // las filas REALES de pedido_items con su `id`, necesarias para invocar
  // la RPC `sustituir_regalo_pedido`.
  const regalosPersistidos = useMemo<PedidoItemDB[]>(
    () => (pedido?.items ?? []).filter(i => i.es_bonificacion === true),
    [pedido]
  );

  // Mapa promocion_id -> { regalo_mueve_stock, ajuste_producto_id } para
  // resolver modo (A/B) y default del contenedor sustituto en el modal.
  const { data: promociones = [] } = usePromocionesListQuery();
  const promoInfoMap = useMemo(() => {
    const m = new Map<string, { mueveStock: boolean; ajusteProductoId: string | null }>();
    for (const p of promociones) {
      m.set(String(p.id), {
        mueveStock: Boolean(p.regalo_mueve_stock),
        ajusteProductoId: p.ajuste_producto_id ? String(p.ajuste_producto_id) : null,
      });
    }
    return m;
  }, [promociones]);

  // Sustituciones de regalo del pedido (mig 058/059/060). Cuando el resolver
  // de promos regenera una bonificacion con el producto original, mapeamos
  // al sustituto vigente para no pisar la decision del admin al guardar
  // (defensa en profundidad junto al trigger SQL trg_aplicar_sustituciones_regalo).
  const { data: sustituciones = [] } = usePedidoSustitucionesQuery(pedido?.id);
  // (promocion_id, producto_original_id) -> { producto_sustituto_id, cantidad_sustituta }
  const sustitucionMap = useMemo(() => {
    const m = new Map<string, { productoSustitutoId: string; cantidadSustituta: number }>();
    // Como las sustituciones vienen ordenadas DESC por created_at, la primera
    // entrada para cada (promo, original) gana (la mas reciente).
    for (const s of sustituciones) {
      const key = `${s.promocion_id ?? 'null'}|${s.producto_original_id}`;
      if (!m.has(key)) {
        m.set(key, {
          productoSustitutoId: String(s.producto_sustituto_id),
          cantidadSustituta: Number(s.cantidad_sustituta),
        });
      }
    }
    return m;
  }, [sustituciones]);

  // Inicializar items del pedido — sólo no-bonificaciones.
  // Las bonificaciones se recalculan reactivamente a partir del estado no-bonif
  // vía usePromocionPedido (ver abajo). Así, editar cantidades, agregar o
  // eliminar productos recalcula las promos automáticamente.
  useEffect(() => {
    if (pedido?.items) {
      const itemsFormateados = pedido.items
        .filter(item => !item.es_bonificacion)
        .map(item => ({
          productoId: item.producto_id,
          nombre: item.producto?.nombre || 'Producto desconocido',
          cantidad: item.cantidad,
          precioUnitario: item.precio_unitario,
          cantidadOriginal: item.cantidad,
        }));
      setItems(itemsFormateados);
      setItemsOriginales(JSON.parse(JSON.stringify(itemsFormateados)));
    }
  }, [pedido]);

  // Armar input con precios base para la resolución. Para items con override
  // manual usamos ese precio; para los demás, el precio base del producto
  // (si el precio del item en DB es 0 por ser regalo legacy, igual funcionaría).
  const itemsConPrecioBase = useMemo(() => {
    return items.map(item => {
      if (item.precioOverride) {
        return {
          productoId: item.productoId,
          cantidad: item.cantidad,
          precioUnitario: item.precioUnitario,
          precioOverride: true,
        };
      }
      const producto = productos.find(p => p.id === item.productoId);
      return {
        productoId: item.productoId,
        cantidad: item.cantidad,
        precioUnitario: producto?.precio || item.precioUnitario,
      };
    });
  }, [items, productos]);

  // Re-resolver promos + mayorista usando la FECHA DEL PEDIDO (no hoy).
  // Así promos vigentes al momento de la creación siguen aplicando; y promos
  // creadas DESPUÉS del pedido no se aplican retroactivamente.
  const fechaReferenciaPromo = pedido?.fecha || undefined;
  const {
    itemsFinales,
    totalFinal,
    moqMap,
    isLoading: promosLoading,
  } = usePromocionPedido(itemsConPrecioBase, fechaReferenciaPromo);

  // Mapa de precios resueltos para mostrar en cada item no-bonif
  const preciosResueltosMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const item of itemsFinales) {
      if (item.esBonificacion) continue;
      const originalItem = items.find(i => i.productoId === item.productoId);
      if (originalItem?.precioOverride) {
        map.set(item.productoId, originalItem.precioUnitario);
      } else {
        map.set(item.productoId, item.precioUnitario);
      }
    }
    return map;
  }, [itemsFinales, items]);

  // Bonificaciones calculadas para mostrar como filas read-only.
  // IMPORTANTE: aplicamos el mapping de sustituciones para que las
  // bonificaciones reflejen el producto sustituido (no el original) — sino
  // al guardar el modal, actualizar_pedido_items recibiria el producto
  // original y pisaria la sustitucion (el trigger SQL es safety net pero
  // queremos consistencia visual y al guardar).
  const bonificacionesCalculadas = useMemo(() => {
    return itemsFinales
      .filter(i => i.esBonificacion)
      .map(bonif => {
        const promoIdStr = String(bonif.promoId ?? 'null');
        const origIdStr = String(bonif.productoId);
        const key = `${promoIdStr}|${origIdStr}`;
        const sub = sustitucionMap.get(key);
        const productoIdFinal = sub ? sub.productoSustitutoId : origIdStr;
        const cantidadFinal = sub ? sub.cantidadSustituta : bonif.cantidad;
        const producto = productos.find(p => String(p.id) === productoIdFinal);
        return {
          productoId: productoIdFinal,
          nombre: producto?.nombre || bonif.promoNombre || 'Regalo',
          cantidad: cantidadFinal,
          promoNombre: bonif.promoNombre,
          promocionId: bonif.promoId,
          esSustituido: !!sub,
        };
      });
  }, [itemsFinales, productos, sustitucionMap]);

  // Detectar si las bonificaciones recalculadas difieren de las que estaban
  // guardadas en el pedido. Si difieren, hay que marcar "modificado" para que
  // el user vea el nuevo total y pueda guardar (arregla pedidos con promos
  // obsoletas por edición previa sin recálculo).
  const bonifDifierenDeDB = useMemo(() => {
    if (promosLoading || !pedido?.items || items.length === 0) return false;
    const originales = pedido.items.filter(i => i.es_bonificacion);
    if (originales.length !== bonificacionesCalculadas.length) return true;
    const mapOrig = new Map(originales.map(b => [String(b.producto_id), b.cantidad]));
    for (const b of bonificacionesCalculadas) {
      if (mapOrig.get(String(b.productoId)) !== b.cantidad) return true;
    }
    return false;
  }, [promosLoading, pedido, items, bonificacionesCalculadas]);

  const total = itemsModificados ? totalFinal : (pedido?.total || 0);

  // Detectar si hubo cambios en items (cantidad, precio, agregados o eliminados)
  useEffect(() => {
    if (itemsOriginales.length === 0) return;

    const cambios = items.length !== itemsOriginales.length ||
      items.some((item) => {
        const original = itemsOriginales.find(o => o.productoId === item.productoId);
        if (!original) return true; // item nuevo
        if (original.cantidad !== item.cantidad) return true;
        if (item.precioOverride) return true;
        if (Math.abs((original.precioUnitario ?? 0) - (item.precioUnitario ?? 0)) > 0.001) return true;
        return false;
      }) ||
      itemsOriginales.some(o => !items.find(i => i.productoId === o.productoId));

    setItemsModificados(cambios || bonifDifierenDeDB);
  }, [items, itemsOriginales, bonifDifierenDeDB]);

  // Productos disponibles para agregar
  const productosDisponibles = useMemo(() => {
    if (!busquedaProducto.trim()) return [];
    const busquedaLower = busquedaProducto.toLowerCase();
    return productos
      .filter(p =>
        !items.find(i => i.productoId === p.id) &&
        p.stock > 0 &&
        (p.nombre?.toLowerCase().includes(busquedaLower) ||
          p.codigo?.toLowerCase().includes(busquedaLower))
      )
      .slice(0, 10);
  }, [productos, items, busquedaProducto]);

  // Funciones para editar items
  const handleCantidadChange = (productoId: string, delta: number): void => {
    setErrorStock(null);
    setItems(prev => prev.map(item => {
      if (item.productoId === productoId) {
        const moq = moqMap.get(String(productoId));
        const minCantidad = moq && moq > 1 ? moq : 1;
        const nuevaCantidad = Math.max(minCantidad, item.cantidad + delta);
        // Verificar stock disponible
        const producto = productos.find(p => p.id === productoId);
        const cantidadOriginal = itemsOriginales.find(o => o.productoId === productoId)?.cantidad || 0;
        const stockDisponible = (producto?.stock || 0) + cantidadOriginal;

        if (nuevaCantidad > stockDisponible) {
          setErrorStock(`Stock insuficiente para "${item.nombre}". Disponible: ${stockDisponible}`);
          return item;
        }
        return { ...item, cantidad: nuevaCantidad };
      }
      return item;
    }));
  };

  const handleEliminarItem = (productoId: string): void => {
    setItems(prev => prev.filter(item => item.productoId !== productoId));
  };

  const handlePrecioChange = (productoId: string, nuevoPrecio: number): void => {
    if (nuevoPrecio <= 0) return;
    setItems(prev => prev.map(item =>
      item.productoId === productoId
        ? { ...item, precioUnitario: nuevoPrecio, precioOverride: true }
        : item
    ));
  };

  const handleAgregarProducto = (producto: ProductoDB): void => {
    const moq = moqMap.get(String(producto.id));
    const cantidadInicial = moq && moq > 1 ? moq : 1;
    setItems(prev => [...prev, {
      productoId: producto.id,
      nombre: producto.nombre,
      cantidad: cantidadInicial,
      precioUnitario: producto.precio,
      cantidadOriginal: 0,
      esNuevo: true
    }]);
    setBusquedaProducto('');
    setMostrarBuscador(false);
  };

  const handleGuardar = async (): Promise<void> => {
    setErrorValidacion('');
    setErrorStock(null);

    // Validar con Zod (solo notas)
    const result = validate({ notas });
    if (!result.success) {
      const firstError = Object.values(result.errors || {})[0] || 'Error de validación';
      setErrorValidacion(firstError);
      return;
    }

    // Si cambió la fecha_entrega (admin/encargado + pedido entregado), consultar control de rendición
    const fechaEntregaCambio = puedeEditarFechas && pedidoEntregado && fechaEntrega && fechaEntrega !== fechaEntregaOriginal;
    if (fechaEntregaCambio && pedido?.transportista_id) {
      try {
        const [origen, destino] = await Promise.all([
          fechaEntregaOriginal ? consultarControl(pedido.transportista_id, fechaEntregaOriginal) : Promise.resolve({ controlada: false, controlada_at: null, controlada_por_nombre: null }),
          consultarControl(pedido.transportista_id, fechaEntrega)
        ]);
        const avisos: string[] = [];
        if (origen.controlada) {
          avisos.push(`La rendición del ${fechaEntregaOriginal} ya fue controlada por ${origen.controlada_por_nombre || 'un usuario'}.`);
        }
        if (destino.controlada) {
          avisos.push(`La rendición del ${fechaEntrega} ya fue controlada por ${destino.controlada_por_nombre || 'un usuario'}.`);
        }
        if (avisos.length > 0) {
          const mensaje = `${avisos.join('\n')}\n\nSi procedés, ese control se anulará y la rendición deberá volver a controlarse. ¿Continuar?`;
          setConfirmConfig({
            visible: true,
            tipo: 'warning',
            titulo: 'Rendición ya controlada',
            mensaje,
            onConfirm: () => {
              setConfirmConfig(null);
              void doGuardar(notas, true);
            },
          });
          return;
        }
      } catch {
        // Si falla la consulta, continuamos (el trigger SQL anulará el control igual)
      }
    }

    await doGuardar(notas, !!fechaEntregaCambio);
  };

  const doGuardar = async (
    notasFinal: string,
    fechaEntregaCambio: boolean,
  ): Promise<void> => {
    try {
      // Si hay cambios en items y el usuario puede editarlos, guardar items con
      // precios mayoristas resueltos, desglose fiscal y bonificaciones recalculadas.
      if (itemsModificados && puedeEditarItems && onSaveItems) {
        const tipoFactura = pedido?.tipo_factura || 'ZZ';

        // Items no-bonif del estado → con precio resuelto + desglose fiscal
        const itemsNoBonif: PedidoEditItem[] = items.map(item => {
          const precioFinal = preciosResueltosMap.get(item.productoId) ?? item.precioUnitario;
          const producto = productos.find(p => p.id === item.productoId);
          const pctIva = producto?.porcentaje_iva ?? 21;
          const pctImpInt = producto?.impuestos_internos ?? 0;
          const desglose = calcularNetoVenta(precioFinal, pctIva, pctImpInt, tipoFactura as 'ZZ' | 'FC');
          return {
            ...item,
            precioUnitario: precioFinal,
            neto_unitario: desglose.neto,
            iva_unitario: desglose.iva,
            impuestos_internos_unitario: desglose.impuestosInternos,
            porcentaje_iva: pctIva,
          };
        });

        // Bonificaciones recalculadas → precio 0, promocionId del hook
        const itemsBonif: PedidoEditItem[] = bonificacionesCalculadas.map(bonif => ({
          productoId: bonif.productoId,
          nombre: bonif.nombre,
          cantidad: bonif.cantidad,
          cantidadOriginal: 0,
          precioUnitario: 0,
          esBonificacion: true,
          promocionId: bonif.promocionId,
          neto_unitario: 0,
          iva_unitario: 0,
          impuestos_internos_unitario: 0,
          porcentaje_iva: 0,
        }));

        await onSaveItems([...itemsNoBonif, ...itemsBonif]);
      }
      // Guardar el resto de los datos
      const fechaEntregaProgramadaCambio = puedeEditarFechas && !pedidoEntregado && fechaEntregaProgramada !== fechaEntregaProgramadaOriginal;
      await onSave({
        notas: notasFinal,
        ...(puedeEditarFechas && fecha ? { fecha } : {}),
        ...(fechaEntregaCambio ? { fechaEntrega } : {}),
        ...(fechaEntregaProgramadaCambio ? { fechaEntregaProgramada } : {})
      });
    } catch (err) {
      const error = err as Error;
      setErrorValidacion(error.message || 'Error al guardar los cambios');
    }
  };

  const getStockDisponible = (productoId: string): number => {
    const producto = productos.find(p => p.id === productoId);
    const cantidadOriginal = itemsOriginales.find(o => o.productoId === productoId)?.cantidad || 0;
    return (producto?.stock || 0) + cantidadOriginal;
  };

  return (
    <ModalBase
      title={`Editar Pedido #${pedido?.id}`}
      description="Editar items, fechas y notas del pedido. El pago se gestiona desde el menú del pedido."
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Info del cliente */}
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-3 border dark:border-gray-600">
          <p className="text-sm text-gray-600 dark:text-gray-400">Cliente</p>
          <p className="font-medium dark:text-white">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500 dark:text-gray-400">{pedido?.cliente?.direccion}</p>
        </div>

        {/* Alerta de pedido entregado */}
        {pedidoEntregado && (
          <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
            <div className="flex items-center gap-2">
              <AlertCircle className="w-5 h-5 text-yellow-600" />
              <p className="text-sm text-yellow-700 dark:text-yellow-400">
                Este pedido ya fue entregado. Los productos no se pueden modificar.
              </p>
            </div>
          </div>
        )}

        {/* Sección de productos - Vista de solo lectura cuando no se pueden editar items o el pedido está entregado */}
        {(!puedeEditarItems || pedidoEntregado) && pedido && (pedido.items?.length ?? 0) > 0 && (
          <div className="border dark:border-gray-600 rounded-lg overflow-hidden">
            <div className="bg-gray-50 dark:bg-gray-700 px-4 py-3 flex items-center gap-2">
              <ShoppingCart className="w-5 h-5 text-blue-600" />
              <span className="font-medium dark:text-white">Productos del Pedido</span>
              <span className="text-xs text-gray-500">(solo lectura)</span>
            </div>
            <div className="divide-y dark:divide-gray-600">
              {pedido.items?.map(item => (
                <div key={item.producto_id} className="p-3 flex items-center justify-between">
                  <div className="flex-1">
                    <p className="font-medium text-sm dark:text-white">{item.producto?.nombre || 'Producto'}</p>
                    <p className="text-xs text-gray-500">{formatPrecio(item.precio_unitario)} c/u</p>
                  </div>
                  <div className="flex items-center gap-4">
                    <span className="text-sm dark:text-white">x{item.cantidad}</span>
                    <span className="font-semibold text-blue-600">{formatPrecio(item.cantidad * item.precio_unitario)}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Sección de productos editable (puede editar items y pedido no entregado) */}
        {puedeEditarItems && !pedidoEntregado && (
          <div className="border dark:border-gray-600 rounded-lg overflow-hidden">
            <div className="bg-gray-50 dark:bg-gray-700 px-4 py-3 flex items-center justify-between">
              <div className="flex items-center gap-2">
                <ShoppingCart className="w-5 h-5 text-blue-600" />
                <span className="font-medium dark:text-white">Productos del Pedido</span>
                {itemsModificados && (
                  <span className="text-xs bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400 px-2 py-0.5 rounded">
                    Modificado
                  </span>
                )}
              </div>
              <button
                onClick={() => setMostrarBuscador(!mostrarBuscador)}
                className="text-sm text-blue-600 hover:text-blue-700 flex items-center gap-1"
              >
                <Plus className="w-4 h-4" />
                Agregar
              </button>
            </div>

            {/* Buscador de productos */}
            {mostrarBuscador && (
              <div className="p-3 border-b dark:border-gray-600 bg-blue-50 dark:bg-blue-900/20">
                <div className="relative w-full">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400 pointer-events-none" />
                  <input
                    type="text"
                    value={busquedaProducto}
                    onChange={e => setBusquedaProducto(e.target.value)}
                    placeholder="Buscar producto por nombre o código..."
                    className="block w-full pl-10 pr-10 py-2.5 min-h-11 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
                    autoFocus
                  />
                  {busquedaProducto && (
                    <button
                      onClick={() => { setBusquedaProducto(''); setMostrarBuscador(false); }}
                      className="absolute right-3 top-1/2 -translate-y-1/2"
                    >
                      <X className="w-4 h-4 text-gray-400" />
                    </button>
                  )}
                </div>
                {productosDisponibles.length > 0 && (
                  <div className="mt-2 max-h-40 overflow-y-auto bg-white dark:bg-gray-800 rounded border dark:border-gray-600">
                    {productosDisponibles.map(producto => (
                      <button
                        key={producto.id}
                        onClick={() => handleAgregarProducto(producto)}
                        className="w-full px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-gray-700 flex justify-between items-center border-b last:border-b-0 dark:border-gray-600"
                      >
                        <div>
                          <p className="text-sm font-medium dark:text-white">{producto.nombre}</p>
                          <p className="text-xs text-gray-500">{producto.codigo} - Stock: {producto.stock}</p>
                        </div>
                        <span className="text-sm font-semibold text-blue-600">{formatPrecio(producto.precio)}</span>
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* Lista de items */}
            <div className="divide-y dark:divide-gray-600">
              {items.length === 0 ? (
                <div className="p-4 text-center text-gray-500">
                  <Package className="w-8 h-8 mx-auto mb-2 opacity-50" />
                  <p className="text-sm">No hay productos en el pedido</p>
                </div>
              ) : (
                items.map(item => {
                  const stockDisponible = getStockDisponible(item.productoId);
                  const cambio = item.cantidad - (item.cantidadOriginal || 0);
                  const precioResuelto = preciosResueltosMap.get(item.productoId) ?? item.precioUnitario;

                  return (
                    <div
                      key={item.productoId}
                      className={`p-3 flex items-center justify-between ${
                        item.esNuevo ? 'bg-green-50 dark:bg-green-900/10' :
                          cambio !== 0 ? 'bg-yellow-50 dark:bg-yellow-900/10' : ''
                      }`}
                    >
                      <div className="flex-1">
                        <div className="flex items-center gap-1.5">
                          <p className="font-medium text-sm dark:text-white">{item.nombre}</p>
                          {item.precioOverride && (
                            <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-orange-100 text-orange-700 rounded-full font-medium shrink-0">
                              <Pencil className="w-3 h-3" />
                              Manual
                            </span>
                          )}
                        </div>
                        <div className="flex items-center gap-2 text-xs text-gray-500">
                          {editingPriceId === item.productoId ? (
                            <div className="flex items-center gap-1">
                              <span className="text-orange-600">$</span>
                              <input
                                type="number"
                                inputMode="decimal"
                                step="0.01"
                                min="0.01"
                                aria-label="Editar precio unitario"
                                value={editingPriceValue}
                                onChange={e => setEditingPriceValue(e.target.value)}
                                onKeyDown={e => {
                                  if (e.key === 'Enter') {
                                    const newPrice = parsePrecio(editingPriceValue);
                                    if (newPrice > 0) handlePrecioChange(item.productoId, newPrice);
                                    setEditingPriceId(null);
                                  } else if (e.key === 'Escape') {
                                    setEditingPriceId(null);
                                  }
                                }}
                                onBlur={() => {
                                  const newPrice = parsePrecio(editingPriceValue);
                                  if (newPrice > 0) handlePrecioChange(item.productoId, newPrice);
                                  setEditingPriceId(null);
                                }}
                                className="w-28 px-2 py-1 text-sm border border-orange-300 rounded bg-orange-50 dark:bg-orange-900/20 dark:border-orange-600 dark:text-white focus:ring-2 focus:ring-orange-500 focus:outline-none"
                                autoFocus
                              />
                              <span className="text-orange-600">c/u</span>
                            </div>
                          ) : (
                            <span
                              className={`${item.precioOverride ? 'text-orange-600 font-medium' : ''} ${puedeEditarPrecios ? 'cursor-pointer hover:underline' : ''}`}
                              onClick={() => {
                                if (puedeEditarPrecios) {
                                  setEditingPriceId(item.productoId);
                                  setEditingPriceValue(String(precioResuelto));
                                }
                              }}
                            >
                              {formatPrecio(precioResuelto)} c/u
                              {puedeEditarPrecios && <Pencil className="w-3 h-3 inline ml-0.5 text-gray-400" />}
                            </span>
                          )}
                          <span>-</span>
                          <span>Stock disp: {stockDisponible}</span>
                          {item.esNuevo && (
                            <span className="text-green-600 font-medium">Nuevo</span>
                          )}
                          {!item.esNuevo && cambio !== 0 && (
                            <span className={cambio > 0 ? 'text-yellow-600' : 'text-orange-600'}>
                              ({cambio > 0 ? '+' : ''}{cambio})
                            </span>
                          )}
                        </div>
                      </div>

                      <div className="flex items-center gap-2">
                        {/* Controles de cantidad */}
                        <div className="flex items-center border dark:border-gray-600 rounded-lg">
                          <button
                            onClick={() => handleCantidadChange(item.productoId, -1)}
                            disabled={item.cantidad <= (moqMap.get(String(item.productoId)) || 1)}
                            className="p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 rounded-l-lg"
                          >
                            <Minus className="w-4 h-4" />
                          </button>
                          <span className="px-3 py-1 min-w-[40px] text-center font-medium dark:text-white">
                            {item.cantidad}
                          </span>
                          <button
                            onClick={() => handleCantidadChange(item.productoId, 1)}
                            disabled={item.cantidad >= stockDisponible}
                            className="p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 rounded-r-lg"
                          >
                            <Plus className="w-4 h-4" />
                          </button>
                        </div>

                        {/* Subtotal */}
                        <span className="font-semibold text-blue-600 min-w-[80px] text-right">
                          {formatPrecio(item.cantidad * precioResuelto)}
                        </span>

                        {/* Eliminar */}
                        <button
                          onClick={() => handleEliminarItem(item.productoId)}
                          className="p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    </div>
                  );
                })
              )}

              {/* Bonificaciones recalculadas (read-only) */}
              {bonificacionesCalculadas.map(bonif => (
                <div
                  key={`bonif-${bonif.productoId}-${bonif.promocionId ?? 'anon'}`}
                  className="p-3 flex items-center justify-between bg-green-50 dark:bg-green-900/20"
                >
                  <div className="flex items-center gap-2 flex-1">
                    <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />
                    <div>
                      <p className="font-medium text-sm dark:text-white">{bonif.nombre}</p>
                      <p className="text-xs text-green-600 font-medium">
                        REGALO x{bonif.cantidad}
                        {bonif.promoNombre ? ` · ${bonif.promoNombre}` : ''}
                      </p>
                    </div>
                  </div>
                  <span className="text-sm font-bold text-green-600">$0</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Regalos persistidos del pedido — solo para admin/encargado, para
            sustituir el producto del regalo (mig 058). No se muestra si no hay
            regalos persistidos o si el usuario no tiene permiso. */}
        {canSustituirRegalo && regalosPersistidos.length > 0 && !pedidoEntregado && (
          <div className="border dark:border-gray-700 rounded-lg overflow-hidden">
            <div className="bg-gray-50 dark:bg-gray-700/50 px-3 py-2 border-b dark:border-gray-700">
              <p className="text-sm font-medium text-gray-700 dark:text-gray-300 flex items-center gap-1.5">
                <Gift className="w-4 h-4 text-emerald-600" />
                Regalos del pedido (sustituibles)
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                Cambiar el producto de un regalo deja audit trail y maneja el stock segun el modo de la promo.
              </p>
            </div>
            <div className="divide-y dark:divide-gray-700">
              {regalosPersistidos.map(regalo => (
                <div
                  key={`regalo-real-${regalo.id}`}
                  className="p-3 flex items-center justify-between bg-emerald-50/40 dark:bg-emerald-900/10"
                >
                  <div className="flex items-center gap-2 flex-1 min-w-0">
                    <Gift className="w-4 h-4 text-emerald-600 flex-shrink-0" />
                    <div className="min-w-0">
                      <p className="font-medium text-sm dark:text-white truncate">
                        {regalo.producto?.nombre || `Producto #${regalo.producto_id}`}
                      </p>
                      <p className="text-xs text-emerald-700 dark:text-emerald-300 font-medium">
                        REGALO x{regalo.cantidad}
                        {regalo.promocion_id ? ` · promo #${regalo.promocion_id}` : ''}
                      </p>
                    </div>
                  </div>
                  <button
                    onClick={() => setSustItemTarget(regalo)}
                    className="flex items-center gap-1 px-3 py-1.5 text-xs font-medium text-emerald-700 dark:text-emerald-300 hover:bg-emerald-100 dark:hover:bg-emerald-900/30 border border-emerald-300 dark:border-emerald-700 rounded-lg"
                  >
                    <RefreshCw className="w-3.5 h-3.5" />
                    Cambiar regalo
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Total del pedido */}
        <div className="bg-blue-50 dark:bg-blue-900/30 rounded-lg p-4 border border-blue-200 dark:border-blue-800">
          <div className="flex justify-between items-center">
            <span className="text-blue-700 dark:text-blue-300 font-medium">Total del Pedido</span>
            <div className="text-right">
              <span className="text-2xl font-bold text-blue-600 dark:text-blue-400">{formatPrecio(total)}</span>
              {itemsModificados && (
                <p className="text-xs text-blue-500">
                  Anterior: {formatPrecio(pedido?.total || 0)}
                </p>
              )}
            </div>
          </div>
        </div>

        {/* Fecha del pedido (solo admin/encargado) */}
        {puedeEditarFechas && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Fecha del Pedido</label>
            <input
              type="date"
              value={fecha}
              onChange={e => setFecha(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
          </div>
        )}

        {/* Fecha programada de entrega (puede editar fechas + pedido NO entregado) */}
        {puedeEditarFechas && !pedidoEntregado && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Fecha programada de entrega
            </label>
            <input
              type="date"
              value={fechaEntregaProgramada}
              onChange={e => setFechaEntregaProgramada(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            {fechaEntregaProgramada !== fechaEntregaProgramadaOriginal && (
              <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                Se actualizará la fecha estimada de entrega del pedido.
              </p>
            )}
          </div>
        )}

        {/* Fecha de entrega (admin/encargado + pedido entregado) - determina el día de rendición */}
        {puedeEditarFechas && pedidoEntregado && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Fecha de Entrega
              <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">(determina el día de rendición)</span>
            </label>
            <input
              type="date"
              value={fechaEntrega}
              onChange={e => setFechaEntrega(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            {fechaEntrega !== fechaEntregaOriginal && (
              <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                Cambiar esta fecha moverá el pedido a la rendición del día elegido. Si alguno de los días estaba controlado, su control se anulará.
              </p>
            )}
          </div>
        )}

        {/* Preventista asignado — solo admin puede reasignar. Util cuando un
            preventista tomo el pedido en persona pero no lo cargo en la app:
            admin lo carga y reasigna para que cuente en sus etiquetas/
            estadisticas/comisiones. El cambio persiste al instante (RPC
            atomico) y no espera al boton Guardar.

            Lo extraemos a sub-componente para que la query de preventistas
            solo se invoque cuando el campo es visible (necesita
            SucursalProvider en arbol; tests sin provider deben pasar). */}
        {puedeEditarPreventista && onCambiarPreventista && pedido && (
          <SelectorPreventistaPedido
            pedido={pedido}
            disabled={guardando || pedidoEntregado}
            onCambiar={onCambiarPreventista}
          />
        )}
        {puedeEditarPreventista && pedidoEntregado && (
          <p className="text-xs text-gray-500">El pedido ya fue entregado; el preventista no se puede cambiar.</p>
        )}

        {/* Notas */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Notas / Observaciones</label>
          <textarea
            value={notas}
            onChange={e => setNotas(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Observaciones importantes para la preparación del pedido..."
            rows={2}
          />
        </div>
      </div>

      {/* Error de stock */}
      {errorStock && (
        <div className="mx-4 mb-2 p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
          <p className="text-sm text-yellow-600 dark:text-yellow-400">{errorStock}</p>
        </div>
      )}

      {/* Error de validación */}
      {errorValidacion && (
        <div className="mx-4 mb-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
          <p className="text-sm text-red-600 dark:text-red-400">{errorValidacion}</p>
        </div>
      )}

      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cancelar
        </button>
        <button
          onClick={handleGuardar}
          disabled={guardando || (puedeEditarItems && !pedidoEntregado && items.length === 0)}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          {itemsModificados ? 'Guardar Todo' : 'Guardar'}
        </button>
      </div>
      <ModalConfirmacion config={confirmConfig} onClose={() => setConfirmConfig(null)} />

      {/* Modal de sustitucion de regalo (lazy) */}
      {sustItemTarget && sustItemTarget.producto && (
        <Suspense fallback={null}>
          {(() => {
            const info = sustItemTarget.promocion_id
              ? promoInfoMap.get(String(sustItemTarget.promocion_id))
              : null;
            return (
              <ModalSustituirRegalo
                pedidoItemId={sustItemTarget.id}
                productoOriginal={sustItemTarget.producto}
                cantidadOriginal={sustItemTarget.cantidad}
                regaloMueveStock={info?.mueveStock ?? true}
                ajusteProductoIdOriginal={info?.ajusteProductoId ?? null}
                onClose={() => setSustItemTarget(null)}
              />
            );
          })()}
        </Suspense>
      )}
    </ModalBase>
  );
});

export default ModalEditarPedido;

// =============================================================================
// SUB-COMPONENTE: selector de preventista del pedido (solo admin)
// =============================================================================

interface SelectorPreventistaPedidoProps {
  pedido: PedidoDB;
  disabled: boolean;
  onCambiar: (nuevoPreventistaId: string) => Promise<void>;
}

function SelectorPreventistaPedido({ pedido, disabled, onCambiar }: SelectorPreventistaPedidoProps) {
  const { data: preventistasAsignables = [] } = usePreventistasAsignablesQuery();
  const [saving, setSaving] = useState<boolean>(false);

  return (
    <div>
      <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
        <UserCheck className="w-4 h-4 text-blue-600" />
        Preventista asignado
      </label>
      <select
        value={pedido.usuario_id ?? ''}
        disabled={saving || disabled}
        onChange={async (e) => {
          const nuevo = e.target.value;
          if (!nuevo || nuevo === pedido.usuario_id) return;
          setSaving(true);
          try {
            await onCambiar(nuevo);
          } catch {
            // El caller notifica el error. Solo limpiamos el flag.
          } finally {
            setSaving(false);
          }
        }}
        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm disabled:opacity-50"
      >
        {/* Si el usuario_id actual no esta en la lista (preventista de otra
            sucursal, eliminado, etc), igual lo mostramos para no perder el
            contexto del pedido. */}
        {pedido.usuario_id && !preventistasAsignables.some(p => p.id === pedido.usuario_id) && (
          <option value={pedido.usuario_id}>(Actual — fuera de la lista)</option>
        )}
        {preventistasAsignables.map(p => (
          <option key={p.id} value={p.id}>{p.nombre}</option>
        ))}
      </select>
    </div>
  );
}
