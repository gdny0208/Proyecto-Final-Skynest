-- =====================================================================
-- SkyNest · Video 5 de 5 · Consulta 5: Paquetes express entregados con retraso, por distrito
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
-- 1. La pregunta: En agosto de 2026, por distrito, ¿cuántos paquetes express entregados llegaron después del tiempo estimado de su ruta?
--    Tablas que usa y cuántas filas tienen
-- ---------------------------------------------------------------------
SELECT 'paquete' AS tabla, count(*) AS filas FROM paquete
UNION ALL
SELECT 'vuelo' AS tabla, count(*) AS filas FROM vuelo;

-- ---------------------------------------------------------------------
-- 2. Punto de partida: solo los índices de las llaves (PRIMARY KEY y UNIQUE)
-- ---------------------------------------------------------------------
SELECT tablename AS tabla, indexname AS indice
FROM pg_indexes
WHERE schemaname = 'skynest' AND tablename IN ('paquete')
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 3. SIN ÍNDICE. Mirar: "Parallel Seq Scan on paquete" y "Parallel Seq Scan on vuelo": lee las dos tablas completas.
--    En la última fila, "Execution Time" (en el informe: unos 113 ms).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
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

-- ---------------------------------------------------------------------
-- 4. CREAR EL ÍNDICE: índice COMPUESTO y CUBRIENTE (prioridad, estado, fecha).
--    Después se actualizan las estadísticas (ANALYZE) y se muestra cuánto ocupa
-- ---------------------------------------------------------------------
CREATE INDEX ix_c5b_paquete_express_cov ON paquete (prioridad, estado, fecha_entrega)
    INCLUDE (id_vuelo, ubigeo_destino);
ANALYZE paquete;
SELECT indexname AS indice, pg_size_pretty(pg_relation_size(('skynest.' || indexname)::regclass)) AS tamano
FROM pg_indexes
WHERE schemaname = 'skynest' AND indexname IN ('ix_c5b_paquete_express_cov');

-- ---------------------------------------------------------------------
-- 5. CON ÍNDICE. Es la MISMA consulta. Mirar: "Index Only Scan using ix_c5b_paquete_express_cov" para paquete, pero vuelo SIGUE con "Seq Scan".
--    "Execution Time" (en el informe: unos 41 ms, 2,7 veces más rápido).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
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

-- ---------------------------------------------------------------------
-- 6. CON ÍNDICE + random_page_cost = 1.1 (el valor recomendado para discos SSD).
--    Mirar: ahora vuelo usa "Index Scan using pk_vuelo" (busca cada vuelo por su llave)
--    y "Execution Time" baja más (en el informe: unos 20 ms, 5,7 veces más rápido que sin índice)
-- ---------------------------------------------------------------------
SET random_page_cost = 1.1;
EXPLAIN (ANALYZE, BUFFERS)
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
RESET random_page_cost;

-- ---------------------------------------------------------------------
-- 7. El índice no cambia la respuesta, solo el tiempo: mismas filas con o sin índice
-- ---------------------------------------------------------------------
SELECT count(*) AS filas_del_resultado FROM (
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
ORDER BY pct_retraso DESC, express_entregados DESC
) AS r;

-- ---------------------------------------------------------------------
-- 8. Dejar la base como estaba: borrar el índice del video
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS ix_c5b_paquete_express_cov;
ANALYZE paquete;
