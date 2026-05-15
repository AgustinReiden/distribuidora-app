/**
 * Deriva un label legible del filtro activo en el panel de Productos.
 *
 * Lo usa el header del panel de Productos para mostrar un título dinámico:
 *   "Productos" / "Productos con stock bajo" / "Productos de Manaos" /
 *   "Productos que coinciden con \"agua\"" / etc.
 *
 * Paralelo a `labelPeriodoPedidos` — mismo patrón de API y testing.
 *
 * Prioridad de filtros (de más específico a menos):
 *   1. `mostrarSoloStockBajo === true` → "con stock bajo"
 *   2. Combinación `categoria + busqueda` → "de {cat} que coinciden con \"X\""
 *   3. Solo `busqueda` → 'que coinciden con "X"'
 *   4. Solo `categoria` !== 'todas' → "de {cat}"
 *   5. Nada → null (el título queda solo "Productos")
 */

export interface LabelCategoriaInput {
  /** Texto de búsqueda actual (puede tener espacios o ser vacío). */
  busqueda: string;
  /** Categoría seleccionada. 'todas' significa "sin filtro de categoría". */
  categoriaSeleccionada: string;
  /** Toggle "Ver solo productos con stock bajo". */
  mostrarSoloStockBajo: boolean;
}

export interface LabelCategoriaProductos {
  /** Siempre 'Productos' por ahora. Reservado para extensión. */
  verbo: string;
  /** Período legible o null si no hay filtro activo. */
  periodo: string | null;
}

/**
 * Normaliza el nombre de la categoría para el título: convierte SCREAMING
 * a Title Case si todo está en mayúsculas (los nombres vienen así de la DB).
 *
 *   "MANAOS"          → "Manaos"
 *   "PAPAS FRITAS"    → "Papas Fritas"
 *   "Cepillo dientes" → "Cepillo dientes"  (deja como está si no es all-caps)
 */
function normalizarCategoria(cat: string): string {
  const trimmed = cat.trim();
  if (!trimmed) return trimmed;
  // Si está todo en mayúsculas, convertir a Title Case.
  if (trimmed === trimmed.toUpperCase()) {
    return trimmed
      .toLowerCase()
      .split(/(\s+)/)
      .map(p => p.length > 0 && /\S/.test(p) ? p.charAt(0).toUpperCase() + p.slice(1) : p)
      .join('');
  }
  return trimmed;
}

export function labelCategoriaProductos(input: LabelCategoriaInput): LabelCategoriaProductos {
  const busqueda = input.busqueda.trim();
  const cat = input.categoriaSeleccionada;
  const hayCategoria = Boolean(cat) && cat !== 'todas';
  const hayBusqueda = busqueda.length > 0;

  // --- Prioridad 1: stock bajo (filtro más operativo) ---
  if (input.mostrarSoloStockBajo) {
    return { verbo: 'Productos', periodo: 'con stock bajo' };
  }

  // --- Prioridad 2: combinación categoría + búsqueda ---
  if (hayCategoria && hayBusqueda) {
    return {
      verbo: 'Productos',
      periodo: `de ${normalizarCategoria(cat)} que coinciden con "${busqueda}"`,
    };
  }

  // --- Prioridad 3: solo búsqueda ---
  if (hayBusqueda) {
    return { verbo: 'Productos', periodo: `que coinciden con "${busqueda}"` };
  }

  // --- Prioridad 4: solo categoría ---
  if (hayCategoria) {
    return { verbo: 'Productos', periodo: `de ${normalizarCategoria(cat)}` };
  }

  // --- Default: sin filtros ---
  return { verbo: 'Productos', periodo: null };
}
