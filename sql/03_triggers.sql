-- =====================================================================
-- SkyNest · 03_triggers.sql  (sección 4.6 del informe)
--
-- PARTE A. Validaciones: reglas que cruzan tablas, que no se pueden
--          expresar con PK/FK/CHECK. Restricciones (i)-(x) del Hito 1.
-- PARTE B. Automatizaciones: cambios de estado en cascada al despegar,
--          aterrizar, abortar o cancelar un vuelo; degradación de baterías.
--
-- Todas las validaciones lanzan ERRCODE 23514 (check_violation) con un
-- mensaje que nombra la regla. Se crean DESPUÉS de cargar los datos
-- (construir_bases.sh), así que validan las operaciones nuevas.
--
-- Requiere: 01_schema.sql      Uso: psql -d skynest_1k -f sql/03_triggers.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = skynest, reportes, public;
BEGIN;

-- Re-ejecutable: borra los triggers trg_* que ya existan
DO $$
DECLARE t RECORD;
BEGIN
    FOR t IN SELECT tgname, tgrelid::regclass AS tabla FROM pg_trigger
             WHERE NOT tgisinternal AND tgname LIKE 'trg\_%' LOOP
        EXECUTE format('DROP TRIGGER %I ON %s', t.tgname, t.tabla);
    END LOOP;
END $$;

-- =====================================================================
-- PARTE A. VALIDACIONES
-- =====================================================================

-- ---------------------------------------------------------------------
-- (i) R16 Jerarquía de clientes: un cliente es persona o empresa, nunca ambas
--     (no solapamiento) y siempre una de las dos (cobertura).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cliente_no_solapa() RETURNS trigger AS $$
BEGIN
    IF TG_TABLE_NAME = 'cliente_persona'
       AND EXISTS (SELECT 1 FROM cliente_empresa WHERE id_cliente = NEW.id_cliente) THEN
        RAISE EXCEPTION 'R16: el cliente % ya está registrado como empresa', NEW.id_cliente
              USING ERRCODE = 'check_violation';
    ELSIF TG_TABLE_NAME = 'cliente_empresa'
       AND EXISTS (SELECT 1 FROM cliente_persona WHERE id_cliente = NEW.id_cliente) THEN
        RAISE EXCEPTION 'R16: el cliente % ya está registrado como persona', NEW.id_cliente
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cliente_persona_no_solapa
    BEFORE INSERT OR UPDATE OF id_cliente ON cliente_persona
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_no_solapa();
CREATE TRIGGER trg_cliente_empresa_no_solapa
    BEFORE INSERT OR UPDATE OF id_cliente ON cliente_empresa
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_no_solapa();

-- Cobertura: se revisa al final de la transacción (DEFERRED), porque primero
-- se inserta el cliente y luego su subclase.
CREATE OR REPLACE FUNCTION fn_cliente_cobertura() RETURNS trigger AS $$
DECLARE
    v_id INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_cliente ELSE NEW.id_cliente END;
BEGIN
    IF EXISTS (SELECT 1 FROM cliente WHERE id_cliente = v_id)
       AND NOT EXISTS (SELECT 1 FROM cliente_persona WHERE id_cliente = v_id)
       AND NOT EXISTS (SELECT 1 FROM cliente_empresa WHERE id_cliente = v_id) THEN
        RAISE EXCEPTION 'R16: el cliente % debe ser persona o empresa', v_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_cliente_cobertura
    AFTER INSERT ON cliente DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_cobertura();
CREATE CONSTRAINT TRIGGER trg_cliente_persona_cobertura
    AFTER DELETE ON cliente_persona DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_cobertura();
CREATE CONSTRAINT TRIGGER trg_cliente_empresa_cobertura
    AFTER DELETE ON cliente_empresa DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_cobertura();

-- ---------------------------------------------------------------------
-- Paquete: (ii) R15 peso total del vuelo <= carga útil del modelo
--          (v)  R14 distrito del paquete = distrito destino de la ruta
--          y solo se puede asignar a un vuelo que aún no despega
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_paquete_validar() RETURNS trigger AS $$
DECLARE
    v_carga      NUMERIC;
    v_destino    CHAR(6);
    v_estado     VARCHAR;
    v_peso_otros NUMERIC;
BEGIN
    IF NEW.id_vuelo IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT m.carga_util_max_kg, r.ubigeo_destino, v.estado
      INTO v_carga, v_destino, v_estado
      FROM vuelo v
      JOIN drone d        ON d.id_drone  = v.id_drone
      JOIN modelo_drone m ON m.id_modelo = d.id_modelo
      JOIN ruta_vuelo r   ON r.id_ruta   = v.id_ruta
     WHERE v.id_vuelo = NEW.id_vuelo;

    -- Asignar a otro vuelo solo si ese vuelo está programado
    IF (TG_OP = 'INSERT' OR NEW.id_vuelo IS DISTINCT FROM OLD.id_vuelo)
       AND v_estado <> 'programado' THEN
        RAISE EXCEPTION 'No se puede asignar el paquete al vuelo % porque está %', NEW.id_vuelo, v_estado
              USING ERRCODE = 'check_violation';
    END IF;

    -- (v) R14
    IF NEW.ubigeo_destino <> v_destino THEN
        RAISE EXCEPTION 'R14: el paquete va al distrito % pero la ruta del vuelo % llega a %',
              NEW.ubigeo_destino, NEW.id_vuelo, v_destino USING ERRCODE = 'check_violation';
    END IF;

    -- (ii) R15
    SELECT COALESCE(sum(peso_kg), 0) INTO v_peso_otros
      FROM paquete
     WHERE id_vuelo = NEW.id_vuelo AND id_paquete <> NEW.id_paquete;
    IF v_peso_otros + NEW.peso_kg > v_carga THEN
        RAISE EXCEPTION 'R15: el vuelo % llevaría % kg y la carga útil del modelo es % kg',
              NEW.id_vuelo, v_peso_otros + NEW.peso_kg, v_carga USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_paquete_validar
    BEFORE INSERT OR UPDATE OF id_vuelo, peso_kg, ubigeo_destino ON paquete
    FOR EACH ROW EXECUTE FUNCTION fn_paquete_validar();

-- ---------------------------------------------------------------------
-- Vuelo: (iii) R11 licencia y autorización vigentes
--        (iv)  R9  permiso vigente si el destino es restringido
--        (vi)  R10 nest del drone = nest de origen de la ruta; drone disponible
--        R12  batería operativa; ruta activa
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_vuelo_validar() RETURNS trigger AS $$
DECLARE
    d   RECORD;   -- drone
    r   RECORD;   -- ruta + distrito destino
    o   RECORD;   -- operador
    p   RECORD;   -- permiso
    v_fecha DATE := NEW.fecha_programada::date;
BEGIN
    SELECT id_nest_base, id_modelo, estado INTO d FROM drone WHERE id_drone = NEW.id_drone;
    SELECT rv.id_nest_origen, rv.ubigeo_destino, rv.activa, di.zona_restringida
      INTO r
      FROM ruta_vuelo rv JOIN distrito di ON di.ubigeo = rv.ubigeo_destino
     WHERE rv.id_ruta = NEW.id_ruta;
    SELECT venc_licencia INTO o FROM operador WHERE id_operador = NEW.id_operador;

    -- (vi) R10: el drone vuela desde su nest base
    IF d.id_nest_base <> r.id_nest_origen THEN
        RAISE EXCEPTION 'R10: el drone % tiene base en el nest % y la ruta % sale del nest %',
              NEW.id_drone, d.id_nest_base, NEW.id_ruta, r.id_nest_origen USING ERRCODE = 'check_violation';
    END IF;

    -- Al programar (INSERT): ruta activa, drone disponible y batería operativa
    IF TG_OP = 'INSERT' THEN
        IF NOT r.activa THEN
            RAISE EXCEPTION 'La ruta % está desactivada', NEW.id_ruta USING ERRCODE = 'check_violation';
        END IF;
        IF d.estado <> 'disponible' THEN
            RAISE EXCEPTION 'R10: el drone % no está disponible (estado: %)', NEW.id_drone, d.estado
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF TG_OP = 'INSERT' OR NEW.id_bateria IS DISTINCT FROM OLD.id_bateria THEN
        IF (SELECT estado FROM bateria WHERE id_bateria = NEW.id_bateria) <> 'operativa' THEN
            RAISE EXCEPTION 'R12: la batería % no está operativa', NEW.id_bateria
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- (iii) R11: licencia vigente y autorización (operador, modelo, distrito) vigente
    IF o.venc_licencia < v_fecha THEN
        RAISE EXCEPTION 'R11: la licencia del operador % vence el % (vuelo del %)',
              NEW.id_operador, o.venc_licencia, v_fecha USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM autorizacion a
                    WHERE a.id_operador = NEW.id_operador AND a.id_modelo = d.id_modelo
                      AND a.ubigeo = r.ubigeo_destino
                      AND v_fecha BETWEEN a.fecha_emision AND a.fecha_vencimiento) THEN
        RAISE EXCEPTION 'R11: el operador % no tiene autorización vigente para el modelo % en el distrito %',
              NEW.id_operador, d.id_modelo, r.ubigeo_destino USING ERRCODE = 'check_violation';
    END IF;

    -- (iv) R9: permiso vigente del mismo distrito si el destino es restringido
    IF r.zona_restringida THEN
        IF NEW.id_permiso IS NULL THEN
            RAISE EXCEPTION 'R9: el distrito % es restringido y el vuelo no tiene permiso', r.ubigeo_destino
                  USING ERRCODE = 'check_violation';
        END IF;
        SELECT ubigeo, estado, fecha_emision, fecha_vencimiento INTO p
          FROM permiso_vuelo WHERE id_permiso = NEW.id_permiso;
        IF p.ubigeo <> r.ubigeo_destino THEN
            RAISE EXCEPTION 'R9: el permiso % es del distrito %, no de %', NEW.id_permiso, p.ubigeo, r.ubigeo_destino
                  USING ERRCODE = 'check_violation';
        END IF;
        IF v_fecha NOT BETWEEN p.fecha_emision AND p.fecha_vencimiento
           OR (TG_OP = 'INSERT' AND p.estado <> 'vigente') THEN
            RAISE EXCEPTION 'R9: el permiso % no está vigente el % (estado: %, del % al %)',
                  NEW.id_permiso, v_fecha, p.estado, p.fecha_emision, p.fecha_vencimiento
                  USING ERRCODE = 'check_violation';
        END IF;
    ELSIF NEW.id_permiso IS NOT NULL THEN
        RAISE EXCEPTION 'R9: el distrito % no es restringido; el vuelo no lleva permiso', r.ubigeo_destino
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vuelo_validar
    BEFORE INSERT OR UPDATE OF id_drone, id_bateria, id_ruta, id_operador, id_permiso, fecha_programada ON vuelo
    FOR EACH ROW EXECUTE FUNCTION fn_vuelo_validar();

-- Transiciones de estado permitidas del vuelo:
--   programado -> en_curso | cancelado ;  en_curso -> completado | abortado
CREATE OR REPLACE FUNCTION fn_vuelo_transicion() RETURNS trigger AS $$
BEGIN
    IF NEW.estado = OLD.estado THEN
        RETURN NEW;
    END IF;
    IF NOT ((OLD.estado = 'programado' AND NEW.estado IN ('en_curso', 'cancelado'))
         OR (OLD.estado = 'en_curso'   AND NEW.estado IN ('completado', 'abortado'))) THEN
        RAISE EXCEPTION 'Transición de estado no permitida para el vuelo %: % -> %', NEW.id_vuelo, OLD.estado, NEW.estado
              USING ERRCODE = 'check_violation';
    END IF;
    -- completa los horarios si no se indicaron
    IF NEW.estado = 'en_curso' AND NEW.despegue IS NULL THEN
        NEW.despegue := now();
    ELSIF NEW.estado IN ('completado', 'abortado') AND NEW.aterrizaje IS NULL THEN
        NEW.aterrizaje := now();
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vuelo_transicion
    BEFORE UPDATE OF estado ON vuelo
    FOR EACH ROW EXECUTE FUNCTION fn_vuelo_transicion();

-- ---------------------------------------------------------------------
-- (viii) R17: la lectura de telemetría cae dentro del vuelo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_telemetria_validar() RETURNS trigger AS $$
DECLARE
    v RECORD;
BEGIN
    SELECT despegue, aterrizaje INTO v FROM vuelo WHERE id_vuelo = NEW.id_vuelo;
    IF v.despegue IS NULL OR NEW.marca_tiempo < v.despegue
       OR (v.aterrizaje IS NOT NULL AND NEW.marca_tiempo > v.aterrizaje) THEN
        RAISE EXCEPTION 'R17: la lectura % está fuera del vuelo % (% a %)',
              NEW.marca_tiempo, NEW.id_vuelo, v.despegue, v.aterrizaje USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_telemetria_validar
    BEFORE INSERT OR UPDATE OF id_vuelo, marca_tiempo ON telemetria_bateria
    FOR EACH ROW EXECUTE FUNCTION fn_telemetria_validar();

-- ---------------------------------------------------------------------
-- (ix) R2: un nest no supera su capacidad de drones
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_drone_capacidad_nest() RETURNS trigger AS $$
DECLARE
    v_cap  SMALLINT;
    v_hay  INTEGER;
BEGIN
    SELECT capacidad_drones INTO v_cap FROM estacion_nest WHERE id_nest = NEW.id_nest_base;
    SELECT count(*) INTO v_hay FROM drone
     WHERE id_nest_base = NEW.id_nest_base AND id_drone <> NEW.id_drone AND estado <> 'baja';
    IF NEW.estado <> 'baja' AND v_hay + 1 > v_cap THEN
        RAISE EXCEPTION 'R2: el nest % ya tiene % drones y su capacidad es %', NEW.id_nest_base, v_hay, v_cap
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_drone_capacidad_nest
    BEFORE INSERT OR UPDATE OF id_nest_base ON drone
    FOR EACH ROW EXECUTE FUNCTION fn_drone_capacidad_nest();

CREATE OR REPLACE FUNCTION fn_nest_capacidad() RETURNS trigger AS $$
DECLARE
    v_hay INTEGER;
BEGIN
    SELECT count(*) INTO v_hay FROM drone WHERE id_nest_base = NEW.id_nest AND estado <> 'baja';
    IF v_hay > NEW.capacidad_drones THEN
        RAISE EXCEPTION 'R2: el nest % tiene % drones; no se puede bajar su capacidad a %',
              NEW.id_nest, v_hay, NEW.capacidad_drones USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_nest_capacidad
    BEFORE UPDATE OF capacidad_drones ON estacion_nest
    FOR EACH ROW EXECUTE FUNCTION fn_nest_capacidad();

-- ---------------------------------------------------------------------
-- (x) R6: toda ruta tiene al menos 2 puntos (revisado al final de la transacción)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ruta_min_puntos() RETURNS trigger AS $$
DECLARE
    v_id INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_ruta ELSE NEW.id_ruta END;
BEGIN
    IF EXISTS (SELECT 1 FROM ruta_vuelo WHERE id_ruta = v_id)
       AND (SELECT count(*) FROM punto_ruta WHERE id_ruta = v_id) < 2 THEN
        RAISE EXCEPTION 'R6: la ruta % debe tener al menos 2 puntos (despegue y entrega)', v_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_ruta_min_puntos
    AFTER INSERT ON ruta_vuelo DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_ruta_min_puntos();
CREATE CONSTRAINT TRIGGER trg_punto_ruta_min_puntos
    AFTER DELETE ON punto_ruta DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_ruta_min_puntos();

-- R6: la altitud de cada punto y la de crucero no superan la altitud máxima
--     del distrito destino
CREATE OR REPLACE FUNCTION fn_altitud_ruta() RETURNS trigger AS $$
DECLARE
    v_max NUMERIC;
    v_alt NUMERIC;
BEGIN
    IF TG_TABLE_NAME = 'punto_ruta' THEN
        SELECT d.altitud_max_m INTO v_max
          FROM ruta_vuelo r JOIN distrito d ON d.ubigeo = r.ubigeo_destino WHERE r.id_ruta = NEW.id_ruta;
        v_alt := NEW.altitud_m;
    ELSE
        SELECT altitud_max_m INTO v_max FROM distrito WHERE ubigeo = NEW.ubigeo_destino;
        v_alt := NEW.altitud_crucero_m;
    END IF;
    IF v_alt > v_max THEN
        RAISE EXCEPTION 'R6: altitud % m supera la máxima del distrito destino (% m)', v_alt, v_max
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_punto_ruta_altitud
    BEFORE INSERT OR UPDATE OF altitud_m, id_ruta ON punto_ruta
    FOR EACH ROW EXECUTE FUNCTION fn_altitud_ruta();
CREATE TRIGGER trg_ruta_altitud
    BEFORE INSERT OR UPDATE OF altitud_crucero_m, ubigeo_destino ON ruta_vuelo
    FOR EACH ROW EXECUTE FUNCTION fn_altitud_ruta();

-- (vii) R12 batería sin vuelos solapados: ya lo garantiza el EXCLUDE
--       ex_vuelo_bateria_solape de 01_schema.sql.


-- =====================================================================
-- PARTE B. AUTOMATIZACIONES
-- =====================================================================

-- ---------------------------------------------------------------------
-- Cambio de estado del vuelo -> paquetes, drone y batería
--   en_curso   : paquetes asignado -> en_ruta;  drone -> en_vuelo
--   completado : paquetes en_ruta -> entregado (fecha_entrega = aterrizaje);
--                drone -> cargando y suma horas; batería +1 ciclo y pierde salud
--   abortado   : paquetes en_ruta -> fallido; drone -> mantenimiento y suma horas;
--                batería +1 ciclo
--   cancelado  : paquetes asignado -> registrado y sin vuelo; drone -> disponible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_vuelo_cambio_estado() RETURNS trigger AS $$
DECLARE
    v_horas NUMERIC;
BEGIN
    IF NEW.estado = OLD.estado THEN
        RETURN NULL;
    END IF;

    IF NEW.estado = 'en_curso' THEN
        UPDATE paquete SET estado = 'en_ruta'  WHERE id_vuelo = NEW.id_vuelo AND estado = 'asignado';
        UPDATE drone   SET estado = 'en_vuelo' WHERE id_drone = NEW.id_drone;

    ELSIF NEW.estado IN ('completado', 'abortado') THEN
        v_horas := EXTRACT(EPOCH FROM (NEW.aterrizaje - NEW.despegue)) / 3600.0;
        IF NEW.estado = 'completado' THEN
            UPDATE paquete SET estado = 'entregado', fecha_entrega = COALESCE(fecha_entrega, NEW.aterrizaje)
             WHERE id_vuelo = NEW.id_vuelo AND estado = 'en_ruta';
        ELSE
            UPDATE paquete SET estado = 'fallido' WHERE id_vuelo = NEW.id_vuelo AND estado = 'en_ruta';
        END IF;
        UPDATE drone
           SET horas_vuelo = horas_vuelo + v_horas,
               estado = CASE WHEN NEW.estado = 'completado' THEN 'cargando' ELSE 'mantenimiento' END
         WHERE id_drone = NEW.id_drone;
        -- cada vuelo es un ciclo de carga; la salud baja 0,02 puntos por ciclo
        UPDATE bateria
           SET ciclos_carga = ciclos_carga + 1,
               salud_pct = GREATEST(0, salud_pct - 0.02)
         WHERE id_bateria = NEW.id_bateria;

    ELSIF NEW.estado = 'cancelado' THEN
        UPDATE paquete SET estado = 'registrado', id_vuelo = NULL
         WHERE id_vuelo = NEW.id_vuelo AND estado = 'asignado';
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vuelo_cambio_estado
    AFTER UPDATE OF estado ON vuelo
    FOR EACH ROW EXECUTE FUNCTION fn_vuelo_cambio_estado();

-- ---------------------------------------------------------------------
-- R12: una batería con salud < 70 % pasa sola a 'degradada'
--      (así nunca choca con el CHECK ck_bateria_salud_estado)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_bateria_degradar() RETURNS trigger AS $$
BEGIN
    IF NEW.salud_pct < 70 AND NEW.estado = 'operativa' THEN
        NEW.estado := 'degradada';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bateria_degradar
    BEFORE INSERT OR UPDATE OF salud_pct, estado ON bateria
    FOR EACH ROW EXECUTE FUNCTION fn_bateria_degradar();

COMMIT;

-- Triggers creados
SELECT event_object_table AS tabla, trigger_name AS trigger, string_agg(event_manipulation, ', ') AS eventos
FROM information_schema.triggers
WHERE trigger_schema = 'public'
GROUP BY event_object_table, trigger_name
ORDER BY 1, 2;
