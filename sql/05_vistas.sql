-- =====================================================================
-- SkyNest · 05_vistas.sql  (sección 4.4 del informe)
--
-- Vistas de usuario prometidas en el Hito 1 (1.5.2 y 2.3.17):
--   v_seguimiento_paquete     estado y vuelo de cada paquete (tracking)
--   v_peso_vuelo              peso total por vuelo vs carga útil (dato derivado)
--   v_historial_bateria       uso de cada batería por vuelo (dato derivado)
--   v_entregas_nest_distrito  entregas y tasa de éxito por nest, distrito y mes
--   v_retrasos_express        paquetes express entregados vs duración estimada
--   v_consumo_modelo_ruta     consumo de batería (pp de carga por km)
--   v_utilizacion_flota       vuelos y horas por drone y mes vs su modelo
--   v_alertas_temperatura     lecturas sobre 60 °C
--   v_licencias_por_vencer    licencias que vencen en 30 días y sus vuelos
-- y la función fn_rastrear_paquete(codigo) para clientes.
--
-- Requiere: 01_schema.sql       Uso: psql -d skynest_1k -f sql/05_vistas.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = reportes, skynest, public;
BEGIN;

-- ---------------------------------------------------------------------
-- Seguimiento de paquetes (consulta más frecuente del sistema)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_seguimiento_paquete AS
SELECT p.codigo_tracking,
       p.estado            AS estado_paquete,
       p.prioridad,
       d.nombre            AS distrito_destino,
       p.direccion_destino,
       p.fecha_registro,
       p.fecha_entrega,
       v.id_vuelo,
       v.estado            AS estado_vuelo,
       v.fecha_programada,
       v.despegue,
       v.aterrizaje,
       n.nombre            AS nest_origen,
       p.id_cliente
FROM paquete p
JOIN distrito d          ON d.ubigeo  = p.ubigeo_destino
LEFT JOIN vuelo v        ON v.id_vuelo = p.id_vuelo
LEFT JOIN ruta_vuelo r   ON r.id_ruta  = v.id_ruta
LEFT JOIN estacion_nest n ON n.id_nest = r.id_nest_origen;

-- Para el rol cliente: solo puede consultar un paquete si conoce su código
CREATE OR REPLACE FUNCTION fn_rastrear_paquete(p_codigo CHAR(12))
RETURNS TABLE (codigo_tracking CHAR(12), estado_paquete VARCHAR, distrito_destino VARCHAR,
               fecha_registro TIMESTAMP, fecha_entrega TIMESTAMP, estado_vuelo VARCHAR,
               despegue TIMESTAMP, aterrizaje TIMESTAMP)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = reportes, skynest, pg_temp AS $$
    SELECT codigo_tracking, estado_paquete, distrito_destino, fecha_registro, fecha_entrega,
           estado_vuelo, despegue, aterrizaje
    FROM v_seguimiento_paquete
    WHERE codigo_tracking = p_codigo;
$$;

-- ---------------------------------------------------------------------
-- Peso total por vuelo (no se almacena en vuelo: se deriva de paquete)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_peso_vuelo AS
SELECT v.id_vuelo,
       v.estado,
       m.fabricante || ' ' || m.nombre            AS modelo,
       count(p.id_paquete)                        AS n_paquetes,
       COALESCE(sum(p.peso_kg), 0)                AS peso_total_kg,
       m.carga_util_max_kg,
       round(100 * COALESCE(sum(p.peso_kg), 0) / m.carga_util_max_kg, 1) AS ocupacion_pct
FROM vuelo v
JOIN drone d        ON d.id_drone  = v.id_drone
JOIN modelo_drone m ON m.id_modelo = d.id_modelo
LEFT JOIN paquete p ON p.id_vuelo  = v.id_vuelo
GROUP BY v.id_vuelo, v.estado, m.fabricante, m.nombre, m.carga_util_max_kg;

-- ---------------------------------------------------------------------
-- Historial de uso de cada batería (no se almacena: se deriva de vuelo y telemetría)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_historial_bateria AS
SELECT b.id_bateria,
       b.numero_serie,
       v.id_vuelo,
       v.id_drone,
       v.despegue,
       v.aterrizaje,
       v.estado                 AS estado_vuelo,
       t.carga_inicial_pct,
       t.carga_final_pct,
       t.carga_inicial_pct - t.carga_final_pct AS consumo_pct,
       t.temp_max_c,
       t.n_lecturas
FROM bateria b
JOIN vuelo v ON v.id_bateria = b.id_bateria
LEFT JOIN LATERAL (
    SELECT max(carga_pct)     AS carga_inicial_pct,
           min(carga_pct)     AS carga_final_pct,
           max(temperatura_c) AS temp_max_c,
           count(*)           AS n_lecturas
    FROM telemetria_bateria tb
    WHERE tb.id_vuelo = v.id_vuelo
) t ON TRUE;

-- ---------------------------------------------------------------------
-- Entregas por nest de origen, distrito destino y mes
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_entregas_nest_distrito AS
SELECT n.nombre                                         AS nest_origen,
       d.nombre                                         AS distrito_destino,
       date_trunc('month', v.despegue)::date            AS mes,
       count(*)                                         AS paquetes,
       count(*) FILTER (WHERE p.estado = 'entregado')   AS entregados,
       round(100.0 * count(*) FILTER (WHERE p.estado = 'entregado') / count(*), 1) AS tasa_exito_pct,
       round(avg(EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_promedio_entrega
FROM paquete p
JOIN vuelo v          ON v.id_vuelo = p.id_vuelo
JOIN ruta_vuelo r     ON r.id_ruta  = v.id_ruta
JOIN estacion_nest n  ON n.id_nest  = r.id_nest_origen
JOIN distrito d       ON d.ubigeo   = p.ubigeo_destino
WHERE v.despegue IS NOT NULL
GROUP BY n.nombre, d.nombre, date_trunc('month', v.despegue);

-- ---------------------------------------------------------------------
-- Paquetes express entregados: tiempo real vs duración estimada de la ruta
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_retrasos_express AS
SELECT p.codigo_tracking,
       d.nombre                                                   AS distrito_destino,
       r.codigo                                                   AS ruta,
       r.duracion_est_min,
       round((EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_reales,
       round((EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60 - r.duracion_est_min)::numeric, 1) AS min_retraso
FROM paquete p
JOIN vuelo v      ON v.id_vuelo = p.id_vuelo
JOIN ruta_vuelo r ON r.id_ruta  = v.id_ruta
JOIN distrito d   ON d.ubigeo   = p.ubigeo_destino
WHERE p.prioridad = 'express' AND p.estado = 'entregado';

-- ---------------------------------------------------------------------
-- Consumo de batería por modelo y ruta (puntos porcentuales por km)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_consumo_modelo_ruta AS
SELECT m.fabricante || ' ' || m.nombre AS modelo,
       r.codigo                        AS ruta,
       count(*)                        AS vuelos,
       round(avg((h.carga_inicial_pct - h.carga_final_pct) / v.distancia_real_km), 2) AS pp_por_km
FROM v_historial_bateria h
JOIN vuelo v        ON v.id_vuelo  = h.id_vuelo
JOIN drone dr       ON dr.id_drone = v.id_drone
JOIN modelo_drone m ON m.id_modelo = dr.id_modelo
JOIN ruta_vuelo r   ON r.id_ruta   = v.id_ruta
WHERE v.estado = 'completado' AND h.n_lecturas >= 2
GROUP BY m.fabricante, m.nombre, r.codigo;

-- ---------------------------------------------------------------------
-- Utilización de la flota: vuelos y horas por drone y mes vs su modelo
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_utilizacion_flota AS
WITH por_drone AS (
    SELECT v.id_drone,
           date_trunc('month', v.despegue)::date AS mes,
           count(*) AS vuelos,
           sum(EXTRACT(EPOCH FROM (v.aterrizaje - v.despegue)) / 3600) AS horas
    FROM vuelo v
    WHERE v.estado IN ('completado', 'abortado')
    GROUP BY v.id_drone, date_trunc('month', v.despegue)
)
SELECT pd.mes,
       n.nombre                         AS nest,
       pd.id_drone,
       m.fabricante || ' ' || m.nombre  AS modelo,
       pd.vuelos,
       round(pd.horas::numeric, 2)      AS horas,
       round(avg(pd.horas) OVER (PARTITION BY d.id_modelo, pd.mes)::numeric, 2) AS horas_prom_modelo
FROM por_drone pd
JOIN drone d          ON d.id_drone  = pd.id_drone
JOIN modelo_drone m   ON m.id_modelo = d.id_modelo
JOIN estacion_nest n  ON n.id_nest   = d.id_nest_base;

-- ---------------------------------------------------------------------
-- Alertas de temperatura de baterías (> 60 °C)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_alertas_temperatura AS
SELECT t.marca_tiempo,
       t.temperatura_c,
       t.carga_pct,
       v.id_vuelo,
       v.id_bateria,
       b.numero_serie AS bateria_serie,
       v.id_drone,
       d.nombre       AS distrito_destino
FROM telemetria_bateria t
JOIN vuelo v      ON v.id_vuelo   = t.id_vuelo
JOIN bateria b    ON b.id_bateria = v.id_bateria
JOIN ruta_vuelo r ON r.id_ruta    = v.id_ruta
JOIN distrito d   ON d.ubigeo     = r.ubigeo_destino
WHERE t.temperatura_c > 60;

-- ---------------------------------------------------------------------
-- Operadores con licencia por vencer (30 días) y sus vuelos programados
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_licencias_por_vencer AS
SELECT o.id_operador,
       o.nombres || ' ' || o.apellidos AS operador,
       o.nro_licencia,
       o.venc_licencia,
       o.venc_licencia - current_date  AS dias_restantes,
       n.nombre                        AS nest,
       count(v.id_vuelo)               AS vuelos_programados
FROM operador o
JOIN estacion_nest n ON n.id_nest = o.id_nest
LEFT JOIN vuelo v    ON v.id_operador = o.id_operador AND v.estado = 'programado'
WHERE o.venc_licencia BETWEEN current_date AND current_date + 30
GROUP BY o.id_operador, o.nombres, o.apellidos, o.nro_licencia, o.venc_licencia, n.nombre;

COMMIT;

SELECT table_name AS vista FROM information_schema.views WHERE table_schema = 'reportes' ORDER BY 1;
