/**
 * Skip Links - Enlaces para saltar contenido
 *
 * Permite a usuarios de teclado y screen readers saltar directamente
 * al contenido principal, navegación, o acciones importantes.
 *
 * WCAG 2.1 - 2.4.1 Bypass Blocks (Level A)
 */
import { useCallback } from 'react'

const SKIP_TARGETS = [
  { id: 'main-content', label: 'Ir al contenido principal' },
  { id: 'main-navigation', label: 'Ir a la navegación' },
  { id: 'search-input', label: 'Ir a búsqueda' }
]

export function SkipLinks({ targets = SKIP_TARGETS }) {
  const handleClick = useCallback((e, targetId) => {
    e.preventDefault()

    const target = document.getElementById(targetId)
    if (target) {
      // Hacer el elemento focusable temporalmente si no lo es
      const originalTabIndex = target.getAttribute('tabindex')
      target.setAttribute('tabindex', '-1')
      target.focus()

      // Restaurar tabindex original después de un momento
      setTimeout(() => {
        if (originalTabIndex) {
          target.setAttribute('tabindex', originalTabIndex)
        } else {
          target.removeAttribute('tabindex')
        }
      }, 100)

      // Scroll suave al elemento
      target.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }, [])

  return (
    <nav
      aria-label="Enlaces de salto"
      className="skip-links"
    >
      {targets.map(({ id, label }) => (
        <a
          key={id}
          href={`#${id}`}
          onClick={(e) => handleClick(e, id)}
          className="skip-link"
        >
          {label}
        </a>
      ))}

      <style>{`
        .skip-links {
          position: absolute;
          top: 0;
          left: 0;
          z-index: 10000;
          display: flex;
          gap: 4px;
          padding: 4px;
        }

        .skip-link {
          position: absolute;
          transform: translateY(-150%);
          padding: 12px 16px;
          background: #1e40af;
          color: white;
          font-weight: 600;
          text-decoration: none;
          border-radius: 0 0 8px 8px;
          box-shadow: 0 2px 8px rgba(0,0,0,0.3);
          transition: transform 0.2s ease-in-out;
        }

        .skip-link:focus {
          transform: translateY(0);
          outline: 3px solid #fbbf24;
          outline-offset: 2px;
        }

        .skip-link:hover {
          background: #1e3a8a;
        }

        /* High contrast mode */
        @media (prefers-contrast: more) {
          .skip-link {
            background: black;
            border: 2px solid white;
          }
          .skip-link:focus {
            outline: 3px solid yellow;
          }
        }

        /* Reduced motion */
        @media (prefers-reduced-motion: reduce) {
          .skip-link {
            transition: none;
          }
        }
      `}</style>
    </nav>
  )
}

export default SkipLinks
