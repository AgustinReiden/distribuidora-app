/* eslint-disable react-refresh/only-export-components */
import React, { createContext, useContext, useState, useEffect, useCallback, ReactNode } from 'react';
import { getStorageItem, setStorageItem } from '../utils/storage';

export interface ThemeContextValue {
  // Estados
  darkMode: boolean;
  highContrast: boolean;
  reducedMotion: boolean;
  // Toggles
  toggleDarkMode: () => void;
  toggleHighContrast: () => void;
  toggleReducedMotion: () => void;
  // Setters directos
  setDarkMode: React.Dispatch<React.SetStateAction<boolean>>;
  setHighContrast: React.Dispatch<React.SetStateAction<boolean>>;
  setReducedMotion: React.Dispatch<React.SetStateAction<boolean>>;
  // Reset
  resetToSystemPreferences: () => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

interface ThemeProviderProps {
  children: ReactNode;
}

/**
 * Provider de tema con soporte para:
 * - Modo oscuro
 * - Alto contraste (WCAG AA)
 * - Movimiento reducido
 */
export function ThemeProvider({ children }: ThemeProviderProps) {
  // Estado de modo oscuro
  const [darkMode, setDarkMode] = useState<boolean>(() => {
    const saved = getStorageItem<boolean | null>('darkMode', null);
    if (saved !== null) return saved;
    if (typeof window !== 'undefined') {
      return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    return false;
  });

  // Estado de alto contraste
  const [highContrast, setHighContrast] = useState<boolean>(() => {
    const saved = getStorageItem<boolean | null>('highContrast', null);
    if (saved !== null) return saved;
    if (typeof window !== 'undefined') {
      return window.matchMedia('(prefers-contrast: more)').matches ||
             window.matchMedia('(-ms-high-contrast: active)').matches;
    }
    return false;
  });

  // Estado de movimiento reducido
  const [reducedMotion, setReducedMotion] = useState<boolean>(() => {
    const saved = getStorageItem<boolean | null>('reducedMotion', null);
    if (saved !== null) return saved;
    if (typeof window !== 'undefined') {
      return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    }
    return false;
  });

  // Aplicar clases al documento
  useEffect(() => {
    const root = document.documentElement;

    // Dark mode
    root.classList.toggle('dark', darkMode);
    setStorageItem('darkMode', darkMode);

    // High contrast
    root.classList.toggle('high-contrast', highContrast);
    setStorageItem('highContrast', highContrast);

    // Reduced motion
    root.classList.toggle('reduce-motion', reducedMotion);
    setStorageItem('reducedMotion', reducedMotion);

    // Meta theme-color para móviles
    const metaThemeColor = document.querySelector('meta[name="theme-color"]');
    if (metaThemeColor) {
      metaThemeColor.setAttribute('content', darkMode ? '#1f2937' : '#2563eb');
    }
  }, [darkMode, highContrast, reducedMotion]);

  // Escuchar cambios en preferencias del sistema
  useEffect(() => {
    const darkModeQuery = window.matchMedia('(prefers-color-scheme: dark)');
    const highContrastQuery = window.matchMedia('(prefers-contrast: more)');
    const reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');

    const handleDarkModeChange = (e: MediaQueryListEvent) => {
      // Solo actualizar si el usuario no ha establecido preferencia manual
      const savedDarkMode = getStorageItem<boolean | null>('darkMode', null);
      if (savedDarkMode === null) {
        setDarkMode(e.matches);
      }
    };

    const handleHighContrastChange = (e: MediaQueryListEvent) => {
      const savedHighContrast = getStorageItem<boolean | null>('highContrast', null);
      if (savedHighContrast === null) {
        setHighContrast(e.matches);
      }
    };

    const handleReducedMotionChange = (e: MediaQueryListEvent) => {
      const savedReducedMotion = getStorageItem<boolean | null>('reducedMotion', null);
      if (savedReducedMotion === null) {
        setReducedMotion(e.matches);
      }
    };

    darkModeQuery.addEventListener('change', handleDarkModeChange);
    highContrastQuery.addEventListener('change', handleHighContrastChange);
    reducedMotionQuery.addEventListener('change', handleReducedMotionChange);

    return () => {
      darkModeQuery.removeEventListener('change', handleDarkModeChange);
      highContrastQuery.removeEventListener('change', handleHighContrastChange);
      reducedMotionQuery.removeEventListener('change', handleReducedMotionChange);
    };
  }, []);

  // Toggles
  const toggleDarkMode = useCallback(() => {
    setDarkMode(prev => !prev);
  }, []);

  const toggleHighContrast = useCallback(() => {
    setHighContrast(prev => !prev);
  }, []);

  const toggleReducedMotion = useCallback(() => {
    setReducedMotion(prev => !prev);
  }, []);

  // Reset a preferencias del sistema
  const resetToSystemPreferences = useCallback(() => {
    localStorage.removeItem('darkMode');
    localStorage.removeItem('highContrast');
    localStorage.removeItem('reducedMotion');

    setDarkMode(window.matchMedia('(prefers-color-scheme: dark)').matches);
    setHighContrast(window.matchMedia('(prefers-contrast: more)').matches);
    setReducedMotion(window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }, []);

  const value: ThemeContextValue = {
    // Estados
    darkMode,
    highContrast,
    reducedMotion,
    // Toggles
    toggleDarkMode,
    toggleHighContrast,
    toggleReducedMotion,
    // Setters directos
    setDarkMode,
    setHighContrast,
    setReducedMotion,
    // Reset
    resetToSystemPreferences
  };

  return (
    <ThemeContext.Provider value={value}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme(): ThemeContextValue {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme debe usarse dentro de ThemeProvider');
  }
  return context;
}
