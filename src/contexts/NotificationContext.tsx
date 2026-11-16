/* eslint-disable react-refresh/only-export-components */
import React, { createContext, useContext, useState, useCallback, useEffect, useMemo, useRef, useSyncExternalStore, ReactNode } from 'react';
import { Check, X, AlertTriangle, Info } from 'lucide-react';
import {
  olvidarNotificacionesGuardadas,
  suscribirUsuarioNotificaciones,
  usuarioNotificaciones,
} from '../utils/notificacionesGuardadas';
import { setQueryErrorNotifier } from '../lib/queryErrorNotifier';

export type NotificationType = 'success' | 'error' | 'warning' | 'info';

export interface Toast {
  id: number;
  message: string;
  type: NotificationType;
  /** Se queda en pantalla hasta que el usuario lo cierra a mano (INF-1, #1600). */
  persist: boolean;
}

export interface NotifyOptions {
  /**
   * El aviso queda en pantalla hasta que el usuario lo cierra. Sólo para lo que
   * tiene que leer sí o sí: un error de guardado, algo que quedó a medias. Por
   * defecto nada persiste (tampoco los errores): se va solo.
   */
  persist?: boolean;
  duration?: number;
}

export interface NotificationContextValue {
  // Toasts
  toasts: Toast[];
  addToast: (message: string, type?: NotificationType, duration?: number, persist?: boolean) => number;
  removeToast: (id: number) => void;
  // Métodos unificados
  notify: (title: string, message?: string, type?: NotificationType, options?: NotifyOptions) => void;
  success: (message: string, options?: NotifyOptions) => void;
  error: (message: string, options?: NotifyOptions) => void;
  warning: (message: string, options?: NotifyOptions) => void;
  info: (message: string, options?: NotifyOptions) => void;
}

const NotificationContext = createContext<NotificationContextValue | null>(null);

interface NotificationProviderProps {
  children: ReactNode;
}

/**
 * Proveedor de avisos (toasts).
 *
 * Un aviso normal se va solo. Uno con `persist: true` queda en pantalla hasta que
 * el usuario lo cierra a mano (INF-1, #1600): el centro de notificaciones que los
 * guardaba se borró y nada los leía, así que «el pedido #N sí se guardó, no lo
 * cargues de nuevo» se veía 4 segundos y se perdía. No se repone ese centro.
 *
 * Un aviso idéntico (mismo texto y tipo) que ya está en pantalla no se duplica
 * (INF-2): renueva el que hay.
 */
export function NotificationProvider({ children }: NotificationProviderProps) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  // La fuente de verdad síncrona: addToast decide si el aviso ya existe sin
  // esperar al render, para que dos llamadas seguidas no dejen dos copias.
  const toastsRef = useRef<Toast[]>([]);
  const timersRef = useRef<Map<number, ReturnType<typeof setTimeout>>>(new Map());

  const commit = useCallback((next: Toast[]) => {
    toastsRef.current = next;
    setToasts(next);
  }, []);

  const clearTimer = useCallback((id: number) => {
    const t = timersRef.current.get(id);
    if (t !== undefined) {
      clearTimeout(t);
      timersRef.current.delete(id);
    }
  }, []);

  const removeToast = useCallback((id: number) => {
    clearTimer(id);
    commit(toastsRef.current.filter(t => t.id !== id));
  }, [clearTimer, commit]);

  const removeAllToasts = useCallback(() => {
    timersRef.current.forEach(t => clearTimeout(t));
    timersRef.current.clear();
    commit([]);
  }, [commit]);

  // Al desmontar no queda ningún timer vivo.
  useEffect(() => {
    const timers = timersRef.current;
    return () => {
      timers.forEach(t => clearTimeout(t));
      timers.clear();
    };
  }, []);

  // === TOASTS ===
  const addToast = useCallback((message: string, type: NotificationType = 'success', duration = 3000, persist = false): number => {
    const repetido = toastsRef.current.find(t => t.message === message && t.type === type);
    const id = repetido ? repetido.id : Date.now() + Math.random();
    const queda = persist || (repetido?.persist ?? false);

    if (repetido) {
      clearTimer(id);
      if (queda !== repetido.persist) {
        commit(toastsRef.current.map(t => (t.id === id ? { ...t, persist: queda } : t)));
      }
    } else {
      commit([...toastsRef.current, { id, message, type, persist: queda }]);
    }

    if (!queda && duration > 0) {
      timersRef.current.set(id, setTimeout(() => removeToast(id), duration));
    }

    return id;
  }, [clearTimer, commit, removeToast]);

  // Los avisos que quedan fijos pueden llevar montos y nombres de clientes: si
  // entra OTRO usuario en el mismo teléfono, no se los ve. El mismo usuario que
  // vuelve a entrar los conserva (el aviso de «quedan N operaciones sin
  // sincronizar» se emite justo antes de salir, para leerlo en el login).
  const usuarioId = useSyncExternalStore(suscribirUsuarioNotificaciones, usuarioNotificaciones, usuarioNotificaciones);
  const ultimoUsuarioRef = useRef<string | null>(usuarioId);
  useEffect(() => {
    if (!usuarioId) return;
    if (ultimoUsuarioRef.current && ultimoUsuarioRef.current !== usuarioId) removeAllToasts();
    ultimoUsuarioRef.current = usuarioId;
  }, [usuarioId, removeAllToasts]);

  // Las notificaciones que se guardaban en el teléfono (claves `notifications` y
  // `notifications:<usuario>`) ya no existen: se borran las que quedaron de antes.
  useEffect(() => {
    olvidarNotificacionesGuardadas();
  }, []);

  // === MÉTODOS UNIFICADOS ===
  const notify = useCallback((title: string, message?: string, type: NotificationType = 'info', options: NotifyOptions = {}) => {
    addToast(message || title, type, options.duration ?? 3000, options.persist === true);
  }, [addToast]);

  // Helpers de conveniencia
  const success = useCallback((message: string, options: NotifyOptions = {}) => {
    addToast(message, 'success', options.duration || 3000, options.persist === true);
  }, [addToast]);

  const error = useCallback((message: string, options: NotifyOptions = {}) => {
    addToast(message, 'error', options.duration || 5000, options.persist === true);
  }, [addToast]);

  const warning = useCallback((message: string, options: NotifyOptions = {}) => {
    addToast(message, 'warning', options.duration || 4000, options.persist === true);
  }, [addToast]);

  const info = useCallback((message: string, options: NotifyOptions = {}) => {
    addToast(message, 'info', options.duration || 3000, options.persist === true);
  }, [addToast]);

  // Registra `error()` para que `queryClient` (fuera de React) pueda avisar
  // de una query fallida. Se desregistra al desmontar para no llamar a un
  // `error` obsoleto tras un logout que remonte el provider.
  useEffect(() => {
    setQueryErrorNotifier(message => error(message));
    return () => setQueryErrorNotifier(null);
  }, [error]);

  // Memoizado a propósito: sin esto el value se recreaba en cada render y
  // cualquier efecto que dependiera de `useNotification()` volvía a dispararse.
  // Lo que rompió: el auto-sync offline dependía de `notify`, y cada
  // `notify.error` del propio sync lo re-lanzaba sin espera — los 5 reintentos
  // de un pedido encolado se consumían en segundos (ver useSyncManager).
  const value = useMemo<NotificationContextValue>(() => ({
    // Toasts
    toasts,
    addToast,
    removeToast,
    // Métodos unificados
    notify,
    success,
    error,
    warning,
    info
  }), [
    toasts,
    addToast,
    removeToast,
    notify,
    success,
    error,
    warning,
    info
  ]);

  return (
    <NotificationContext.Provider value={value}>
      {children}
      <ToastContainer toasts={toasts} removeToast={removeToast} removeAll={removeAllToasts} />
    </NotificationContext.Provider>
  );
}

export const useNotification = (): NotificationContextValue => {
  const context = useContext(NotificationContext);
  if (!context) {
    throw new Error('useNotification debe usarse dentro de NotificationProvider');
  }
  return context;
};

// Alias para compatibilidad con código existente
export const useToast = useNotification;

// === COMPONENTES DE TOAST ===
interface ToastContainerProps {
  toasts: Toast[];
  removeToast: (id: number) => void;
  removeAll: () => void;
}

function ToastContainer({ toasts, removeToast, removeAll }: ToastContainerProps) {
  if (toasts.length === 0) return null;

  // Por encima de la barra inferior del celular (WP-41): --bottom-nav-h vale 0
  // en escritorio y donde no hay barra (la ruta activa), así que ahí queda
  // igual que siempre. No lee --bottom-inset: en la ruta ese vale 10rem y los
  // toasts no tienen que subir por el FAB.
  //
  // `data-slot="avisos"` es el gancho de index.css para el celular con un
  // bottom sheet abierto (#852): ahí la pila pasa ARRIBA de la pantalla, porque
  // abajo a la derecha tapaba «Confirmar» del alta de pedido (el sheet es z-50 y
  // esta pila z-[100]). Es CSS puro, sin estado: no mover ni sacar el atributo
  // sin tocar esa regla (la fija src/styles/layoutVars.contract.test.ts).
  //
  // INF-1 (#1600): varios avisos que no se van solos no pueden cubrir el celular.
  // La pila topea en la mitad de la ventana y scrollea por dentro (`*:shrink-0`:
  // ningún aviso se achica para entrar), el ancho no pasa del de la pantalla, y con
  // dos avisos fijos o más aparece «Cerrar todos».
  const fijos = toasts.filter(t => t.persist).length;
  return (
    <div
      data-slot="avisos"
      role="region"
      aria-label="Avisos"
      className="fixed bottom-[calc(1rem+var(--bottom-nav-h))] right-4 z-[100] flex flex-col gap-2 max-w-[min(24rem,calc(100vw-2rem))] max-h-[50dvh] overflow-y-auto overscroll-contain *:shrink-0"
    >
      {fijos >= 2 && (
        <button
          type="button"
          onClick={removeAll}
          className="self-end rounded-md bg-gray-800 px-3 py-1.5 text-xs font-medium text-white shadow-lg hover:bg-gray-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-800 dark:bg-gray-200 dark:text-gray-900 dark:hover:bg-gray-300"
        >
          Cerrar todos los avisos
        </button>
      )}
      {toasts.map(toast => (
        <ToastItem key={toast.id} toast={toast} onClose={() => removeToast(toast.id)} />
      ))}
    </div>
  );
}

interface ToastItemProps {
  toast: Toast;
  onClose: () => void;
}

function ToastItem({ toast, onClose }: ToastItemProps) {
  const [isExiting, setIsExiting] = useState(false);

  const handleClose = () => {
    setIsExiting(true);
    setTimeout(onClose, 200);
  };

  const config: Record<NotificationType, { bg: string; icon: React.ReactNode; text: string }> = {
    success: {
      bg: 'bg-green-50 border-green-200 dark:bg-green-900/30 dark:border-green-800',
      icon: <Check aria-hidden="true" className="w-5 h-5 shrink-0 text-green-600 dark:text-green-400" />,
      text: 'text-green-800 dark:text-green-200'
    },
    error: {
      bg: 'bg-red-50 border-red-200 dark:bg-red-900/30 dark:border-red-800',
      icon: <X aria-hidden="true" className="w-5 h-5 shrink-0 text-red-600 dark:text-red-400" />,
      text: 'text-red-800 dark:text-red-200'
    },
    warning: {
      bg: 'bg-yellow-50 border-yellow-200 dark:bg-yellow-900/30 dark:border-yellow-800',
      icon: <AlertTriangle aria-hidden="true" className="w-5 h-5 shrink-0 text-yellow-600 dark:text-yellow-400" />,
      text: 'text-yellow-800 dark:text-yellow-200'
    },
    info: {
      bg: 'bg-blue-50 border-blue-200 dark:bg-blue-900/30 dark:border-blue-800',
      icon: <Info aria-hidden="true" className="w-5 h-5 shrink-0 text-blue-600 dark:text-blue-400" />,
      text: 'text-blue-800 dark:text-blue-200'
    }
  };

  const { bg, icon, text } = config[toast.type] || config.info;

  // Un error o una advertencia se anuncia en el acto (`alert`); el resto, con
  // cortesía (`status`).
  const urgente = toast.type === 'error' || toast.type === 'warning';

  return (
    <div
      role={urgente ? 'alert' : 'status'}
      data-persist={toast.persist ? 'true' : undefined}
      className={`flex items-center gap-3 px-4 py-3 rounded-lg border shadow-lg transition-all duration-200 ${bg} ${
        isExiting ? 'opacity-0 translate-x-4' : 'opacity-100 translate-x-0 animate-slide-in'
      }`}
    >
      {icon}
      <p className={`flex-1 text-sm font-medium ${text}`}>{toast.message}</p>
      <button
        type="button"
        onClick={handleClose}
        aria-label="Cerrar aviso"
        className="p-1 hover:bg-black/5 dark:hover:bg-white/10 rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-500"
      >
        <X aria-hidden="true" className="w-4 h-4 text-gray-500 dark:text-gray-400" />
      </button>
    </div>
  );
}
