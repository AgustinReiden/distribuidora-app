/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  darkMode: 'class',
  theme: {
    extend: {
      animation: {
        'slide-in': 'slide-in 0.2s ease-out',
        'fade-in': 'fade-in 0.2s ease-out',
        'fade-out': 'fade-out 0.15s ease-in',
        'scale-in': 'scale-in 0.2s ease-out',
        'fadeSlideIn': 'fadeSlideIn 0.3s ease-out',
        'card-in': 'card-in 0.35s cubic-bezier(0.22, 1, 0.36, 1)',
      },
      keyframes: {
        'slide-in': {
          '0%': { opacity: '0', transform: 'translateX(100%)' },
          '100%': { opacity: '1', transform: 'translateX(0)' },
        },
        'fade-in': {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        'fade-out': {
          '0%': { opacity: '1' },
          '100%': { opacity: '0' },
        },
        'scale-in': {
          '0%': { opacity: '0', transform: 'scale(0.95)' },
          '100%': { opacity: '1', transform: 'scale(1)' },
        },
        /* Fade + slide leve para el período del título cuando cambia */
        'fadeSlideIn': {
          '0%': { opacity: '0', transform: 'translateY(-3px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        /* Card entrance: fade desde abajo, leve scale */
        'card-in': {
          '0%': { opacity: '0', transform: 'translateY(6px) scale(0.99)' },
          '100%': { opacity: '1', transform: 'translateY(0) scale(1)' },
        },
      },
      /* Sombras cálidas (tinte stone en vez de gray puro) */
      boxShadow: {
        'warm': '0 1px 2px 0 rgb(120 113 108 / 0.06), 0 1px 3px 0 rgb(120 113 108 / 0.05)',
        'warm-md': '0 4px 6px -1px rgb(120 113 108 / 0.08), 0 2px 4px -2px rgb(120 113 108 / 0.06)',
        'warm-lg': '0 10px 15px -3px rgb(120 113 108 / 0.08), 0 4px 6px -4px rgb(120 113 108 / 0.04)',
      },
    },
  },
  plugins: [],
}
