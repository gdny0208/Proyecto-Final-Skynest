# Guiones de audio para los 5 videos del anexo

Cada guion está sincronizado con su video (`videos_anexo/video_CN_skynest_1m.mp4`). La columna **Tiempo** indica
cuándo empieza cada parte; la etiqueta roja de arriba a la derecha ("Bloque N") ayuda a no perderse.

**Cómo grabar:** abre el video, ponlo en pantalla completa y lee el guion mientras se reproduce. Graba con
Notas de Voz (iPhone o Mac) o con QuickTime (*Archivo → Nueva grabación de audio*), **un archivo por video**:
`audio_C1.m4a` … `audio_C5.m4a`. Si te adelantas, haz una pausa; si te atrasas, salta la frase marcada como
*(opcional)*. Unos 2 segundos de silencio al inicio ayudan a sincronizar.

**Los tiempos de ejecución** que se dicen son los que salieron en cada video. El informe usa la media de 5
corridas, por eso no son idénticos: lo que importa es el cambio de plan y que el tiempo baja.

---

## Video 1 · Consulta 1 — Tasa de entregas por nest y distrito (1:54)

| Tiempo | En pantalla | Qué decir |
|---|---|---|
| 0:00 | Título | "Video uno de cinco. Consulta uno: la tasa de entregas exitosas por nest de salida y distrito de destino, en la base de un millón de vuelos." |
| 0:08 | pgAdmin, se abre el Query Tool | "Trabajamos en pgAdmin, conectados a la base skynest_1m. Abrimos el Query Tool y cargamos el script demo_c1.sql." |
| 0:25 | Se abre el archivo | "El script se ejecuta bloque por bloque: primero medimos la consulta sin índice, luego creamos el índice, la medimos otra vez y al final lo borramos." *(opcional)* "Así la base queda como estaba." |
| 0:45 | Bloque 0 | "El bloque cero prepara la sesión: usa el esquema skynest y borra índices de pruebas anteriores. No devuelve filas." |
| 0:50 | Bloque 1 | "La pregunta es: en marzo de 2026, qué porcentaje de paquetes se entregó y cuánto demoró. Usa un millón de vuelos y un millón y medio de paquetes." |
| 0:55 | Bloque 2 | "Partimos solo con los índices de las llaves primarias y únicas." |
| 1:01 | Bloque 3 · plan sin índice | "Sin índice, el plan hace un Parallel Seq Scan sobre paquete y sobre vuelo: lee las dos tablas completas para quedarse con marzo." |
| 1:10 | Execution Time | "El tiempo de ejecución es de unos 330 milisegundos." |
| 1:16 | Bloque 4 · se crean los índices | "Creamos dos índices cubrientes: uno en la fecha de despegue y otro en el vuelo del paquete, que además guarda el estado y la fecha de entrega. Ocupan 30 y 58 megas." |
| 1:24 | Bloque 5 · plan con índice | "Es la misma consulta. Ahora aparece un Index Only Scan: PostgreSQL responde con el índice, sin leer la tabla de paquetes." |
| 1:33 | Execution Time | "Baja a 131 milisegundos: dos veces y media más rápido." |
| 1:37 | Bloque 6 | "El resultado es el mismo con o sin índice, 342 filas. El índice solo cambia el tiempo." |
| 1:42 | Bloque 7 | "Por último borramos los índices y la base queda como al inicio." |
| 1:48 | Resumen final | "Esa fue la consulta uno." |

---

## Video 2 · Consulta 2 — Consumo de batería por km (1:53)

| Tiempo | En pantalla | Qué decir |
|---|---|---|
| 0:00 | Título | "Video dos de cinco. Consulta dos: cuántos puntos de batería gasta cada modelo de drone por kilómetro, en la base de un millón de vuelos." |
| 0:08 | pgAdmin, se abre el Query Tool | "En pgAdmin, sobre skynest_1m, abrimos el Query Tool y cargamos demo_c2.sql." |
| 0:25 | Se abre el archivo | "Igual que antes: sin índice, creamos el índice, con índice y al final lo borramos." |
| 0:44 | Bloque 0 | "Preparamos la sesión y nos aseguramos de que no haya índices del experimento." |
| 0:49 | Bloque 1 | "La pregunta: en el primer trimestre de 2026, para los vuelos que salen del nest NST-MIR-01, cuánta carga gasta cada modelo por kilómetro en cada ruta. Usa un millón de vuelos y casi cinco millones de lecturas de telemetría." |
| 0:56 | Bloque 2 | "Solo están los índices de las llaves." |
| 1:01 | Bloque 3 · plan sin índice | "Sin índice, el plan recorre el millón de vuelos con un Parallel Seq Scan y descarta casi todos con Rows Removed by Filter." |
| 1:11 | Execution Time | "Tarda unos 109 milisegundos." |
| 1:17 | Bloque 4 · se crea el índice | "Creamos un índice compuesto en la ruta y la fecha de despegue. Ocupa 30 megas." |
| 1:23 | Bloque 5 · plan con índice | "Con el índice, el plan usa un Index Scan: va directo a los vuelos de cada ruta en el trimestre." |
| 1:32 | Execution Time | "Baja a 62 milisegundos, casi el doble de rápido." |
| 1:37 | Bloque 6 | "La respuesta no cambia: 69 filas con o sin índice." |
| 1:42 | Bloque 7 | "Borramos el índice para dejar la base como estaba." |
| 1:47 | Resumen final | "Esa fue la consulta dos." |

---

## Video 3 · Consulta 3 — Baterías sobre 60 °C (1:50)

| Tiempo | En pantalla | Qué decir |
|---|---|---|
| 0:00 | Título | "Video tres de cinco. Consulta tres: qué baterías superaron los 60 grados en octubre, en la base de un millón de vuelos." |
| 0:08 | pgAdmin, se abre el Query Tool | "En pgAdmin, sobre skynest_1m, abrimos el Query Tool y cargamos demo_c3.sql." |
| 0:25 | Se abre el archivo | "Medimos sin índice, creamos el índice, medimos con índice y lo borramos." *(opcional)* "Esta es la consulta donde el índice más se nota." |
| 0:44 | Bloque 0 | "Preparamos la sesión, sin índices del experimento." |
| 0:50 | Bloque 1 | "La pregunta: qué baterías pasaron los 60 grados en octubre de 2026 y en qué drones se usaron. La tabla de telemetría tiene casi cinco millones de lecturas." |
| 0:55 | Bloque 2 | "La telemetría solo tiene su llave primaria." |
| 1:00 | Bloque 3 · plan sin índice | "Sin índice, el plan hace un Parallel Seq Scan sobre la telemetría y descarta más de un millón y medio de filas en cada proceso, porque casi ninguna lectura pasa los 60 grados." |
| 1:10 | Execution Time | "Tarda unos 300 milisegundos." |
| 1:15 | Bloque 4 · se crea el índice | "Creamos un índice parcial: solo guarda las lecturas sobre 60 grados. Por eso ocupa apenas 424 kilobytes." |
| 1:21 | Bloque 5 · plan con índice | "Con el índice, el plan usa un Bitmap Index Scan sobre el índice parcial y lee solo unas 800 lecturas." |
| 1:30 | Execution Time | "Baja a 9 milisegundos: más de treinta veces más rápido." |
| 1:34 | Bloque 6 | "El resultado es el mismo: 466 baterías con o sin índice." |
| 1:39 | Bloque 7 | "Borramos el índice y la base queda como estaba." |
| 1:44 | Resumen final | "Elegir el tipo de índice correcto, aquí uno parcial, importa tanto como la columna." |

---

## Video 4 · Consulta 4 — Uso de la flota (1:51)

| Tiempo | En pantalla | Qué decir |
|---|---|---|
| 0:00 | Título | "Video cuatro de cinco. Consulta cuatro: el uso de la flota frente al promedio de cada modelo, en la base de un millón de vuelos." |
| 0:08 | pgAdmin, se abre el Query Tool | "En pgAdmin, sobre skynest_1m, abrimos el Query Tool y cargamos demo_c4.sql." |
| 0:25 | Se abre el archivo | "Medimos sin índice, creamos el índice, medimos con índice y lo borramos." |
| 0:44 | Bloque 0 | "Preparamos la sesión, sin índices del experimento." |
| 0:50 | Bloque 1 | "La pregunta: en septiembre de 2026, cuántos vuelos y horas hizo cada drone y cuánto se aleja del promedio de su modelo. Usa la tabla de un millón de vuelos." |
| 0:55 | Bloque 2 | "Solo están los índices de las llaves." |
| 1:00 | Bloque 3 · plan sin índice | "Sin índice, el plan recorre el millón de vuelos con un Parallel Seq Scan para quedarse con los de septiembre." |
| 1:10 | Execution Time | "Tarda unos 94 milisegundos." |
| 1:16 | Bloque 4 · se crea el índice | "Creamos un índice B+ en la fecha de despegue. Ocupa 18 megas." |
| 1:21 | Bloque 5 · plan con índice | "Con el índice, el plan usa un Bitmap Index Scan y va directo a los vuelos de septiembre." |
| 1:30 | Execution Time | "Baja a 41 milisegundos: más del doble de rápido." |
| 1:34 | Bloque 6 | "La respuesta es la misma: 300 drones con o sin índice." |
| 1:39 | Bloque 7 | "Borramos el índice y la base queda como estaba." |
| 1:45 | Resumen final | "Esa fue la consulta cuatro." *(opcional)* "Un índice BRIN en la fecha no sirvió, porque los vuelos no están guardados en orden de fecha." |

---

## Video 5 · Consulta 5 — Paquetes express con retraso (2:19)

| Tiempo | En pantalla | Qué decir |
|---|---|---|
| 0:00 | Título | "Video cinco de cinco. Consulta cinco: los paquetes express que llegaron tarde, por distrito, en la base de un millón de vuelos." |
| 0:08 | pgAdmin, se abre el Query Tool | "En pgAdmin, sobre skynest_1m, abrimos el Query Tool y cargamos demo_c5.sql." |
| 0:25 | Se abre el archivo | "Aquí medimos tres cosas: sin índice, con índice, y con índice más un ajuste del planificador." |
| 0:44 | Bloque 0 | "Preparamos la sesión, sin índices del experimento." |
| 0:50 | Bloque 1 | "La pregunta: en agosto de 2026, por distrito, cuántos paquetes express entregados llegaron después del tiempo estimado de su ruta." |
| 0:55 | Bloque 2 | "Partimos solo con los índices de las llaves." |
| 1:02 | Bloque 3 · plan sin índice | "Sin índice, el plan lee completas las tablas de paquetes y de vuelos con Parallel Seq Scan." |
| 1:12 | Execution Time | "Tarda alrededor de un segundo." *(opcional)* "Es la primera lectura, con los datos aún en disco." |
| 1:18 | Bloque 4 · se crea el índice | "Creamos un índice compuesto y cubriente en prioridad, estado y fecha de entrega, que además guarda el vuelo y el distrito. Ocupa 96 megas." |
| 1:29 | Bloque 5 · plan con índice | "Con el índice, los paquetes se leen con un Index Only Scan, pero la tabla de vuelos todavía se recorre completa." |
| 1:39 | Execution Time | "Baja a 125 milisegundos." |
| 1:45 | Bloque 6 · random_page_cost = 1.1 | "Ahora bajamos random_page_cost a 1.1, el valor recomendado para discos SSD. Con eso, el planificador busca cada vuelo por su llave primaria con un Index Scan, en vez de leer la tabla entera." |
| 1:55 | Execution Time | "Baja a 103 milisegundos, unas diez veces más rápido que sin índice." |
| 1:58 | Línea RESET | "Y devolvemos el parámetro a su valor por defecto." |
| 2:02 | Bloque 7 | "El resultado es el mismo con o sin índice: 34 distritos." |
| 2:07 | Bloque 8 | "Borramos el índice y la base queda como estaba." |
| 2:13 | Resumen final | "Con esto terminamos las cinco consultas: con un millón de registros, el índice adecuado reduce el tiempo entre dos y treinta veces. Gracias." |
