import { ChevronLeft, ChevronRight } from 'lucide-react';

export interface PaginacionProps {
  paginaActual: number;
  totalPaginas: number;
  onPageChange: (page: number) => void;
  totalItems: number;
  itemsLabel?: string;
}

export default function Paginacion({
  paginaActual,
  totalPaginas,
  onPageChange,
  totalItems,
  itemsLabel = 'items'
}: PaginacionProps) {
  if (totalPaginas <= 1) return null;

  const getPageNumbers = () => {
    const pages = [];
    const maxVisible = 5;
    let start = Math.max(1, paginaActual - Math.floor(maxVisible / 2));
    let end = Math.min(totalPaginas, start + maxVisible - 1);

    if (end - start + 1 < maxVisible) {
      start = Math.max(1, end - maxVisible + 1);
    }

    for (let i = start; i <= end; i++) {
      pages.push(i);
    }
    return pages;
  };

  return (
    <div className="flex items-center justify-center space-x-2 mt-4">
      <button
        onClick={() => onPageChange(Math.max(1, paginaActual - 1))}
        disabled={paginaActual === 1}
        className="p-2 rounded-lg border hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        aria-label="Página anterior"
      >
        <ChevronLeft className="w-5 h-5" />
      </button>

      {getPageNumbers().map(num => (
        <button
          key={num}
          onClick={() => onPageChange(num)}
          className={`w-10 h-10 rounded-lg transition-colors ${
            paginaActual === num
              ? 'bg-blue-600 text-white'
              : 'border hover:bg-gray-100'
          }`}
        >
          {num}
        </button>
      ))}

      <button
        onClick={() => onPageChange(Math.min(totalPaginas, paginaActual + 1))}
        disabled={paginaActual === totalPaginas}
        className="p-2 rounded-lg border hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        aria-label="Página siguiente"
      >
        <ChevronRight className="w-5 h-5" />
      </button>

      <span className="text-sm text-gray-500 ml-4">
        {totalItems} {totalItems !== 1 ? itemsLabel : itemsLabel.replace(/s$/, '')}
      </span>
    </div>
  );
}
