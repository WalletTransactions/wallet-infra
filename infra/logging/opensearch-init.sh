#!/bin/sh
# Разовая настройка OpenSearch под дневные индексы wallet-logs-YYYY.MM.DD
# (см. Logstash_Format в fluent-bit.conf): шаблон индекса (1 шард, 0 реплик —
# нода одна, реплике некуда встать, иначе индекс вечно yellow) и ISM-политика
# (удалить индекс через 14 дней). Идемпотентно — безопасно на каждом
# `docker compose up`: шаблон PUT просто перезаписывает, политику обновляем
# через if_seq_no/if_primary_term (голый PUT на существующую вернул бы 409).
set -eu
OS=http://opensearch:9200
POLICY=wallet-logs-retention

curl -sf -X PUT "$OS/_index_template/wallet-logs" \
    -H 'Content-Type: application/json' -d @/init/index_template.json
echo

existing=$(curl -s "$OS/_plugins/_ism/policies/$POLICY")
seq_no=$(echo "$existing" | sed -n 's/.*"_seq_no":\([0-9]*\).*/\1/p')
primary_term=$(echo "$existing" | sed -n 's/.*"_primary_term":\([0-9]*\).*/\1/p')
if [ -n "$seq_no" ] && [ -n "$primary_term" ]; then
    query="?if_seq_no=$seq_no&if_primary_term=$primary_term"
else
    query=""
fi
curl -sf -X PUT "$OS/_plugins/_ism/policies/$POLICY$query" \
    -H 'Content-Type: application/json' -d @/init/ism_policy.json
echo
echo "opensearch init done"
