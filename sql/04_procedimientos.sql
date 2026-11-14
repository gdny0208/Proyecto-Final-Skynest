-- =====================================================================
-- SkyNest · 04_procedimientos.sql  (sección 4.5 del informe)
--
-- Procedimientos que implementan el flujo de un envío (sección 1.4.2):
--   1. sp_registrar_cliente_persona / sp_registrar_cliente_empresa
--   2. sp_registrar_paquete      -> genera el código de tracking
--   3. sp_programar_vuelo        -> elige drone, batería, operador y permiso
--   4. sp_asignar_paquete        -> sube el paquete a un vuelo programado
--   5. sp_despegar_vuelo / sp_cerrar_vuelo / sp_cancelar_vuelo
--   6. sp_registrar_lectura      -> telemetría en vivo
--
-- Los procedimientos deciden; los triggers de 03_triggers.sql validan.
-- Uso: CALL sp_xxx(...);  los parámetros INOUT devuelven el id creado.
-- Requiere: 01, 02 (datos) y 03_triggers.sql
-- =====================================================================

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Registrar clientes: superclase + subclase en una sola transacción,
--    así se cumple la cobertura de la jerarquía (R16).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_cliente_persona(
    p_email VARCHAR, p_telefono VARCHAR, p_dni CHAR(8), p_nombres VARCHAR, p_apellidos VARCHAR,
    INOUT p_id_cliente INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cliente (email, telefono) VALUES (p_email, p_telefono)
    RETURNING id_cliente INTO p_id_cliente;
    INSERT INTO cliente_persona (id_cliente, dni, nombres, apellidos)
    VALUES (p_id_cliente, p_dni, p_nombres, p_apellidos);
END $$;

CREATE OR REPLACE PROCEDURE sp_registrar_cliente_empresa(
    p_email VARCHAR, p_telefono VARCHAR, p_ruc CHAR(11), p_razon_social VARCHAR, p_contacto VARCHAR,
    INOUT p_id_cliente INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cliente (email, telefono) VALUES (p_email, p_telefono)
    RETURNING id_cliente INTO p_id_cliente;
    INSERT INTO cliente_empresa (id_cliente, ruc, razon_social, contacto)
    VALUES (p_id_cliente, p_ruc, p_razon_social, p_contacto);
END $$;

-- ---------------------------------------------------------------------
-- 2. Registrar un paquete (estado 'registrado', sin vuelo).
--    Código de tracking: 'SKY' + id con 9 dígitos. Costo base:
--    S/ 8 + S/ 1 por kg + S/ 5 si es express.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_paquete(
    p_id_cliente INTEGER, p_ubigeo_destino CHAR(6), p_peso_kg NUMERIC,
    p_largo_cm NUMERIC, p_ancho_cm NUMERIC, p_alto_cm NUMERIC,
    p_prioridad VARCHAR, p_es_fragil BOOLEAN,
    p_destinatario VARCHAR, p_telefono VARCHAR, p_direccion VARCHAR,
    p_lat NUMERIC DEFAULT NULL, p_lon NUMERIC DEFAULT NULL,
    INOUT p_codigo_tracking CHAR(12) DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_id INTEGER := nextval(pg_get_serial_sequence('paquete', 'id_paquete'));
BEGIN
    p_codigo_tracking := 'SKY' || lpad(v_id::text, 9, '0');
    INSERT INTO paquete (id_paquete, codigo_tracking, id_cliente, ubigeo_destino, peso_kg,
                         largo_cm, ancho_cm, alto_cm, prioridad, es_fragil,
                         destinatario_nombre, destinatario_telefono, direccion_destino,
                         lat_destino, lon_destino, estado, costo_envio)
    VALUES (v_id, p_codigo_tracking, p_id_cliente, p_ubigeo_destino, p_peso_kg,
            p_largo_cm, p_ancho_cm, p_alto_cm, p_prioridad, p_es_fragil,
            p_destinatario, p_telefono, p_direccion, p_lat, p_lon, 'registrado',
            round(8 + p_peso_kg + CASE WHEN p_prioridad = 'express' THEN 5 ELSE 0 END, 2));
END $$;

-- ---------------------------------------------------------------------
-- 3. Programar un vuelo para una ruta y una hora (despacho).
--    Elige automáticamente:
--      - un drone DISPONIBLE del nest de origen, cuyo alcance cubra ida y
--        vuelta con 20 % de reserva y sin otro vuelo pendiente a menos de
--        40 min de esa hora (el de más carga útil si hay varios);
--      - una batería OPERATIVA del mismo tipo que usa ese modelo, sin otro
--        vuelo pendiente a menos de 40 min (la de mejor salud);
--      - un operador del nest con licencia vigente y autorización para el
--        modelo y el distrito destino;
--      - el permiso vigente si el distrito destino es restringido.
--    Si falta alguno, lanza un error explicando qué faltó.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_programar_vuelo(
    p_id_ruta INTEGER, p_fecha TIMESTAMP, p_tipo_operacion VARCHAR DEFAULT 'automatico',
    INOUT p_id_vuelo INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    r          RECORD;
    v_drone    INTEGER;
    v_modelo   INTEGER;
    v_bateria  INTEGER;
    v_operador INTEGER;
    v_permiso  INTEGER;
BEGIN
    SELECT rv.id_nest_origen, rv.ubigeo_destino, rv.distancia_km, d.zona_restringida
      INTO r
      FROM ruta_vuelo rv JOIN distrito d ON d.ubigeo = rv.ubigeo_destino
     WHERE rv.id_ruta = p_id_ruta AND rv.activa;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La ruta % no existe o está desactivada', p_id_ruta;
    END IF;

    -- drone
    SELECT dr.id_drone, dr.id_modelo INTO v_drone, v_modelo
      FROM drone dr JOIN modelo_drone m ON m.id_modelo = dr.id_modelo
     WHERE dr.id_nest_base = r.id_nest_origen
       AND dr.estado = 'disponible'
       AND 2 * r.distancia_km <= 0.8 * m.alcance_km
       AND NOT EXISTS (SELECT 1 FROM vuelo v
                        WHERE v.id_drone = dr.id_drone AND v.estado IN ('programado', 'en_curso')
                          AND v.fecha_programada BETWEEN p_fecha - interval '40 minutes' AND p_fecha + interval '40 minutes')
     ORDER BY m.carga_util_max_kg DESC, dr.horas_vuelo
     LIMIT 1;
    IF v_drone IS NULL THEN
        RAISE EXCEPTION 'No hay drone disponible en el nest % con alcance para la ruta %', r.id_nest_origen, p_id_ruta;
    END IF;

    -- batería: mismo tipo (química y capacidad) que las que ya usa ese modelo
    SELECT b.id_bateria INTO v_bateria
      FROM bateria b
     WHERE b.estado = 'operativa'
       AND (b.quimica, b.capacidad_mah) IN (
             SELECT b2.quimica, b2.capacidad_mah
               FROM vuelo v2 JOIN drone d2 ON d2.id_drone = v2.id_drone
               JOIN bateria b2 ON b2.id_bateria = v2.id_bateria
              WHERE d2.id_modelo = v_modelo LIMIT 1)
       AND NOT EXISTS (SELECT 1 FROM vuelo v
                        WHERE v.id_bateria = b.id_bateria AND v.estado IN ('programado', 'en_curso')
                          AND v.fecha_programada BETWEEN p_fecha - interval '40 minutes' AND p_fecha + interval '40 minutes')
     ORDER BY b.salud_pct DESC
     LIMIT 1;
    IF v_bateria IS NULL THEN
        RAISE EXCEPTION 'No hay batería operativa compatible con el modelo %', v_modelo;
    END IF;

    -- operador
    SELECT o.id_operador INTO v_operador
      FROM operador o
      JOIN autorizacion a ON a.id_operador = o.id_operador
     WHERE o.id_nest = r.id_nest_origen
       AND o.venc_licencia >= p_fecha::date
       AND a.id_modelo = v_modelo AND a.ubigeo = r.ubigeo_destino
       AND p_fecha::date BETWEEN a.fecha_emision AND a.fecha_vencimiento
     ORDER BY (SELECT count(*) FROM vuelo v WHERE v.id_operador = o.id_operador AND v.estado = 'programado')
     LIMIT 1;
    IF v_operador IS NULL THEN
        RAISE EXCEPTION 'No hay operador del nest % autorizado para el modelo % en el distrito %',
              r.id_nest_origen, v_modelo, r.ubigeo_destino;
    END IF;

    -- permiso (solo distritos restringidos)
    IF r.zona_restringida THEN
        SELECT id_permiso INTO v_permiso
          FROM permiso_vuelo
         WHERE ubigeo = r.ubigeo_destino AND estado = 'vigente'
           AND p_fecha::date BETWEEN fecha_emision AND fecha_vencimiento
         ORDER BY fecha_vencimiento DESC LIMIT 1;
        IF v_permiso IS NULL THEN
            RAISE EXCEPTION 'R9: el distrito % es restringido y no hay permiso vigente para el %',
                  r.ubigeo_destino, p_fecha::date;
        END IF;
    END IF;

    INSERT INTO vuelo (id_drone, id_bateria, id_ruta, id_operador, id_permiso,
                       fecha_programada, estado, tipo_operacion)
    VALUES (v_drone, v_bateria, p_id_ruta, v_operador, v_permiso, p_fecha, 'programado', p_tipo_operacion)
    RETURNING id_vuelo INTO p_id_vuelo;
END $$;

-- ---------------------------------------------------------------------
-- 4. Asignar un paquete registrado a un vuelo programado.
--    El trigger valida R14 (distrito) y R15 (peso).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_asignar_paquete(p_codigo_tracking CHAR(12), p_id_vuelo INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado VARCHAR;
BEGIN
    SELECT estado INTO v_estado FROM paquete WHERE codigo_tracking = p_codigo_tracking FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el paquete %', p_codigo_tracking;
    ELSIF v_estado <> 'registrado' THEN
        RAISE EXCEPTION 'El paquete % no se puede asignar: está %', p_codigo_tracking, v_estado;
    END IF;
    UPDATE paquete SET id_vuelo = p_id_vuelo, estado = 'asignado' WHERE codigo_tracking = p_codigo_tracking;
END $$;

-- ---------------------------------------------------------------------
-- 5. Ciclo de vida del vuelo. Los triggers de PARTE B actualizan
--    paquetes, drone y batería en cascada.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_despegar_vuelo(p_id_vuelo INTEGER, p_hora TIMESTAMP DEFAULT now())
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE vuelo SET estado = 'en_curso', despegue = p_hora WHERE id_vuelo = p_id_vuelo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el vuelo %', p_id_vuelo;
    END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_cerrar_vuelo(
    p_id_vuelo INTEGER, p_distancia_km NUMERIC, p_exitoso BOOLEAN DEFAULT TRUE,
    p_hora TIMESTAMP DEFAULT now())
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE vuelo
       SET estado = CASE WHEN p_exitoso THEN 'completado' ELSE 'abortado' END,
           aterrizaje = p_hora,
           distancia_real_km = p_distancia_km
     WHERE id_vuelo = p_id_vuelo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el vuelo %', p_id_vuelo;
    END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_cancelar_vuelo(p_id_vuelo INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE vuelo SET estado = 'cancelado' WHERE id_vuelo = p_id_vuelo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el vuelo %', p_id_vuelo;
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 6. Registrar una lectura de telemetría (usuario "sistema de telemetría").
--    El trigger valida que caiga dentro del vuelo (R17).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_registrar_lectura(
    p_id_vuelo INTEGER, p_voltaje NUMERIC, p_corriente NUMERIC, p_temperatura NUMERIC, p_carga NUMERIC,
    p_hora TIMESTAMP DEFAULT now())
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO telemetria_bateria (id_vuelo, marca_tiempo, voltaje_v, corriente_a, temperatura_c, carga_pct)
    VALUES (p_id_vuelo, p_hora, p_voltaje, p_corriente, p_temperatura, p_carga);
END $$;

COMMIT;

SELECT p.proname AS procedimiento, pg_get_function_identity_arguments(p.oid) AS parametros
FROM pg_proc p
WHERE p.prokind = 'p' AND p.pronamespace = 'public'::regnamespace
ORDER BY 1;
