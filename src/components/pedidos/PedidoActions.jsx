/**
 * Componente AccionesDropdown para pedidos
 * Menú desplegable con acciones disponibles para un pedido
 */
import React, { useState, useRef, useEffect, memo } from 'react';
import { MoreVertical, History, Edit2, Package, User, Check, AlertTriangle, Trash2 } from 'lucide-react';

function AccionesDropdown({
  pedido,
  isAdmin,
  isPreventista,
  isTransportista,
  onHistorial,
  onEditar,
  onPreparar,
  onAsignar,
  onEntregado,
  onRevertir,
  onEliminar
}) {
  const [abierto, setAbierto] = useState(false);
  const dropdownRef = useRef(null);

  useEffect(() => {
    const handleClickOutside = (event) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target)) {
        setAbierto(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const acciones = [];

  // Siempre visible
  acciones.push({
    label: 'Ver Historial',
    icon: History,
    onClick: () => onHistorial(pedido),
    color: 'text-gray-700'
  });

  // Admin o preventista pueden editar
  if (isAdmin || isPreventista) {
    acciones.push({
      label: 'Editar',
      icon: Edit2,
      onClick: () => onEditar(pedido),
      color: 'text-blue-700'
    });
  }

  // Admin puede preparar si está pendiente
  if (isAdmin && pedido.estado === 'pendiente') {
    acciones.push({
      label: 'Marcar en Preparación',
      icon: Package,
      onClick: () => onPreparar(pedido),
      color: 'text-orange-700'
    });
  }

  // Admin puede asignar si no está entregado
  if (isAdmin && pedido.estado !== 'entregado') {
    acciones.push({
      label: pedido.transportista ? 'Reasignar Transportista' : 'Asignar Transportista',
      icon: User,
      onClick: () => onAsignar(pedido),
      color: 'text-orange-700'
    });
  }

  // Transportista o admin pueden marcar entregado
  if ((isTransportista || isAdmin) && pedido.estado === 'asignado') {
    acciones.push({
      label: 'Marcar Entregado',
      icon: Check,
      onClick: () => onEntregado(pedido),
      color: 'text-green-700'
    });
  }

  // Admin puede revertir si está entregado
  if (isAdmin && pedido.estado === 'entregado') {
    acciones.push({
      label: 'Revertir Entrega',
      icon: AlertTriangle,
      onClick: () => onRevertir(pedido),
      color: 'text-yellow-700'
    });
  }

  // Admin puede eliminar
  if (isAdmin) {
    acciones.push({
      label: 'Eliminar',
      icon: Trash2,
      onClick: () => onEliminar(pedido.id),
      color: 'text-red-600',
      divider: true
    });
  }

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        onClick={() => setAbierto(!abierto)}
        className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
        aria-label="Más acciones"
      >
        <MoreVertical className="w-5 h-5 text-gray-600 dark:text-gray-300" />
      </button>

      {abierto && (
        <div className="absolute right-0 mt-2 w-56 bg-white dark:bg-gray-800 rounded-lg shadow-lg border dark:border-gray-700 z-50 py-1">
          {acciones.map((accion, idx) => (
            <React.Fragment key={idx}>
              {accion.divider && <div className="border-t dark:border-gray-700 my-1" />}
              <button
                onClick={() => { accion.onClick(); setAbierto(false); }}
                className={`w-full flex items-center space-x-2 px-4 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-700 ${accion.color} dark:text-gray-300`}
              >
                <accion.icon className="w-4 h-4" />
                <span>{accion.label}</span>
              </button>
            </React.Fragment>
          ))}
        </div>
      )}
    </div>
  );
}

export default memo(AccionesDropdown);
