/**
 * useNavegacionVoz — voz para la navegación in-app con Web Speech API
 * (speechSynthesis). Gratis y, en Android, offline una vez bajado el pack de
 * voz en español (clave para túneles/zonas muertas).
 *
 * Gotchas que maneja (validados para Android Chrome PWA):
 *  - Activación de usuario: `speak()` solo arranca si hubo un gesto. `prime()`
 *    se llama DENTRO del tap de "Iniciar navegación" para desbloquear la voz
 *    del resto de la sesión.
 *  - getVoices() viene vacío al principio: se reintenta en `voiceschanged`.
 *  - No existe voz es-AR garantizada: se elige por prefijo `es-*` (priorizando
 *    es-419/es-AR/es-US/es-MX > es-ES) y se prefiere `localService` (offline).
 *  - Las instrucciones se encolan: `cancel()` antes de cada `speak()`, con un
 *    pequeño delay para que Chrome no se coma la frase.
 */
import { useCallback, useEffect, useRef } from 'react';

function rankVoz(v: SpeechSynthesisVoice): number {
  const l = (v.lang || '').toLowerCase();
  let s = 0;
  if (l.startsWith('es-419') || l.startsWith('es-ar') || l.startsWith('es-us') || l.startsWith('es-mx')) {
    s += 4;
  } else if (l.startsWith('es-es')) {
    s += 1;
  } else if (l.startsWith('es')) {
    s += 2;
  }
  if (v.localService) s += 2; // preferir offline
  return s;
}

function elegirVoz(voces: SpeechSynthesisVoice[]): SpeechSynthesisVoice | null {
  const es = voces.filter(v => (v.lang || '').toLowerCase().startsWith('es'));
  if (es.length === 0) return null;
  return [...es].sort((a, b) => rankVoz(b) - rankVoz(a))[0];
}

export interface UseNavegacionVozReturn {
  /** Desbloquea la voz; llamar DENTRO del gesto de inicio. */
  prime: () => void;
  /** Dice una frase (no repite la última salvo `forzar`). */
  decir: (texto: string, opts?: { forzar?: boolean }) => void;
  /** Corta cualquier locución en curso. */
  callar: () => void;
  soportada: boolean;
}

export function useNavegacionVoz(): UseNavegacionVozReturn {
  const vozRef = useRef<SpeechSynthesisVoice | null>(null);
  const ultimoRef = useRef<string>('');
  const soportada = typeof window !== 'undefined' && 'speechSynthesis' in window;

  useEffect(() => {
    if (!soportada) return;
    const cargar = (): void => {
      const elegida = elegirVoz(window.speechSynthesis.getVoices());
      if (elegida) vozRef.current = elegida;
    };
    cargar();
    window.speechSynthesis.addEventListener('voiceschanged', cargar);
    return () => window.speechSynthesis.removeEventListener('voiceschanged', cargar);
  }, [soportada]);

  const prime = useCallback((): void => {
    if (!soportada) return;
    try {
      const u = new SpeechSynthesisUtterance(' ');
      u.volume = 0;
      u.lang = vozRef.current?.lang || 'es-419';
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(u);
    } catch {
      // sin voz; la nav funciona igual con el banner visual
    }
  }, [soportada]);

  const decir = useCallback((texto: string, opts?: { forzar?: boolean }): void => {
    if (!soportada || !texto) return;
    if (!opts?.forzar && texto === ultimoRef.current) return;
    ultimoRef.current = texto;
    try {
      window.speechSynthesis.cancel();
      const u = new SpeechSynthesisUtterance(texto);
      u.lang = vozRef.current?.lang || 'es-419';
      if (vozRef.current) u.voice = vozRef.current;
      u.rate = 1;
      u.pitch = 1;
      // Delay corto: en algunos Chrome, speak() inmediato tras cancel() se pierde.
      window.setTimeout(() => {
        try {
          window.speechSynthesis.speak(u);
        } catch {
          // ignore
        }
      }, 60);
    } catch {
      // ignore
    }
  }, [soportada]);

  const callar = useCallback((): void => {
    if (!soportada) return;
    try {
      window.speechSynthesis.cancel();
    } catch {
      // ignore
    }
    ultimoRef.current = '';
  }, [soportada]);

  return { prime, decir, callar, soportada };
}
