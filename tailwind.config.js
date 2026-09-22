import colors from 'tailwindcss/colors'
import defaultTheme from 'tailwindcss/defaultTheme'

/* Color de marca del rediseño de UI (#698): petróleo alrededor de #0E5A75.
   Los primitivos nuevos (Button, Badge, IconBadge) nacen con `brand-*`, y
   `blue-*` —el azul de facto de la app, 1260 usos— se remapea a ESTA misma
   escala (#700), para que lo migrado y lo no migrado se vean iguales y para
   que el color de toda la app se pueda revertir en una línea.

   Reglas que salen de los contrastes medidos (WCAG, sobre blanco y sobre
   stone-800/900 para el modo oscuro):
   - Relleno de marca: `bg-brand-600` en claro Y en oscuro (blanco encima =
     7,67). No bajar a `brand-500` en oscuro: blanco encima da 4,87, justo AA,
     y 400 no llega (2,68).
   - Texto o ícono de marca sobre fondo oscuro: `dark:text-brand-300` (9,38
     sobre stone-900) o `brand-400` (6,51). `brand-600` sobre stone-900 da
     2,28: ilegible.
   - Fondos suaves (chips, tiles, selección): `brand-50` / `brand-100` con
     texto `brand-700` / `brand-800` (8,21 y 9,90 sobre 100). */
const brand = {
  50: '#F0F7FA',
  100: '#E3EEF3',
  200: '#C3DDE8',
  300: '#8FC6DA',
  400: '#57A8C6',
  500: '#227A99',
  600: '#0E5A75',
  700: '#0B4A61',
  800: '#0A3D50',
  900: '#0A3342',
  950: '#061F29',
}

/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        /* Un solo neutro (#699). La app venía con dos: `gray` (5462 usos) y
           `stone` (558, el "editorial cálido" de Pedidos, Clientes, Productos y
           Dashboard), y esa mezcla es lo que la partía en dos generaciones
           visuales. En vez de reescribir 5462 clases, `gray` pasa a tener los
           VALORES de `stone`: los nombres de clase no cambian, así que ni los
           tests que aseveran clases ni high-contrast.css se enteran, y
           revertirlo es una línea. Contraste medido paso a paso contra blanco:
           delta máximo 0,07; ninguna falla AA nueva. Efecto de segundo orden:
           `borderColor.DEFAULT` y `divideColor.DEFAULT` pasan a stone-200.
           Los hex escritos a mano fuera de Tailwind (inputs de index.css, splash
           de index.html, manifest, theme-color, popups de mapas) se
           sincronizaron en el mismo cambio. */
        gray: colors.stone,
        brand,
        /* Marca (#700): `blue-*` toma los valores de `brand`. Es el azul de facto
           de la app (botones, links, activo, anillo de foco, "en camino").
           Remapear en vez de renombrar: los nombres de clase no cambian, los
           tests que aseveran 'blue' y high-contrast.css siguen matcheando, y
           revertir el color de toda la app es esta línea. Arrastra, y se
           declara: el anillo de foco global (`ringColor.DEFAULT` sale de
           blue.500) y el `*:focus-visible` de index.css. Los hex de marca escritos a mano
           (theme-color, TileColor, mask-icon, splash, manifest, skip-links,
           marcadores y polilíneas de los mapas) se sincronizaron en el mismo
           cambio; las paletas de gráficos y de marcadores por preventista NO,
           porque son categorías de datos, no marca. */
        blue: brand,
        /* Familias gemelas (#712): la app usaba dos nombres para el mismo
           significado según quién escribió el componente ("Pendientes" era
           `amber` en el KPI y `yellow` en el badge; "Entregados", `emerald`
           en el KPI y `green` en el stepper; lo destructivo, `rose` o `red`).
           Mismo truco que `gray` y `blue`: el nombre de clase no cambia —ni los
           tests que aseveran 'yellow' ni high-contrast.css se enteran— y cada
           línea se revierte sola. Contraste de lo que se mueve, sobre blanco:
           yellow-600 → amber-600 sube de 2,94 a 3,19; rose-600 → red-600 sube
           de 4,70 a 4,83; emerald-600 → green-600 baja de 3,77 a 3,30 y
           emerald-700 → green-700 de 5,48 a 5,02 (sigue en AA). Los botones
           con texto blanco sobre emerald ya pasaron a `Button variant="success"`
           (green-700) en #707. */
        yellow: colors.amber,
        emerald: colors.green,
        rose: colors.red,
      },
      animation: {
        'slide-in': 'slide-in 0.2s ease-out',
        'fade-in': 'fade-in 0.2s ease-out',
        'fade-out': 'fade-out 0.15s ease-in',
        'scale-in': 'scale-in 0.2s ease-out',
        'fadeSlideIn': 'fadeSlideIn 0.3s ease-out',
        'card-in': 'card-in 0.35s cubic-bezier(0.22, 1, 0.36, 1)',
        'slide-up': 'slide-up 0.28s cubic-bezier(0.22, 1, 0.36, 1)',
        'slide-down': 'slide-down 0.22s cubic-bezier(0.55, 0, 0.55, 0.2)',
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
        /* Bottom sheet: sube desde el borde inferior. */
        'slide-up': {
          '0%': { transform: 'translateY(100%)' },
          '100%': { transform: 'translateY(0)' },
        },
        'slide-down': {
          '0%': { transform: 'translateY(0)' },
          '100%': { transform: 'translateY(100%)' },
        },
      },
      /* Tipografias auto-alojadas (WP-22, #701). Los @font-face viven en
         src/index.css: ahi esta el porque de escribirlos a mano y de cargar
         solo el subset latino. Los nombres son los que declaran los paquetes
         @fontsource-variable, con el sufijo "Variable" incluido.

         `display` cae a la pila de `sans` a proposito: mientras Bricolage no
         haya bajado (font-display: swap) o si un caracter se le escapa al
         subset latino, el titulo se dibuja con Plex y no con el Times del
         navegador. */
      fontFamily: {
        sans: ['IBM Plex Sans Variable', ...defaultTheme.fontFamily.sans],
        display: ['Bricolage Grotesque Variable', 'IBM Plex Sans Variable', ...defaultTheme.fontFamily.sans],
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
