/* eslint-disable react-refresh/only-export-components */
import React, { createContext, useContext, useState, useCallback, useEffect } from 'react';
import { Check, X, AlertTriangle, Info, Bell, CheckCircle, Trash2 } from 'lucide-react';
import { getStorageItem, setStorageItem } from '../utils/storage';
import { formatTimeAgo } from '../utils/formatters';

const NotificationContext = createContext({});

/**
 * Proveedor unificado de notificaciones
 * Combina:
 * - Toasts temporales (aparecen abajo a la derecha, desaparecen solos)
 * - Notificaciones persistentes (se muestran en el centro de notificaciones)
 */
export function NotificationProvider({ children }) {
  // Toasts temporales
  const [toasts, setToasts] = useState([]);

  // Notificaciones persistentes
  const [notifications, setNotifications] = useState(() => {
    const saved = getStorageItem('notifications', []);
    return Array.isArray(saved) ? saved : [];
  });

  // Persistir notificaciones
  useEffect(() => {
    setStorageItem('notifications', notifications);
  }, [notifications]);

  // === TOASTS ===
  const addToast = useCallback((message, type = 'success', duration = 3000) => {
    const id = Date.now() + Math.random();
    setToasts(prev => [...prev, { id, message, type }]);

    if (duration > 0) {
      setTimeout(() => {
        setToasts(prev => prev.filter(t => t.id !== id));
      }, duration);
    }

    return id;
  }, []);

  const removeToast = useCallback((id) => {
    setToasts(prev => prev.filter(t => t.id !== id));
  }, []);

  // === NOTIFICACIONES PERSISTENTES ===
  const addNotification = useCallback((notification) => {
    const newNotification = {
      id: Date.now(),
      timestamp: new Date().toISOString(),
      read: false,
      ...notification
    };
    setNotifications(prev => [newNotification, ...prev].slice(0, 50)); // Máximo 50
  }, []);

  const markAsRead = useCallback((id) => {
    setNotifications(prev =>
      prev.map(n => n.id === id ? { ...n, read: true } : n)
    );
  }, []);

  const markAllAsRead = useCallback(() => {
    setNotifications(prev => prev.map(n => ({ ...n, read: true })));
  }, []);

  const removeNotification = useCallback((id) => {
    setNotifications(prev => prev.filter(n => n.id !== id));
  }, []);

  const clearAllNotifications = useCallback(() => {
    setNotifications([]);
  }, []);

  const unreadCount = notifications.filter(n => !n.read).length;

  // === MÉTODOS UNIFICADOS ===
  // Estos métodos muestran toast Y agregan notificación persistente
  const notify = useCallback((title, message, type = 'info', options = {}) => {
    const { persist = true, duration = 3000 } = options;

    // Siempre mostrar toast
    addToast(message || title, type, duration);

    // Opcionalmente agregar a notificaciones persistentes
    if (persist) {
      addNotification({ type, title, message });
    }
  }, [addToast, addNotification]);

  // Helpers de conveniencia
  const success = useCallback((message, options = {}) => {
    addToast(message, 'success', options.duration || 3000);
    if (options.persist) {
      addNotification({ type: 'success', title: 'Éxito', message });
    }
  }, [addToast, addNotification]);

  const error = useCallback((message, options = {}) => {
    addToast(message, 'error', options.duration || 5000);
    // Los errores se persisten por defecto
    if (options.persist !== false) {
      addNotification({ type: 'error', title: 'Error', message });
    }
  }, [addToast, addNotification]);

  const warning = useCallback((message, options = {}) => {
    addToast(message, 'warning', options.duration || 4000);
    if (options.persist) {
      addNotification({ type: 'warning', title: 'Advertencia', message });
    }
  }, [addToast, addNotification]);

  const info = useCallback((message, options = {}) => {
    addToast(message, 'info', options.duration || 3000);
    if (options.persist) {
      addNotification({ type: 'info', title: 'Información', message });
    }
  }, [addToast, addNotification]);

  const value = {
    // Toasts
    toasts,
    addToast,
    removeToast,
    // Notificaciones
    notifications,
    addNotification,
    markAsRead,
    markAllAsRead,
    removeNotification,
    clearAllNotifications,
    unreadCount,
    // Métodos unificados
    notify,
    success,
    error,
    warning,
    info
  };

  return (
    <NotificationContext.Provider value={value}>
      {children}
      <ToastContainer toasts={toasts} removeToast={removeToast} />
    </NotificationContext.Provider>
  );
}

export const useNotification = () => {
  const context = useContext(NotificationContext);
  if (!context) {
    throw new Error('useNotification debe usarse dentro de NotificationProvider');
  }
  return context;
};

// Alias para compatibilidad con código existente
export const useToast = useNotification;

// === COMPONENTES DE TOAST ===
function ToastContainer({ toasts, removeToast }) {
  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-4 right-4 z-[100] flex flex-col gap-2 max-w-sm">
      {toasts.map(toast => (
        <Toast key={toast.id} toast={toast} onClose={() => removeToast(toast.id)} />
      ))}
    </div>
  );
}

function Toast({ toast, onClose }) {
  const [isExiting, setIsExiting] = useState(false);

  const handleClose = () => {
    setIsExiting(true);
    setTimeout(onClose, 200);
  };

  const config = {
    success: {
      bg: 'bg-green-50 border-green-200 dark:bg-green-900/30 dark:border-green-800',
      icon: <Check className="w-5 h-5 text-green-600 dark:text-green-400" />,
      text: 'text-green-800 dark:text-green-200'
    },
    error: {
      bg: 'bg-red-50 border-red-200 dark:bg-red-900/30 dark:border-red-800',
      icon: <X className="w-5 h-5 text-red-600 dark:text-red-400" />,
      text: 'text-red-800 dark:text-red-200'
    },
    warning: {
      bg: 'bg-yellow-50 border-yellow-200 dark:bg-yellow-900/30 dark:border-yellow-800',
      icon: <AlertTriangle className="w-5 h-5 text-yellow-600 dark:text-yellow-400" />,
      text: 'text-yellow-800 dark:text-yellow-200'
    },
    info: {
      bg: 'bg-blue-50 border-blue-200 dark:bg-blue-900/30 dark:border-blue-800',
      icon: <Info className="w-5 h-5 text-blue-600 dark:text-blue-400" />,
      text: 'text-blue-800 dark:text-blue-200'
    }
  };

  const { bg, icon, text } = config[toast.type] || config.info;

  return (
    <div
      className={`flex items-center gap-3 px-4 py-3 rounded-lg border shadow-lg transition-all duration-200 ${bg} ${
        isExiting ? 'opacity-0 translate-x-4' : 'opacity-100 translate-x-0 animate-slide-in'
      }`}
    >
      {icon}
      <p className={`flex-1 text-sm font-medium ${text}`}>{toast.message}</p>
      <button onClick={handleClose} className="p-1 hover:bg-black/5 dark:hover:bg-white/10 rounded">
        <X className="w-4 h-4 text-gray-500 dark:text-gray-400" />
      </button>
    </div>
  );
}

// === COMPONENTE NOTIFICATION CENTER ===
const iconMap = {
  success: CheckCircle,
  error: AlertTriangle,
  warning: AlertTriangle,
  info: Info
};

const colorMap = {
  success: 'text-green-600 bg-green-100 dark:bg-green-900/30',
  error: 'text-red-600 bg-red-100 dark:bg-red-900/30',
  warning: 'text-amber-600 bg-amber-100 dark:bg-amber-900/30',
  info: 'text-blue-600 bg-blue-100 dark:bg-blue-900/30'
};

export function NotificationCenter() {
  const {
    notifications,
    markAsRead,
    markAllAsRead,
    removeNotification,
    clearAllNotifications,
    unreadCount
  } = useNotification();

  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = React.useRef(null);

  useEffect(() => {
    const handleClickOutside = (event) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target)) {
        setIsOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="relative p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
        aria-label={`Notificaciones${unreadCount > 0 ? ` (${unreadCount} sin leer)` : ''}`}
        aria-expanded={isOpen}
      >
        <Bell className="w-5 h-5 text-gray-600 dark:text-gray-300" />
        {unreadCount > 0 && (
          <span className="absolute -top-1 -right-1 w-5 h-5 bg-red-500 text-white text-xs rounded-full flex items-center justify-center animate-pulse">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {isOpen && (
        <div className="absolute right-0 mt-2 w-80 sm:w-96 bg-white dark:bg-gray-800 rounded-xl shadow-xl border dark:border-gray-700 z-50 overflow-hidden">
          {/* Header */}
          <div className="flex items-center justify-between px-4 py-3 border-b dark:border-gray-700 bg-gray-50 dark:bg-gray-700/50">
            <h3 className="font-semibold text-gray-800 dark:text-white">Notificaciones</h3>
            <div className="flex items-center space-x-2">
              {unreadCount > 0 && (
                <button
                  onClick={markAllAsRead}
                  className="text-xs text-blue-600 hover:underline"
                >
                  Marcar todas leídas
                </button>
              )}
              {notifications.length > 0 && (
                <button
                  onClick={clearAllNotifications}
                  className="p-1 text-gray-400 hover:text-red-500 transition-colors"
                  title="Limpiar todas"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              )}
            </div>
          </div>

          {/* Lista */}
          <div className="max-h-96 overflow-y-auto">
            {notifications.length === 0 ? (
              <div className="py-12 text-center text-gray-500 dark:text-gray-400">
                <Bell className="w-12 h-12 mx-auto mb-3 opacity-30" />
                <p>No hay notificaciones</p>
              </div>
            ) : (
              <ul className="divide-y dark:divide-gray-700">
                {notifications.map(notification => {
                  const Icon = iconMap[notification.type] || Info;
                  return (
                    <li
                      key={notification.id}
                      className={`px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors ${
                        !notification.read ? 'bg-blue-50/50 dark:bg-blue-900/10' : ''
                      }`}
                    >
                      <div className="flex items-start space-x-3">
                        <div className={`p-2 rounded-lg ${colorMap[notification.type] || colorMap.info}`}>
                          <Icon className="w-4 h-4" />
                        </div>
                        <div className="flex-1 min-w-0">
                          <p className={`text-sm ${!notification.read ? 'font-medium' : ''} text-gray-800 dark:text-white`}>
                            {notification.title}
                          </p>
                          {notification.message && (
                            <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5 truncate">
                              {notification.message}
                            </p>
                          )}
                          <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">
                            {formatTimeAgo(notification.timestamp)}
                          </p>
                        </div>
                        <div className="flex items-center space-x-1">
                          {!notification.read && (
                            <button
                              onClick={() => markAsRead(notification.id)}
                              className="p-1 text-gray-400 hover:text-blue-500 transition-colors"
                              title="Marcar como leída"
                            >
                              <Check className="w-4 h-4" />
                            </button>
                          )}
                          <button
                            onClick={() => removeNotification(notification.id)}
                            className="p-1 text-gray-400 hover:text-red-500 transition-colors"
                            title="Eliminar"
                          >
                            <X className="w-4 h-4" />
                          </button>
                        </div>
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
