/**
 * Caracterización del selector de período del Dashboard (#880).
 *
 * Fija CÓMO SE COMPORTA hoy el bloque «Período» de la VistaDashboard REAL, para
 * poder cambiar por dentro cómo se dibuja (de botones y inputs a mano al primitivo
 * `PeriodPicker`) sin cambiar lo que hace. Se consulta sólo por rol y nombre
 * accesible (`getByRole('button', { name })`, `getByLabelText('Desde' | 'Hasta')`),
 * nunca por clase ni por id: el look es lo que se va a mover y no es contrato.
 *
 * El comportamiento que se fija, y que es el que sorprende:
 *  - «Personalizado» NO avisa al padre: sólo muestra los campos de fecha. El botón
 *    presionado sigue siendo el de `filtroPeriodo` hasta que el padre cambie la prop.
 *  - Escribir una fecha no avisa a nadie. Sólo «Aplicar» llama a `onCambiarPeriodo`
 *    con ('personalizado', desde, hasta), pasando `null` en la fecha vacía, y con las
 *    dos vacías no hace nada.
 *  - Elegir cualquier otro preset esconde las fechas y avisa con el id solo.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import VistaDashboard from '../VistaDashboard';
import {
  METRICAS_DASHBOARD,
  TOTAL_CLIENTES_DASHBOARD,
} from '../../../../dev/gallery/fixtures/dashboard';

const PRESETS = [
  'Hoy',
  'Última semana',
  'Este mes',
  'Este año',
  'Histórico',
  'Personalizado',
] as const;

function montar(filtroPeriodo = 'mes') {
  const onCambiarPeriodo = vi.fn();
  const user = userEvent.setup();
  render(
    <VistaDashboard
      metricas={METRICAS_DASHBOARD}
      loading={false}
      filtroPeriodo={filtroPeriodo}
      onCambiarPeriodo={onCambiarPeriodo}
      onRefetch={vi.fn()}
      onDescargarBackup={vi.fn(async () => {})}
      exportando={false}
      totalClientes={TOTAL_CLIENTES_DASHBOARD}
      isAdmin
    />,
  );
  return { onCambiarPeriodo, user };
}

const boton = (nombre: string) => screen.getByRole('button', { name: nombre });
const campoDesde = () => screen.queryByLabelText('Desde');
const campoHasta = () => screen.queryByLabelText('Hasta');
const aplicar = () => screen.queryByRole('button', { name: 'Aplicar' });

describe('VistaDashboard · selector de período (caracterización)', () => {
  describe('los presets', () => {
    it('muestra los 6 en este orden: Hoy, Última semana, Este mes, Este año, Histórico, Personalizado', () => {
      montar();
      const botones = PRESETS.map(boton);
      for (let i = 1; i < botones.length; i++) {
        // El anterior tiene que quedar ANTES en el documento.
        expect(
          botones[i - 1].compareDocumentPosition(botones[i]) & Node.DOCUMENT_POSITION_FOLLOWING,
          `«${PRESETS[i]}» tiene que ir después de «${PRESETS[i - 1]}»`,
        ).toBeTruthy();
      }
    });

    it('conserva el rótulo visible «Período»', () => {
      montar();
      expect(screen.getByText('Período', { exact: true })).toBeInTheDocument();
    });

    it('aria-pressed sigue a la prop filtroPeriodo: «mes» presiona sólo «Este mes»', () => {
      montar('mes');
      for (const nombre of PRESETS) {
        expect(boton(nombre), nombre).toHaveAttribute('aria-pressed', nombre === 'Este mes' ? 'true' : 'false');
      }
    });

    it('con otro filtroPeriodo se presiona el que corresponde («hoy» → «Hoy»)', () => {
      montar('hoy');
      for (const nombre of PRESETS) {
        expect(boton(nombre), nombre).toHaveAttribute('aria-pressed', nombre === 'Hoy' ? 'true' : 'false');
      }
    });

    it('con filtroPeriodo «personalizado» se presiona «Personalizado» (sin abrir las fechas)', () => {
      montar('personalizado');
      for (const nombre of PRESETS) {
        expect(boton(nombre), nombre).toHaveAttribute('aria-pressed', nombre === 'Personalizado' ? 'true' : 'false');
      }
      expect(campoDesde()).not.toBeInTheDocument();
      expect(campoHasta()).not.toBeInTheDocument();
    });
  });

  describe('elegir un preset que no es «Personalizado»', () => {
    it('llama a onCambiarPeriodo una vez con SÓLO ese id y no muestra campos de fecha', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Última semana'));
      expect(onCambiarPeriodo).toHaveBeenCalledTimes(1);
      expect(onCambiarPeriodo).toHaveBeenCalledWith('semana');
      expect(onCambiarPeriodo.mock.calls[0]).toHaveLength(1);
      expect(campoDesde()).not.toBeInTheDocument();
      expect(campoHasta()).not.toBeInTheDocument();
      expect(aplicar()).not.toBeInTheDocument();
    });

    it('cada preset avisa con su id: hoy, semana, mes, anio, historico', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Hoy'));
      await user.click(boton('Última semana'));
      await user.click(boton('Este mes'));
      await user.click(boton('Este año'));
      await user.click(boton('Histórico'));
      expect(onCambiarPeriodo.mock.calls).toEqual([['hoy'], ['semana'], ['mes'], ['anio'], ['historico']]);
    });
  });

  describe('«Personalizado»', () => {
    it('no llama a onCambiarPeriodo y muestra Desde, Hasta y Aplicar', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      expect(campoDesde()).not.toBeInTheDocument();
      expect(campoHasta()).not.toBeInTheDocument();
      expect(aplicar()).not.toBeInTheDocument();

      await user.click(boton('Personalizado'));

      expect(onCambiarPeriodo).not.toHaveBeenCalled();
      expect(screen.getByLabelText('Desde')).toBeInTheDocument();
      expect(screen.getByLabelText('Hasta')).toBeInTheDocument();
      expect(boton('Aplicar')).toBeInTheDocument();
    });

    it('el preset presionado sigue siendo el de filtroPeriodo: «Personalizado» no pasa a presionado', async () => {
      const { user } = montar('mes');
      await user.click(boton('Personalizado'));
      expect(boton('Este mes')).toHaveAttribute('aria-pressed', 'true');
      expect(boton('Personalizado')).toHaveAttribute('aria-pressed', 'false');
    });

    it('los campos de fecha empiezan vacíos', async () => {
      const { user } = montar('mes');
      await user.click(boton('Personalizado'));
      expect(screen.getByLabelText('Desde')).toHaveValue('');
      expect(screen.getByLabelText('Hasta')).toHaveValue('');
    });

    it('escribir fechas no llama a onCambiarPeriodo y los campos muestran lo escrito', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Personalizado'));
      await user.type(screen.getByLabelText('Desde'), '2026-09-01');
      await user.type(screen.getByLabelText('Hasta'), '2026-09-15');
      expect(screen.getByLabelText('Desde')).toHaveValue('2026-09-01');
      expect(screen.getByLabelText('Hasta')).toHaveValue('2026-09-15');
      expect(onCambiarPeriodo).not.toHaveBeenCalled();
    });

    it('«Aplicar» con las dos fechas llama a onCambiarPeriodo(\'personalizado\', desde, hasta)', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Personalizado'));
      await user.type(screen.getByLabelText('Desde'), '2026-09-01');
      await user.type(screen.getByLabelText('Hasta'), '2026-09-15');
      await user.click(boton('Aplicar'));
      expect(onCambiarPeriodo).toHaveBeenCalledTimes(1);
      expect(onCambiarPeriodo).toHaveBeenCalledWith('personalizado', '2026-09-01', '2026-09-15');
    });

    it('«Aplicar» con sólo «Desde» pasa null en «Hasta»', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Personalizado'));
      await user.type(screen.getByLabelText('Desde'), '2026-09-01');
      await user.click(boton('Aplicar'));
      expect(onCambiarPeriodo).toHaveBeenCalledTimes(1);
      expect(onCambiarPeriodo).toHaveBeenCalledWith('personalizado', '2026-09-01', null);
    });

    it('«Aplicar» con sólo «Hasta» pasa null en «Desde»', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Personalizado'));
      await user.type(screen.getByLabelText('Hasta'), '2026-09-15');
      await user.click(boton('Aplicar'));
      expect(onCambiarPeriodo).toHaveBeenCalledTimes(1);
      expect(onCambiarPeriodo).toHaveBeenCalledWith('personalizado', null, '2026-09-15');
    });

    it('«Aplicar» con las dos fechas vacías no llama a nada', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Personalizado'));
      await user.click(boton('Aplicar'));
      expect(onCambiarPeriodo).not.toHaveBeenCalled();
    });
  });

  describe('después de abrir «Personalizado»', () => {
    it('elegir otro preset esconde las fechas y llama a onCambiarPeriodo(id)', async () => {
      const { onCambiarPeriodo, user } = montar('mes');
      await user.click(boton('Personalizado'));
      expect(screen.getByLabelText('Desde')).toBeInTheDocument();

      await user.click(boton('Hoy'));

      expect(onCambiarPeriodo).toHaveBeenCalledTimes(1);
      expect(onCambiarPeriodo).toHaveBeenCalledWith('hoy');
      expect(campoDesde()).not.toBeInTheDocument();
      expect(campoHasta()).not.toBeInTheDocument();
      expect(aplicar()).not.toBeInTheDocument();
    });

    it('volver a «Personalizado» tras esconderlas muestra las fechas de nuevo', async () => {
      const { user } = montar('mes');
      await user.click(boton('Personalizado'));
      await user.click(boton('Hoy'));
      await user.click(boton('Personalizado'));
      expect(screen.getByLabelText('Desde')).toBeInTheDocument();
      expect(screen.getByLabelText('Hasta')).toBeInTheDocument();
      expect(boton('Aplicar')).toBeInTheDocument();
    });
  });
});
