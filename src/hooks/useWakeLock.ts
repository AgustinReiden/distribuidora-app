/**
 * useWakeLock — mantiene la pantalla encendida durante la navegación (Screen
 * Wake Lock API). En una PWA, si la pantalla se apaga el GPS deja de emitir y
 * la nav muere, así que esto es condición necesaria del modo navegación.
 *
 * Gotchas que maneja:
 *  - Se debe pedir desde un gesto y con el documento visible → `solicitar()` se
 *    llama dentro del tap de "Iniciar navegación".
 *  - El lock se suelta solo cada vez que la app pierde visibilidad (llamada,
 *    cambio de app, pantalla apagada) → se re-adquiere en `visibilitychange`.
 *  - Bajo ahorro de batería el request puede ser rechazado: se traga el error
 *    (la nav sigue, pero la pantalla podría apagarse).
 */
import { useCallback, useEffect, useRef, useState } from 'react';

interface WakeLockSentinelLike {
  released: boolean;
  release: () => Promise<void>;
  addEventListener: (type: string, listener: () => void) => void;
}
interface WakeLockNavigator {
  wakeLock?: { request: (type: 'screen') => Promise<WakeLockSentinelLike> };
}

export interface UseWakeLockReturn {
  /** Pide el lock y activa la re-adquisición. Llamar dentro de un gesto. */
  solicitar: () => void;
  /** Libera el lock y desactiva la re-adquisición. */
  liberar: () => void;
  soportado: boolean;
}

export function useWakeLock(): UseWakeLockReturn {
  const sentinelRef = useRef<WakeLockSentinelLike | null>(null);
  const activoRef = useRef<boolean>(false);
  // Ref al último `pedir` para que el listener 'release' lo invoque sin que
  // `pedir` se referencie a sí mismo (evita el TDZ del callback).
  const pedirRef = useRef<() => void>(() => {});
  const [soportado] = useState<boolean>(
    () => typeof navigator !== 'undefined' && 'wakeLock' in navigator,
  );

  const pedir = useCallback(async (): Promise<void> => {
    const nav = navigator as unknown as WakeLockNavigator;
    if (!nav.wakeLock) return;
    if (sentinelRef.current && !sentinelRef.current.released) return;
    if (typeof document !== 'undefined' && document.visibilityState !== 'visible') return;
    try {
      const sentinel = await nav.wakeLock.request('screen');
      sentinelRef.current = sentinel;
      // Si el sistema lo suelta solo (no por nosotros), intentar recuperarlo.
      sentinel.addEventListener('release', () => {
        if (activoRef.current && document.visibilityState === 'visible') {
          pedirRef.current();
        }
      });
    } catch {
      // ahorro de batería / no visible: la pantalla podría apagarse
    }
  }, []);

  useEffect(() => {
    pedirRef.current = () => { void pedir(); };
  }, [pedir]);

  const solicitar = useCallback((): void => {
    activoRef.current = true;
    void pedir();
  }, [pedir]);

  const liberar = useCallback((): void => {
    activoRef.current = false;
    const sentinel = sentinelRef.current;
    sentinelRef.current = null;
    if (sentinel && !sentinel.released) {
      void sentinel.release().catch(() => {});
    }
  }, []);

  // Re-adquirir al volver a primer plano; liberar al desmontar.
  useEffect(() => {
    const onVisibilidad = (): void => {
      if (activoRef.current && document.visibilityState === 'visible') {
        void pedir();
      }
    };
    document.addEventListener('visibilitychange', onVisibilidad);
    return () => {
      document.removeEventListener('visibilitychange', onVisibilidad);
      activoRef.current = false;
      const sentinel = sentinelRef.current;
      sentinelRef.current = null;
      if (sentinel && !sentinel.released) {
        void sentinel.release().catch(() => {});
      }
    };
  }, [pedir]);

  return { solicitar, liberar, soportado };
}
