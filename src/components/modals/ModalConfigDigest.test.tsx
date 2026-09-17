/**
 * ModalConfigDigest: lo que el admin elige es lo que se guarda.
 *
 * El foco está en los bordes que la base rechaza con un CHECK — cero días,
 * cero secciones — y en que "no recibir" sea una salida explícita y no algo
 * que haya que simular dejando todo apagado.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import ModalConfigDigest from './ModalConfigDigest';
import type {
  BotDigestConfig,
  GuardarConfigDigestInput,
} from '../../hooks/queries/useBotDigestConfig';

const CONFIG_BASE: BotDigestConfig = {
  perfil_id: 'perfil-uno',
  perfil_nombre: 'Julio',
  telegram_user_id: 111,
  sucursal_id: 2,
  sucursal_nombre: 'Taco Pozo',
  configurado: false,
  activo: true,
  hora_local: 7,
  dias_semana: [1, 2, 3, 4, 5, 6, 7],
  secciones: ['ventas', 'top_clientes', 'stock_critico', 'deuda', 'vencimientos'],
  actualizado_at: null,
  actualizado_por: null,
};

function renderModal(config: Partial<BotDigestConfig> = {}) {
  const onGuardar = vi.fn(async (_input: GuardarConfigDigestInput) => {});
  const onClose = vi.fn();
  render(
    <ModalConfigDigest
      config={{ ...CONFIG_BASE, ...config }}
      onGuardar={onGuardar}
      onClose={onClose}
    />,
  );
  return { onGuardar, onClose };
}

describe('ModalConfigDigest', () => {
  it('avisa cuando la configuración es el default y no una elección', async () => {
    renderModal({ configurado: false });
    expect(screen.getByText(/todavía no tiene una configuración propia/i)).toBeInTheDocument();
  });

  it('no muestra ese aviso si ya la configuró', () => {
    renderModal({ configurado: true });
    expect(screen.queryByText(/todavía no tiene una configuración propia/i)).not.toBeInTheDocument();
  });

  it('guarda la hora, los días y las secciones que quedaron elegidos', async () => {
    const user = userEvent.setup();
    const { onGuardar, onClose } = renderModal();

    await user.selectOptions(screen.getByLabelText('Hora'), '19');
    // Apagamos sábado y domingo.
    await user.click(screen.getByRole('button', { name: 'sábado' }));
    await user.click(screen.getByRole('button', { name: 'domingo' }));
    // Y sumamos una sección que estaba apagada.
    await user.click(screen.getByRole('checkbox', { name: /Top productos/i }));

    await user.click(screen.getByRole('button', { name: 'Guardar' }));

    await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
    expect(onGuardar).toHaveBeenCalledWith({
      perfil_id: 'perfil-uno',
      activo: true,
      hora_local: 19,
      dias_semana: [1, 2, 3, 4, 5],
      secciones: [
        'deuda',
        'stock_critico',
        'top_clientes',
        'top_productos',
        'vencimientos',
        'ventas',
      ],
    });
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it('sin ningún día no deja guardar y dice por qué', async () => {
    const user = userEvent.setup();
    const { onGuardar } = renderModal({ dias_semana: [1] });

    await user.click(screen.getByRole('button', { name: 'lunes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/al menos un día/i);
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();
    expect(onGuardar).not.toHaveBeenCalled();
  });

  it('sin ninguna sección no deja guardar: un mensaje vacío no es una opción', async () => {
    const user = userEvent.setup();
    const { onGuardar } = renderModal({ secciones: ['ventas'] });

    await user.click(screen.getByRole('checkbox', { name: /Ventas del día/i }));

    expect(screen.getByRole('alert')).toHaveTextContent(/al menos una sección/i);
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();
    expect(onGuardar).not.toHaveBeenCalled();
  });

  it('"no recibir" guarda activo=false aunque no haya días ni secciones elegidos', async () => {
    const user = userEvent.setup();
    const { onGuardar } = renderModal({ secciones: ['ventas'] });

    await user.click(screen.getByRole('checkbox', { name: /Ventas del día/i }));
    // Con cero secciones el guardado estaba bloqueado…
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();

    // …y marcar "no recibir" lo destraba: es la forma explícita de bajarse.
    await user.click(screen.getByRole('checkbox', { name: /No recibir el resumen/i }));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Guardar' }));
    await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
    expect(onGuardar.mock.calls[0][0]).toMatchObject({ activo: false });
  });

  it('si falla el guardado el modal NO se cierra y muestra el error', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const onGuardar = vi.fn(async (_input: GuardarConfigDigestInput) => {
      throw new Error('El perfil no es un admin vinculado al bot');
    });
    render(
      <ModalConfigDigest config={CONFIG_BASE} onGuardar={onGuardar} onClose={onClose} />,
    );

    await user.click(screen.getByRole('button', { name: 'Guardar' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/no es un admin vinculado/i),
    );
    // Lo importante: no se pierde lo que acababa de tildar.
    expect(onClose).not.toHaveBeenCalled();
  });
});
