/* eslint-disable react-refresh/only-export-components */
import React, { useState, useRef, useEffect } from 'react';
import { Bell, X, Check, AlertTriangle, Info, CheckCircle, Trash2 } from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import { getStorageItem, setStorageItem } from '../../utils/storage';

// =============================================================================
// INTERFACES Y TIPOS
// =============================================================================

export type NotificationType = 'success' | 'error' | 'warning' | 'info';

export interface Notification {
  id: number;
  type: NotificationType;
  title: string;
  message?: string;
  timestamp: string;
  read: boolean;
}

export interface NotificationInput {
  type: NotificationType;
  title: string;
  message?: string;
}

export interface UseNotificationsReturn {
  notifications: Notification[];
  addNotification: (notification: NotificationInput) => void;
  markAsRead: (id: number) => void;
  markAllAsRead: () => void;
  removeNotification: (id: number) => void;
  clearAll: () => void;
  unreadCount: number;
}

export interface NotificationCenterProps {
  notifications: Notification[];
  onMarkAsRead: (id: number) => void;
  onMarkAllAsRead: () => void;
  onRemove: (id: number) => void;
  onClearAll: () => void;
  unreadCount: number;
}

// =============================================================================
// CONSTANTES
// =============================================================================

const iconMap: Record<NotificationType, LucideIcon> = {
  success: CheckCircle,
  error: AlertTriangle,
  warning: AlertTriangle,
  info: Info
};

const colorMap: Record<NotificationType, string> = {
  success: 'text-green-600 bg-green-100 dark:bg-green-900/30',
  error: 'text-red-600 bg-red-100 dark:bg-red-900/30',
  warning: 'text-amber-600 bg-amber-100 dark:bg-amber-900/30',
  info: 'text-blue-600 bg-blue-100 dark:bg-blue-900/30'
};

// =============================================================================
// HOOK: useNotifications
// =============================================================================

export function useNotifications(): UseNotificationsReturn {
  const [notifications, setNotifications] = useState<Notification[]>(() => {
    const saved = getStorageItem('notifications', []);
    // Validar que sea un array
    return Array.isArray(saved) ? saved : [];
  });

  useEffect(() => {
    setStorageItem('notifications', notifications);
  }, [notifications]);

  const addNotification = (notification: NotificationInput): void => {
    const newNotification: Notification = {
      id: Date.now(),
      timestamp: new Date().toISOString(),
      read: false,
      ...notification
    };
    setNotifications(prev => [newNotification, ...prev].slice(0, 50)); // Maximo 50
  };

  const markAsRead = (id: number): void => {
    setNotifications(prev =>
      prev.map(n => n.id === id ? { ...n, read: true } : n)
    );
  };

  const markAllAsRead = (): void => {
    setNotifications(prev => prev.map(n => ({ ...n, read: true })));
  };

  const removeNotification = (id: number): void => {
    setNotifications(prev => prev.filter(n => n.id !== id));
  };

  const clearAll = (): void => {
    setNotifications([]);
  };

  const unreadCount = notifications.filter(n => !n.read).length;

  return {
    notifications,
    addNotification,
    markAsRead,
    markAllAsRead,
    removeNotification,
    clearAll,
    unreadCount
  };
}

// =============================================================================
// UTILIDADES
// =============================================================================

function formatTimeAgo(timestamp: string): string {
  const now = new Date();
  const date = new Date(timestamp);
  const seconds = Math.floor((now.getTime() - date.getTime()) / 1000);

  if (seconds < 60) return 'Hace un momento';
  if (seconds < 3600) return `Hace ${Math.floor(seconds / 60)} min`;
  if (seconds < 86400) return `Hace ${Math.floor(seconds / 3600)} h`;
  return date.toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit' });
}

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

export default function NotificationCenter({
  notifications,
  onMarkAsRead,
  onMarkAllAsRead,
  onRemove,
  onClearAll,
  unreadCount
}: NotificationCenterProps): React.ReactElement {
  const [isOpen, setIsOpen] = useState<boolean>(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent): void => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const handleToggle = (): void => {
    setIsOpen(!isOpen);
  };

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        onClick={handleToggle}
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
                  onClick={onMarkAllAsRead}
                  className="text-xs text-blue-600 hover:underline"
                >
                  Marcar todas leidas
                </button>
              )}
              {notifications.length > 0 && (
                <button
                  onClick={onClearAll}
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
                              onClick={() => onMarkAsRead(notification.id)}
                              className="p-1 text-gray-400 hover:text-blue-500 transition-colors"
                              title="Marcar como leida"
                            >
                              <Check className="w-4 h-4" />
                            </button>
                          )}
                          <button
                            onClick={() => onRemove(notification.id)}
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
