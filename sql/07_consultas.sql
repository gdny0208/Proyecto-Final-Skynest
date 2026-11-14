-- =====================================================================
-- SkyNest · 07_consultas.sql  (sección 5.1 del informe)
--
-- Las 5 consultas intermedias del experimento, tomadas de la lista de
-- consultas esperadas del Hito 1 (sección 1.5.4):
--   C1  (#2) Tasa de entregas exitosas y tiempo promedio por nest y distrito
--   C2  (#3) Consumo de batería (pp de carga por km) por modelo y ruta
--   C3  (#4) Baterías con temperatura anómala y drones que las usaron
--   C4  (#5) Utilización de la flota vs el promedio de su modelo
--   C5  (#6) Paquetes express entregados con retraso, por distrito
--
-- Todas tienen un filtro selectivo (un mes, un nest o un umbral), porque
-- son reportes de un periodo: así un índice puede evitar leer la tabla
-- completa. Los parámetros están fijos para que el experimento sea repetible.
--
-- Formato: cada consulta empieza con una línea "-- @consulta Cn" (la usa
-- bench/experimento.py para leerlas) y termina en ";".
-- =====================================================================

-- @consulta C1
-- C1. Tasa de entregas exitosas y tiempo promedio de entrega por nest de origen
--     y distrito destino, para los vuelos de marzo de 2026.
--     Tablas: vuelo (filtro por fecha) ⋈ paquete ⋈ ruta_vuelo ⋈ estacion_nest ⋈ distrito
SELECT n.nombre                                         AS nest_origen,
       d.nombre                                         AS distrito_destino,
       count(*)                                         AS paquetes,
       count(*) FILTER (WHERE p.estado = 'entregado')   AS entregados,
       round(100.0 * count(*) FILTER (WHERE p.estado = 'entregado') / count(*), 1) AS tasa_exito_pct,
       round(avg(EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60)::numeric, 1) AS min_prom_entrega
FROM vuelo v
JOIN paquete p        ON p.id_vuelo = v.id_vuelo
JOIN ruta_vuelo r     ON r.id_ruta  = v.id_ruta
JOIN estacion_nest n  ON n.id_nest  = r.id_nest_origen
JOIN distrito d       ON d.ubigeo   = r.ubigeo_destino
WHERE v.despegue >= '2026-03-01' AND v.despegue < '2026-04-01'
GROUP BY n.nombre, d.nombre
ORDER BY tasa_exito_pct, paquetes DESC;

-- @consulta C2
-- C2. Consumo promedio de batería (puntos porcentuales de carga por km) por
--     modelo de drone y ruta, para los vuelos completados que salieron del
--     Nest Miraflores en el primer trimestre de 2026.
--     El consumo de un vuelo = carga de su primera lectura - carga de su última lectura.
WITH vuelos_sel AS (
    SELECT v.id_vuelo, v.id_ruta, v.id_drone, v.distancia_real_km
    FROM vuelo v
    JOIN ruta_vuelo r ON r.id_ruta = v.id_ruta
    WHERE r.id_nest_origen = (SELECT id_nest FROM estacion_nest WHERE codigo = 'NST-MIR-01')
      AND v.estado = 'completado'
      AND v.despegue >= '2026-01-01' AND v.despegue < '2026-04-01'
), extremos AS (
    SELECT t.id_vuelo,
           (array_agg(t.carga_pct ORDER BY t.marca_tiempo ASC))[1]  AS carga_ini,
           (array_agg(t.carga_pct ORDER BY t.marca_tiempo DESC))[1] AS carga_fin
    FROM telemetria_bateria t
    JOIN vuelos_sel vs ON vs.id_vuelo = t.id_vuelo
    GROUP BY t.id_vuelo
)
SELECT m.fabricante || ' ' || m.nombre AS modelo,
       r.codigo                        AS ruta,
       count(*)                        AS vuelos,
       round(avg((e.carga_ini - e.carga_fin) / vs.distancia_real_km), 2) AS pp_por_km
FROM vuelos_sel vs
JOIN extremos e      ON e.id_vuelo  = vs.id_vuelo
JOIN drone dr        ON dr.id_drone = vs.id_drone
JOIN modelo_drone m  ON m.id_modelo = dr.id_modelo
JOIN ruta_vuelo r    ON r.id_ruta   = vs.id_ruta
GROUP BY m.fabricante, m.nombre, r.codigo
ORDER BY pp_por_km DESC;

-- @consulta C3
-- C3. Baterías que superaron 60 °C en octubre de 2026: número de lecturas
--     anómalas, temperatura máxima, vuelos afectados y drones que las usaron.
SELECT b.id_bateria,
       b.numero_serie,
       b.salud_pct,
       b.estado,
       count(*)                                    AS lecturas_sobre_60,
       max(t.temperatura_c)                        AS temp_max_c,
       count(DISTINCT v.id_vuelo)                  AS vuelos,
       string_agg(DISTINCT v.id_drone::text, ', ') AS drones
FROM telemetria_bateria t
JOIN vuelo v   ON v.id_vuelo   = t.id_vuelo
JOIN bateria b ON b.id_bateria = v.id_bateria
WHERE t.temperatura_c > 60
  AND t.marca_tiempo >= '2026-10-01' AND t.marca_tiempo < '2026-11-01'
GROUP BY b.id_bateria, b.numero_serie, b.salud_pct, b.estado
ORDER BY temp_max_c DESC;

-- @consulta C4
-- C4. Utilización de la flota en septiembre de 2026: vuelos y horas de cada
--     drone, comparadas con el promedio de los drones de su mismo modelo
--     (función de ventana). Primero los más subutilizados.
WITH por_drone AS (
    SELECT v.id_drone,
           count(*) AS vuelos,
           sum(EXTRACT(EPOCH FROM (v.aterrizaje - v.despegue)) / 3600) AS horas
    FROM vuelo v
    WHERE v.estado IN ('completado', 'abortado')
      AND v.despegue >= '2026-09-01' AND v.despegue < '2026-10-01'
    GROUP BY v.id_drone
)
SELECT n.nombre                        AS nest,
       pd.id_drone,
       m.fabricante || ' ' || m.nombre AS modelo,
       pd.vuelos,
       round(pd.horas::numeric, 2)     AS horas,
       round(avg(pd.horas) OVER (PARTITION BY d.id_modelo)::numeric, 2)            AS horas_prom_modelo,
       round((pd.horas - avg(pd.horas) OVER (PARTITION BY d.id_modelo))::numeric, 2) AS diferencia
FROM por_drone pd
JOIN drone d          ON d.id_drone  = pd.id_drone
JOIN modelo_drone m   ON m.id_modelo = d.id_modelo
JOIN estacion_nest n  ON n.id_nest   = d.id_nest_base
ORDER BY diferencia, pd.id_drone;

-- @consulta C5
-- C5. Paquetes express entregados en agosto de 2026 que tardaron más que la
--     duración estimada de su ruta, agrupados por distrito destino.
SELECT d.nombre AS distrito,
       count(*) AS express_entregados,
       count(*) FILTER (WHERE EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60 > r.duracion_est_min) AS con_retraso,
       round(100.0 * count(*) FILTER (WHERE EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60 > r.duracion_est_min)
             / count(*), 1) AS pct_retraso,
       round(avg(GREATEST(0, EXTRACT(EPOCH FROM (p.fecha_entrega - v.despegue)) / 60 - r.duracion_est_min))::numeric, 2)
             AS min_retraso_prom
FROM paquete p
JOIN vuelo v      ON v.id_vuelo = p.id_vuelo
JOIN ruta_vuelo r ON r.id_ruta  = v.id_ruta
JOIN distrito d   ON d.ubigeo   = p.ubigeo_destino
WHERE p.prioridad = 'express'
  AND p.estado = 'entregado'
  AND p.fecha_entrega >= '2026-08-01' AND p.fecha_entrega < '2026-09-01'
GROUP BY d.nombre
ORDER BY pct_retraso DESC, express_entregados DESC;
