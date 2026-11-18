-- =====================================================================
-- SkyNest · 08_indices.sql  (sección 5.3 del informe)
--
-- Dos planes de índices por consulta (A y B). En el experimento cada plan
-- se crea SOLO, se mide y se borra (bench/experimento.py), para comparar
-- "sin índices" vs plan A vs plan B en cada escala.
--
-- "Sin índices" significa: solo los índices que PostgreSQL crea por sí mismo
-- para PRIMARY KEY, UNIQUE y el EXCLUDE de vuelo (GiST sobre id_bateria y el
-- intervalo del vuelo). Ojo: las FOREIGN KEY NO crean índice en PostgreSQL;
-- por eso paquete.id_vuelo, vuelo.id_ruta, etc. no están indexadas al inicio.
--
-- Mediciones preliminares en la escala 1M (mediana de 3 corridas, ms):
--             sin índices   plan A          plan B
--   C1           385         256 (1,5x)       78 (4,2x)  cubrientes
--   C2           140          39 (3,6x)       70 (2,0x)
--   C3           311          67 (4,6x)       20 (15,6x) parcial
--   C4            94          27 (3,5x)       88 (1,1x)  BRIN no se usa
--   C5           278         204 (1,4x)      130 (2,1x)  (39 ms con random_page_cost = 1.1)
--
-- Formato: cada plan empieza con "-- @plan Cn X" (lo lee bench/experimento.py).
-- Ejecutar este archivo completo crea TODOS los índices a la vez.
-- =====================================================================
SET search_path = skynest, reportes, public;

-- @plan C1 A
-- B+ (btree) simple en la fecha de despegue y en la FK paquete.id_vuelo.
-- El filtro de un mes selecciona ~4,5 % de los vuelos; el join con paquete
-- sigue leyendo paquete completo (hash join), por eso mejora poco.
CREATE INDEX IF NOT EXISTS ix_c1a_vuelo_despegue ON vuelo (despegue);
CREATE INDEX IF NOT EXISTS ix_c1a_paquete_vuelo  ON paquete (id_vuelo);

-- @plan C1 B
-- B+ cubrientes (INCLUDE): el índice ya trae las columnas que la consulta
-- necesita (id_ruta; estado y fecha_entrega), así PostgreSQL hace un
-- Index Only Scan sobre paquete sin leer la tabla.
CREATE INDEX IF NOT EXISTS ix_c1b_vuelo_despegue_cov ON vuelo (despegue) INCLUDE (id_ruta);
CREATE INDEX IF NOT EXISTS ix_c1b_paquete_vuelo_cov  ON paquete (id_vuelo) INCLUDE (estado, fecha_entrega);

-- @plan C2 A
-- B+ compuesto (id_ruta, despegue): la consulta filtra por las 20 rutas de un
-- nest Y por un rango de fechas; el índice resuelve los dos filtros juntos.
CREATE INDEX IF NOT EXISTS ix_c2a_vuelo_ruta_despegue ON vuelo (id_ruta, despegue);

-- @plan C2 B
-- B+ en la fecha + índice cubriente de telemetría (id_vuelo, marca_tiempo)
-- INCLUDE (carga_pct): primera y última lectura sin tocar la tabla.
CREATE INDEX IF NOT EXISTS ix_c2b_vuelo_despegue      ON vuelo (despegue);
CREATE INDEX IF NOT EXISTS ix_c2b_telemetria_cov      ON telemetria_bateria (id_vuelo, marca_tiempo) INCLUDE (carga_pct);

-- @plan C3 A
-- B+ en la temperatura: el filtro > 60 °C deja ~0,4 % de las lecturas.
CREATE INDEX IF NOT EXISTS ix_c3a_telemetria_temp ON telemetria_bateria (temperatura_c);

-- @plan C3 B
-- Índice PARCIAL: solo indexa las lecturas sobre 60 °C, ordenadas por fecha.
-- Es mucho más pequeño y resuelve a la vez el umbral y el rango de fechas.
CREATE INDEX IF NOT EXISTS ix_c3b_telemetria_alertas ON telemetria_bateria (marca_tiempo) WHERE temperatura_c > 60;

-- @plan C4 A
-- B+ en la fecha de despegue (filtro de un mes).
CREATE INDEX IF NOT EXISTS ix_c4a_vuelo_despegue ON vuelo (despegue);

-- @plan C4 B
-- BRIN (Block Range INdex): muy pequeño, pero solo sirve si las filas están
-- guardadas físicamente en orden de la columna. Aquí los vuelos se insertan
-- por drone, no por fecha, así que el planificador lo descarta: sirve para
-- discutir cuándo NO conviene un BRIN.
CREATE INDEX IF NOT EXISTS ix_c4b_vuelo_despegue_brin ON vuelo USING brin (despegue);

-- @plan C5 A
-- B+ en la fecha de entrega.
CREATE INDEX IF NOT EXISTS ix_c5a_paquete_entrega ON paquete (fecha_entrega);

-- @plan C5 B
-- B+ compuesto y cubriente: (prioridad, estado, fecha_entrega) resuelve los
-- tres filtros; INCLUDE trae id_vuelo y ubigeo_destino para el join.
CREATE INDEX IF NOT EXISTS ix_c5b_paquete_express_cov ON paquete (prioridad, estado, fecha_entrega)
    INCLUDE (id_vuelo, ubigeo_destino);

ANALYZE;
