# payments-local

Всё приложение `payments-app-org` локально: docker-compose (Postgres, Kafka, Redis, 9 сервисов, фронтенд), создание схем БД, секреты и скрипты рабочего места. Документация всего проекта — [CLAUDE.md](CLAUDE.md).

## Начать

```bash
mkdir -p ~/Claude/payments && cd ~/Claude/payments
git clone git@github.com:payments-app-org/payments-local.git
payments-local/scripts/clone-all.sh     # склонировать остальные репозитории рядом
cd payments-local && cp .env.example .env   # заполнить секреты (openssl rand -base64 32)
scripts/up.sh                           # собрать и поднять всё → http://localhost:5173
```

Сборке образов нужен токен GitHub с правом `read:packages` (Maven скачивает общую библиотеку из GitHub Packages): `scripts/up.sh` берёт его из `gh auth token`, если в `.env` не задан `GITHUB_TOKEN`.

| Скрипт | Что делает |
|---|---|
| `scripts/clone-all.sh` | клонирует все репозитории в общую папку |
| `scripts/pull-all.sh` | обновляет `main` во всех (пропускает ветки с правками) |
| `scripts/status.sh` | ветка и правки в каждом репозитории |
| `scripts/up.sh [сервис…]` | собирает и поднимает всё или указанные сервисы |

## Репозитории

| Репозиторий | Что внутри |
|---|---|
| [payments-ci](https://github.com/payments-app-org/payments-ci) | общие шаблоны CI |
| [payments-platform](https://github.com/payments-app-org/payments-platform) | общая инфраструктурная библиотека |
| [payments-account](https://github.com/payments-app-org/payments-account) | пользователи, счета, лимиты, резервы, журнал |
| [payments-pricing](https://github.com/payments-app-org/payments-pricing) | комиссии и котировки |
| [payments-payment](https://github.com/payments-app-org/payments-payment) | оркестратор платежей (сага) |
| [payments-fraud](https://github.com/payments-app-org/payments-fraud) | заглушка антифрода |
| [payments-processing](https://github.com/payments-app-org/payments-processing) | заглушка процессинга |
| [payments-history](https://github.com/payments-app-org/payments-history) | история операций и аналитика |
| [payments-biller](https://github.com/payments-app-org/payments-biller) | поставщики, переводы за рубеж, госуслуги |
| [payments-providers](https://github.com/payments-app-org/payments-providers) | заглушки поставщиков |
| [payments-autopayments](https://github.com/payments-app-org/payments-autopayments) | шаблоны и автоплатежи |
| [payments-frontend](https://github.com/payments-app-org/payments-frontend) | веб-интерфейс |
