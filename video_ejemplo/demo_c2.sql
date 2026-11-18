-- =====================================================================
-- SkyNest · Video 2 de 5 · Consulta 2: Consumo de batería por km, por modelo y ruta
-- Base: skynest_1m (1 000 000 de vuelos), en pgAdmin → Query Tool.
--
-- Cómo usarlo: ejecutar UN BLOQUE A LA VEZ, en orden. Para ejecutar un bloque,
-- seleccionarlo con el mouse (desde su comentario hasta el último ;) y pulsar F5.
-- Los comentarios dicen qué mirar en cada resultado: se leen en pantalla, así el
-- video se entiende sin voz. Al terminar, la base queda igual que al principio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Preparación: tablas del esquema skynest y sin índices del experimento
-- ---------------------------------------------------------------------
SET search_path = skynest, reportes, public;
DO $$
DECLARE ix text;
BEGIN
    FOR ix IN SELECT indexname FROM pg_indexes WHERE schemaname = 'skynest' AND indexname LIKE 'ix\_c%' LOOP
        EXECUTE format('DROP INDEX skynest.%I', ix);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 1. La pregunta: En el primer trimestre de 2026, para los vuelos del nest NST-MIR-01, ¿cuántos puntos de carga gasta cada modelo por km, en cada ruta?
--    Tablas que usa y cuántas filas tienen
-- ---------------------------------------------------------------------
SELECT 'vuelo' AS tabla, count(*) AS filas FROM vuelo
UNION ALL
SELECT 'telemetria_bateria' AS tabla, count(*) AS filas FROM telemetria_bateria;

-- ---------------------------------------------------------------------
-- 2. Punto de partida: solo los índices de las llaves (PRIMARY KEY y UNIQUE)
-- ---------------------------------------------------------------------
SELECT tablename AS tabla, indexname AS indice
FROM pg_indexes
WHERE schemaname = 'skynest' AND tablename IN ('vuelo')
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 3. SIN ÍNDICE. Mirar: "Parallel Seq Scan on vuelo" con "Rows Removed by Filter": recorre el millón de vuelos y bota casi todos.
--    En la última fila, "Execution Time" (en el informe: unos 46 ms).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
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

-- ---------------------------------------------------------------------
-- 4. CREAR EL ÍNDICE: índice COMPUESTO (ruta, fecha).
--    Después se actualizan las estadísticas (ANALYZE) y se muestra cuánto ocupa
-- ---------------------------------------------------------------------
CREATE INDEX ix_c2a_vuelo_ruta_despegue ON vuelo (id_ruta, despegue);
ANALYZE vuelo;
SELECT indexname AS indice, pg_size_pretty(pg_relation_size(('skynest.' || indexname)::regclass)) AS tamano
FROM pg_indexes
WHERE schemaname = 'skynest' AND indexname IN ('ix_c2a_vuelo_ruta_despegue');

-- ---------------------------------------------------------------------
-- 5. CON ÍNDICE. Es la MISMA consulta. Mirar: "Index Scan using ix_c2a_vuelo_ruta_despegue on vuelo": va directo a los vuelos de cada ruta en el trimestre.
--    "Execution Time" menor (en el informe: unos 21 ms, 2,2 veces más rápido).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
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

-- ---------------------------------------------------------------------
-- 6. El índice no cambia la respuesta, solo el tiempo: mismas filas con o sin índice
-- ---------------------------------------------------------------------
SELECT count(*) AS filas_del_resultado FROM (
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
ORDER BY pp_por_km DESC
) AS r;

-- ---------------------------------------------------------------------
-- 7. Dejar la base como estaba: borrar el índice del video
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS ix_c2a_vuelo_ruta_despegue;
ANALYZE vuelo;
