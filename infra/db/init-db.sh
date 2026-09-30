#!/bin/sh
# Постгрес-образ прогоняет всё из /docker-entrypoint-initdb.d только один раз
# — при первой инициализации ПУСТОГО volume (db-data). На уже существующем
# volume этот скрипт не выполнится сам — тогда накатите его руками:
#   podman exec -i <контейнер db> sh < infra/db/init-db.sh
#
# ТРИ роли, не одна общая и не две (см. infra/db/README.md, "Три роли"):
#   1. МИГРАТОР ($POSTGRES_USER — так его называет сам образ postgres,
#      значение приходит из MIGRATOR_POSTGRES_USER, см. compose.yaml) —
#      bootstrap-роль образа, фактически суперпользователь. Создаёт обе базы,
#      обе app-роли, владеет всеми таблицами и умеет их менять (DDL) — это и
#      есть та роль, которой дальше накатываются версионированные миграции
#      (см. infra/db/migrate.sh и infra/db/README.md, "Миграции").
#   2. AUTH_POSTGRES_USER — роль google-auth. Только DML на СВОИ таблицы
#      (SELECT/INSERT/UPDATE/DELETE) — ни CREATE/ALTER/DROP, ни TRUNCATE.
#   3. WALLET_POSTGRES_USER — роль wallet-api. То же самое, только своя база.
#
# ЭТОТ скрипт больше НЕ создаёт таблицы (roles/users/wallets) — они переехали
# в версионированные миграции ({google-auth,wallet-api}/migrations/, накатываются
# infra/db/migrate.sh, см. infra/db/README.md, "Миграции"). Здесь остаётся только
# bootstrap: роли+базы (нужен доступ к maintenance-базе "postgres", которого
# у мигратора-как-обычной-app-роли в чужой базе не было бы) и права DML для
# app-ролей на их будущие таблицы (ALTER DEFAULT PRIVILEGES — должен
# выполниться ДО того, как эти таблицы создаст миграция, поэтому и остаётся
# именно здесь, в bootstrap-шаге, а не переехал вместе с CREATE TABLE).
# Собственно `db.cpp::verify_schema()` в сервисах ничего из этого не
# создаёт — только проверяет, что миграции уже накачены, и падает с понятным
# сообщением, если нет.
set -eu

# --- 1. Роли и базы (подключение к maintenance-базе "postgres") ---
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v authuser="$AUTH_POSTGRES_USER" -v authpass="$AUTH_POSTGRES_PASSWORD" \
     -v authdb="$AUTH_POSTGRES_DB" \
     -v walletuser="$WALLET_POSTGRES_USER" -v walletpass="$WALLET_POSTGRES_PASSWORD" \
     -v walletdb="$WALLET_POSTGRES_DB" \
     -v monuser="$MONITORING_POSTGRES_USER" -v monpass="$MONITORING_POSTGRES_PASSWORD" \
     -v perfuser="$PERF_POSTGRES_USER" -v perfpass="$PERF_POSTGRES_PASSWORD" \
     -v perfdb="$PERF_POSTGRES_DB" \
     -v tguser="$TELEGRAM_POSTGRES_USER" -v tgpass="$TELEGRAM_POSTGRES_PASSWORD" \
     -v tgdb="$TELEGRAM_POSTGRES_DB" <<-'SQL'
    -- CREATE ROLE/DATABASE не поддерживают IF NOT EXISTS в ванильном
    -- Postgres — условная генерация через \gexec: этот SELECT не выполняет
    -- CREATE сам, а СТРОИТ его текст как обычную строку (||-конкатенация),
    -- и только \gexec потом отправляет получившийся текст на выполнение
    -- отдельным запросом.
    --
    -- Тонкость с квотированием — двух видов:
    --   :'var'  — подстановка ЗНАЧЕНИЯ переменной как безопасного
    --             SQL-литерала В ЗАПРОСЕ, который видит сервер (защита от
    --             SQL-инъекции при подстановке значения В SQL). После
    --             разбора сервером ЗНАЧЕНИЕ этого литерала — обычная
    --             строка БЕЗ кавычек (как у любого текстового литерала).
    --   quote_literal(x) — SQL-функция: берёт строку-ЗНАЧЕНИЕ x и
    --             возвращает НОВУЮ СТРОКУ С КАВЫЧКАМИ ВНУТРИ СЕБЯ.
    -- Пароль ниже участвует в ||-конкатенации, результат которой — ТЕКСТ
    -- БУДУЩЕЙ команды CREATE ROLE, а не сам запрос — значит, нужен именно
    -- quote_literal(:'authpass'), а не голый :'authpass': тот даёт просто
    -- значение пароля БЕЗ кавычек, и в собранном тексте команды получится
    -- синтаксическая ошибка (ровно так и было — см. историю чата, "syntax
    -- error at or near ..."). Для идентификаторов (имя роли/базы) — та же
    -- логика, quote_ident(:'var'), уже было верно.
    SELECT 'CREATE ROLE ' || quote_ident(:'authuser') || ' LOGIN PASSWORD ' || quote_literal(:'authpass')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'authuser')\gexec

    SELECT 'CREATE ROLE ' || quote_ident(:'walletuser') || ' LOGIN PASSWORD ' || quote_literal(:'walletpass')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'walletuser')\gexec

    -- Четвёртая роль, НЕ входящая в "три роли" выше (см. заголовок файла) —
    -- под ней ходит postgres_exporter (см. compose.yaml, сервис
    -- "postgres-exporter"), а не приложение. pg_monitor — встроенная роль
    -- Postgres (с версии 10): даёт SELECT на pg_stat_activity/pg_stat_database/
    -- pg_stat_replication и EXECUTE на горстку служебных функций мониторинга,
    -- но НЕ даёт доступа к данным пользовательских таблиц ни в одной базе —
    -- этой ролью нельзя прочитать ни счета, ни леджер, ни сессии. CONNECT
    -- LIMIT не ограничиваем отдельно: postgres_exporter держит одно соединение
    -- на процесс, LOGIN сама по себе уже не даёт прав на данные.
    SELECT 'CREATE ROLE ' || quote_ident(:'monuser') || ' LOGIN PASSWORD ' || quote_literal(:'monpass')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'monuser')\gexec
    GRANT pg_monitor TO :"monuser";

    -- Пятая роль — под ней ходит record_run.sh (см.
    -- wallet-report/loadtest/record_run.sh), пишет историю прогонов
    -- нагрузочного контура в СВОЮ, четвёртую базу (perf_history — не
    -- домен кошелька, не мирrouится в android-wallet/schema, см. комментарий в
    -- infra/db/migrations/perf/000001_init.up.sql). Только DML на СВОИ
    -- будущие таблицы — тот же принцип, что у AUTH_/WALLET_POSTGRES_USER
    -- выше; читает эту же базу отдельная read-only роль perf_reader,
    -- заводится не здесь, а в самой миграции (её GRANT SELECT должен идти
    -- ПОСЛЕ CREATE TABLE, а не до — в отличие от DML-ролей, которым
    -- ALTER DEFAULT PRIVILEGES ниже достаточно и без спец. лечения).
    SELECT 'CREATE ROLE ' || quote_ident(:'perfuser') || ' LOGIN PASSWORD ' || quote_literal(:'perfpass')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'perfuser')\gexec

    -- Шестая роль — Telegram-бот (wallet-telegram, см.
    -- org/docs/TODO_telegram_bot.md, §1.4). Своя база: связки чатов и offset
    -- поллинга, к базе кошелька у бота доступа нет вовсе — он пишет в
    -- кошелёк только через /sync/push от имени пользователя.
    SELECT 'CREATE ROLE ' || quote_ident(:'tguser') || ' LOGIN PASSWORD ' || quote_literal(:'tgpass')
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'tguser')\gexec

    -- Владелец всех трёх баз — МИГРАТОР (текущая роль, $POSTGRES_USER), не
    -- app-роль: тогда и таблицы внутри будут принадлежать мигратору, и
    -- ALTER DEFAULT PRIVILEGES ниже (запускается тоже мигратором) сработает
    -- на объекты, которые сам же мигратор и создаст.
    SELECT 'CREATE DATABASE ' || quote_ident(:'authdb')
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'authdb')\gexec

    SELECT 'CREATE DATABASE ' || quote_ident(:'walletdb')
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'walletdb')\gexec

    SELECT 'CREATE DATABASE ' || quote_ident(:'perfdb')
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'perfdb')\gexec

    SELECT 'CREATE DATABASE ' || quote_ident(:'tgdb')
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'tgdb')\gexec

    -- Defense in depth: Postgres по умолчанию даёт роли PUBLIC право CONNECT
    -- на любую новую базу — без этого auth-роль технически могла бы
    -- подключиться к базе wallet-api и наоборот (хоть и не прочитать там
    -- ничего без grant'ов на таблицы). Отзываем у PUBLIC, даём только
    -- своей роли на свою базу. ($POSTGRES_USER — мигратор — всё равно
    -- суперпользователь и это не обходит; это ограничение самого
    -- официального postgres-образа, тут не решается.)
    REVOKE CONNECT ON DATABASE :"authdb" FROM PUBLIC;
    REVOKE CONNECT ON DATABASE :"walletdb" FROM PUBLIC;
    REVOKE CONNECT ON DATABASE :"perfdb" FROM PUBLIC;
    REVOKE CONNECT ON DATABASE :"tgdb" FROM PUBLIC;
    GRANT CONNECT ON DATABASE :"authdb" TO :"authuser";
    GRANT CONNECT ON DATABASE :"walletdb" TO :"walletuser";
    GRANT CONNECT ON DATABASE :"perfdb" TO :"perfuser";
    GRANT CONNECT ON DATABASE :"tgdb" TO :"tguser";
    -- monitoring-роль подключается ко всем трём (postgres_exporter — с
    -- --auto-discover-databases, см. compose.yaml) — pg_monitor выше даёт ей
    -- право ЧИТАТЬ статистику отовсюду, но не право вообще ПОДКЛЮЧИТЬСЯ к
    -- базе, которую PUBLIC уже лишили CONNECT строками выше.
    GRANT CONNECT ON DATABASE :"authdb" TO :"monuser";
    GRANT CONNECT ON DATABASE :"walletdb" TO :"monuser";
    GRANT CONNECT ON DATABASE :"perfdb" TO :"monuser";
    GRANT CONNECT ON DATABASE :"tgdb" TO :"monuser";
    -- perf_reader (Grafana, см. infra/db/migrations/perf/000001_init.up.sql)
    -- подключается ТОЛЬКО к perf_history — ей нечего делать в auth/wallet.
    -- Сама роль заводится позже, миграцией perf (нужны её собственные
    -- таблицы для осмысленного SELECT) — но CONNECT на базу можно
    -- разрешить уже сейчас, GRANT на ещё не существующую роль просто
    -- упал бы: делаем это в самой миграции, не здесь.
SQL

# --- 2. Права google-auth (подключение к его собственной базе) ---
# Схема (roles/users) сюда больше не входит — см. google-auth/migrations/,
# накатывается отдельно через infra/db/migrate.sh ПОСЛЕ этого bootstrap-шага.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$AUTH_POSTGRES_DB" \
     -v authuser="$AUTH_POSTGRES_USER" <<-'SQL'
    -- Собирает статистику латентности/вызовов ПО КАЖДОМУ нормализованному
    -- запросу (см. GRANT pg_monitor выше и "postgres-exporter" в compose.yaml,
    -- --collector.stat_statements) — то, что даёт дашборду Grafana реальную
    -- "DB latency", а не только число активных соединений. Модуль загружен в
    -- разделяемую память кластера через shared_preload_libraries (см. команду
    -- запуска "db" в compose.yaml) — CREATE EXTENSION здесь лишь заводит
    -- SQL-обвязку (представление pg_stat_statements) В ЭТОЙ базе; данные сам
    -- по себе кластерные, общие для всех баз.
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

    GRANT USAGE ON SCHEMA public TO :"authuser";
    -- Только DML на объекты, которые мигратор создаст ПОЗЖЕ версионированной
    -- миграцией (ALTER DEFAULT PRIVILEGES действует на будущие объекты
    -- текущей роли — сработает, раз миграция накатывается позже этим же
    -- мигратором). Явно НЕ TRUNCATE и НЕ DDL (CREATE/ALTER/DROP) — их тут
    -- просто нет в списке.
    ALTER DEFAULT PRIVILEGES FOR ROLE :"authuser" IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"authuser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"authuser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT USAGE ON SEQUENCES TO :"authuser";
SQL

# --- 3. Права wallet-api (подключение к его собственной базе) ---
# Схема (wallets) сюда больше не входит — см. wallet-api/migrations/,
# накатывается отдельно через infra/db/migrate.sh ПОСЛЕ этого bootstrap-шага.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$WALLET_POSTGRES_DB" \
     -v walletuser="$WALLET_POSTGRES_USER" <<-'SQL'
    -- См. тот же CREATE EXTENSION и комментарий в блоке AUTH_POSTGRES_DB выше.
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

    GRANT USAGE ON SCHEMA public TO :"walletuser";
    ALTER DEFAULT PRIVILEGES FOR ROLE :"walletuser" IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"walletuser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"walletuser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT USAGE ON SEQUENCES TO :"walletuser";
SQL

# --- 4. Права record_run.sh (подключение к своей, отдельной от кошелька, базе) ---
# Схема (test_run/test_result) сюда не входит — см.
# infra/db/migrations/perf/, накатывается отдельно через
# `infra/db/migrate.sh perf up` ПОСЛЕ этого bootstrap-шага. Никакого
# pg_stat_statements здесь — эта база не про запросы самого сервиса
# (метрики уровня приложения из неё же снимает postgres-exporter наравне с
# auth/wallet), а про историю нагрузочных прогонов.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$PERF_POSTGRES_DB" \
     -v perfuser="$PERF_POSTGRES_USER" <<-'SQL'
    GRANT USAGE ON SCHEMA public TO :"perfuser";
    ALTER DEFAULT PRIVILEGES FOR ROLE :"perfuser" IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"perfuser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"perfuser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT USAGE ON SEQUENCES TO :"perfuser";
SQL

# --- 5. Права wallet-telegram (своя база, см. wallet-telegram/migrations/) ---
# Тот же принцип, что у google-auth/wallet-api выше: только DML на таблицы,
# которые позже создаст мигратор (`infra/db/migrate.sh telegram up`).
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$TELEGRAM_POSTGRES_DB" \
     -v tguser="$TELEGRAM_POSTGRES_USER" <<-'SQL'
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

    GRANT USAGE ON SCHEMA public TO :"tguser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"tguser";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT USAGE ON SEQUENCES TO :"tguser";
SQL
