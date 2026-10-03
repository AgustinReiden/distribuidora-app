import '@testing-library/jest-dom/vitest';
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import CargandoContenido from './CargandoContenido';
import { SkeletonTable } from './Skeleton';

describe('CargandoContenido', () => {
  it('es un role status con aria-live polite, sin aria-busy (callaria el aviso)', () => {
    render(<CargandoContenido><div>relleno</div></CargandoContenido>);
    const aviso = screen.getByRole('status');
    expect(aviso).toHaveAttribute('aria-live', 'polite');
    expect(aviso).not.toHaveAttribute('aria-busy');
    expect(aviso).toHaveAttribute('data-slot', 'cargando-contenido');
  });

  it('por defecto dice "Cargando...", igual que LoadingSpinner', () => {
    render(<CargandoContenido><div>relleno</div></CargandoContenido>);
    expect(screen.getByRole('status')).toHaveTextContent('Cargando...');
    expect(screen.getByText('Cargando...')).toBeInTheDocument();
  });

  it('el texto es solo para lectores de pantalla', () => {
    render(<CargandoContenido><div>relleno</div></CargandoContenido>);
    expect(screen.getByText('Cargando...')).toHaveClass('sr-only');
  });

  it('el texto se puede personalizar', () => {
    render(<CargandoContenido texto="Cargando pedidos..."><div>relleno</div></CargandoContenido>);
    expect(screen.getByRole('status')).toHaveTextContent('Cargando pedidos...');
    expect(screen.queryByText('Cargando...')).not.toBeInTheDocument();
  });

  it('los children van aria-hidden: no se leen ni aparecen en el arbol de accesibilidad', () => {
    render(
      <CargandoContenido>
        <SkeletonTable rows={2} columns={3} />
      </CargandoContenido>,
    );
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    expect(screen.getByRole('table', { hidden: true }).closest('[aria-hidden="true"]')).not.toBeNull();
    // El aviso solo contiene el texto: el skeleton no le suma nada al nombre.
    expect(screen.getByRole('status')).toHaveTextContent(/^Cargando\.\.\.$/);
  });
});
