## ADDED Requirements

### Requirement: Стек логов только с этой машины
Порты OpenSearch и OpenSearch Dashboards SHALL публиковаться на хосте только
на `127.0.0.1`: в стеке логов нет аутентификации, а в индексах — логи prod и
test. Fluent Bit SHALL писать в OpenSearch по внутренней сети стека, без
хост-порта.

#### Scenario: Запрос из LAN
- **WHEN** с другой машины в LAN выполняется `curl http://<IP хоста>:19200/_search`
- **THEN** соединение отклонено

#### Scenario: Логи на этой машине
- **WHEN** на хосте открыт `http://localhost:15601`
- **THEN** Dashboards показывают логи обоих контуров
