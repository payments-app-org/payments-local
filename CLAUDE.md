# payments-app

Платёжный кабинет: «Платежи и переводы» и «История». Микросервисная архитектура.

## Принцип работы

Как в компаниях на микросервисах: **у каждого сервиса свой репозиторий** и свой CI/CD. Все репозитории — в организации GitHub [`payments-app-org`](https://github.com/payments-app-org), локально — рядом в одной папке `~/Claude/payments/`.

1. **Ветка** — правим нужный репозиторий в своей ветке (не в `main`).
2. **Проверяем локально** — поднимаем всё в Docker (`payments-local/scripts/up.sh`) и смотрим на http://localhost:5173. Всё должно работать до коммита.
3. **PR** — `git push` ветки → pull request в `main` этого репозитория. CI репозитория собирает и тестирует сервис; сливаем одним коммитом (squash), когда проверка `ci / ok` зелёная. `main` защищён: без зелёного `ci / ok` коммит туда не попадёт — ни через PR, ни прямым push, в том числе у владельца; force push и удаление ветки запрещены.
4. **После слияния** CI снова проверяет сервис и публикует образ `ghcr.io/payments-app-org/payments-<сервис>:<sha>` (и `:main`) в GitHub Container Registry. **Выкатка — по кнопке**: задача `deploy` ждёт подтверждения окружения `prod` (в запуске CI — Review deployments → prod → Approve and deploy; аналог `when: manual` в GitLab), затем записывает `<sha>` в [`payments-deploy`](https://github.com/payments-app-org/payments-deploy) (`envs/prod/services/<сервис>.yaml`), Argo CD в кластере видит коммит и обновляет только этот сервис — http://payments.localhost. На push в ветку без PR CI не запускается.

Изменение затрагивает несколько сервисов (новое поле в API) — PR в каждый репозиторий; сначала тот, кто отдаёт данные, потом тот, кто их читает: сервисы выкатываются независимо и должны работать со старой версией соседа.

Делаем только то, что попросили: новые сервисы, таблицы и фичи добавляем по мере того, как их описывают.

## Репозитории

```
~/Claude/payments/
  payments-local/         docker-compose всего приложения, init.sql, .env, скрипты рабочего места, эта документация
  payments-ci/            общие шаблоны CI (reusable workflows): java-service, java-library, frontend, deploy
  payments-deploy/        окружение в Kubernetes: общий Helm-чарт, настройки сервисов, Postgres/Kafka/Redis, Argo CD
  payments-platform/      общая инфраструктурная библиотека (см. ниже), версии — в GitHub Packages
  payments-account/       пользователи, счета, подписки, лимиты, резервирование, журнал операций   :8081
  payments-pricing/       расчёт комиссии и подписанная котировка                                  :8082
  payments-payment/       оркестратор платежей (сага)                                              :8083
  payments-fraud/         заглушка антифрода (другая команда)                                      :8084
  payments-processing/    заглушка процессинга — движения денег (другая команда)                   :8085
  payments-history/       история операций всех пользователей (читает Kafka)                       :8086
  payments-biller/        справочники и интеграции с поставщиками: переводы за рубеж, госуслуги      :8087
  payments-providers/     заглушки сторонних поставщиков (шлюзы, ГИС ГМП)                          :8088
  payments-autopayments/  шаблоны платежей и автоплатежи                                           :8089
  payments-gateway/       API Gateway: единственный вход в API (Spring Cloud Gateway)               :8080
  payments-frontend/      React + Vite + TypeScript; design/ — макеты (reference-*.png)            :5173
```

- `payments-local/scripts/clone-all.sh` — склонировать все репозитории рядом; `pull-all.sh` — обновить `main` во всех (пропускает ветки с правками); `status.sh` — ветка и правки в каждом.
- История каждого репозитория — история его папки из прежнего монорепозитория `artur08r/payments-app` (теперь в архиве, только чтение).

Java-сервисы: Java 21, Spring Boot 4, Maven. Каждый сервис — самостоятельный проект; доменный код не делим (договариваются через API), общая только инфраструктура — `payments-platform`.

## CI (GitHub Actions)

В каждом репозитории `.github/workflows/ci.yml` в несколько строк подключает шаблон из `payments-ci` (тег `v1`):
- **сервис** (`java-service.yml`): `mvn verify` (unit + интеграционные на Testcontainers) → Trivy по зависимостям (отказ на исправимых CRITICAL) → сборка образа → Trivy по образу (пакеты ОС и `app.jar`) → в `main` публикация в GHCR. В PR образ только собирается и проверяется — так проверяется и Dockerfile. Упали тесты — отчёты в артефактах запуска (7 дней).
- **библиотека** (`java-library.yml`): `mvn verify`, Trivy; тег `vX.Y.Z`, совпадающий с версией в `pom.xml`, — публикация версии в GitHub Packages.
- **фронтенд** (`frontend.yml`): `npm ci`, `npm run build` (проверка типов и сборка), Trivy, образ (nginx со статикой; цель `dev` Dockerfile — dev-сервер Vite для compose) → Trivy по образу → в `main` публикация.
- **выкатка** (`deploy.yml`, вызывают шаблоны сервиса и фронтенда в `main` после публикации образа): ждёт кнопки (окружение `prod` с обязательным подтверждением в репозитории), затем `payments-deploy/scripts/set-image.sh` записывает тег образа в `envs/prod/services/<сервис>.yaml` ключом развёртывания (секрет `DEPLOY_KEY`), дальше Argo CD. Итог `ok` выкатку не ждёт: в PR её нет.
- Итог — задача `ok`, проверка `ci / ok`: её требует защита `main`.
- Действия закреплены по SHA коммита (тег можно переписать задним числом). `.github/dependabot.yml` в каждом репозитории — раз в неделю PR с обновлениями (minor и patch — одним PR; мажорные смены базовых образов — Java, Node — не предлагает: это решение вместе с `pom.xml` и CI; свою библиотеку обновляем сами).
- Изменили шаблон в `payments-ci` совместимо — сдвинуть тег `v1`; несовместимо — тег `v2`, и репозитории переходят на него сами.
- Проверить workflow локально: `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7`.

## payments-platform

Подключается зависимостью `com.paymentsapp:platform` с версией (`<platform.version>` в `pom.xml` сервиса), включается автоконфигурацией. Версии публикуются в GitHub Packages (аналог корпоративного Nexus): поменяли библиотеку → подняли версию в её `pom.xml` → PR → тег `vX.Y.Z` → CI публикует. Сервисы переходят на новую версию сами, когда им удобно. Скачивание требует входа даже у публичных пакетов: в CI — встроенный токен, при сборке образа — секрет сборки `github_token` (в слои не попадает), вход описан в `.mvn/settings.xml` каждого репозитория.
- **Outbox** (`platform.outbox.enabled: true` — payment): запись события в транзакции (`Outbox.add`), публикация в Kafka (`FOR UPDATE SKIP LOCKED`, интервал `platform.outbox.publish-interval`), очистка отправленных старше `retention` пачками (ShedLock).
- **DLT для Kafka**: консьюмер не смог обработать сообщение — 3 повтора с паузой 1 → 2 → 4 с, затем в DLT своей группы `<топик>.<группа>-dlt` (`platform.kafka.dead-letter.*`): у `payment.events` три группы (history, biller, biller-charity), сбой одной не попадает в разбор другой; битый JSON — сразу в DLT. Каждое сообщение в DLT — `ERROR` в логе (ключ и место в топике, без тела). Разбор для `platform.kafka.dead-letter.topics` / `groups`: `GET /api/internal/dlt/{topic}` — сколько ждёт по группам, `POST /api/internal/dlt/{topic}/replay` — отправить в исходный топик всё, что лежало в DLT (позиция — в группе `<сервис>-dlt-replay`). Сообщение снова получат и другие группы, поэтому все читатели идемпотентны.
- **Время**: бины `Clock` и `ZoneId` из `platform.time.zone` (Europe/Moscow). В коде не вызываем `now()` без `Clock`.
- **Ошибки — два уровня проверки.** Первый — формат запроса: Bean Validation на DTO (`@Valid`, `@NotNull`, `@Size`, `@Pattern`, `@Digits`…), параметры и заголовки. Все ошибки формата Spring MVC превращает в ProblemDetail `InputErrorHandler`: коды `InputError` (`VALIDATION_FAILED` + список `errors` [{field, message}] и те же причины в `detail`, `MALFORMED_REQUEST`, `INVALID_PARAMETER`, `NOT_FOUND`, `METHOD_NOT_ALLOWED`…), непредвиденная ошибка — `INTERNAL_ERROR` (500, стек только в лог). Тексты — на русском для любого клиента (`FixedLocaleResolver(ru)`). Второй уровень — бизнес-правила в сервисах: enum кода ошибки реализует `ErrorCode` (статус + шаблон текста), бросаем `DomainException`, ответ — ProblemDetail с полем `code`. Свои `@RestControllerAdvice` сервиса — с `@Order(HIGHEST_PRECEDENCE)`, иначе их перехватит «последний рубеж» платформы.
- **Хэши**: `Hashing.sha256Hex`, `Hashing.hmacSha256Hex`.
- **ShedLock** в Redis (у сервисов со `spring-boot-starter-data-redis`): `@SchedulerLock` на задаче — при нескольких подах её выполняет один. Сейчас: `payment-recovery`, `payment-idempotency-cleanup`, `charity-settlement`, `outbox-cleanup`. Планировщик autopayments работу не блокирует, а делит: каждый под бронирует свою пачку (`FOR UPDATE SKIP LOCKED` + `claimed_until`).
- **ResilientCalls** (у сервисов с `resilience4j-spring-boot4`): вызов соседа через bulkhead → circuit breaker → retry, настройки — `resilience4j.*` в `application.yml`; открытый circuit breaker → `ServiceUnavailableException` (наследник `RestClientException`). `ConnectFailure` — предикат «повторять, только если не удалось соединиться».

- **Кэш** (`platform.cache.enabled: true`): `@Cacheable` поверх Redis, TTL — `platform.cache.ttl.<кэш>`, префикс ключей `<сервис>:<version>:<кэш>:`; сбой Redis — запрос идёт мимо кэша.
- **IdempotentResults**: итог операции по ключу идемпотентности в Redis (`SET NX` + TTL) — для заглушек внешних систем; `replace` — промежуточный итог (долгий перевод) сменился окончательным.
- **Swagger** (у сервисов со springdoc): заголовок — имя сервиса, описание — `platform.openapi.description`; у каждой операции ответы `4XX`/`5XX` в формате ProblemDetail, в схеме `Problem` — коды `InputError` и все коды из enum ошибок сервиса (`platform.openapi.error-codes`).

- **Наблюдаемость** (с 1.1.0): метрики для Prometheus с меткой `application` (сервис открывает `/actuator/prometheus` в `management.endpoints.web.exposure.include`), трассировка OpenTelemetry → OTLP. Куда слать трассы (`management.opentelemetry.tracing.export.otlp.endpoint`), долю запросов и JSON-логи (`logging.structured.format.console: ecs`, с `traceId`) задаёт окружение — в кластере `payments-deploy/envs/prod/env.yaml`; локально адреса нет — трассы не отправляются, логи обычным текстом. Kafka: payment публикует со своей трассой (`spring.kafka.template.observation-enabled`), history и biller продолжают её (`spring.kafka.listener.observation-enabled`). Outbox публикует по расписанию, поэтому событие — отдельная трасса, не продолжение HTTP-запроса.

Тайм-ауты HTTP-клиентов по умолчанию — `spring.http.clients.connect-timeout` / `read-timeout` (1 с / 5 с).

## Здоровье и Swagger

- У каждого сервиса Actuator: `/actuator/health/liveness` (процесс жив) и `/actuator/health/readiness` (готов: на месте его БД и Redis — `management.endpoint.health.group.readiness.include`). По readiness — healthcheck в compose (`docker compose ps` показывает `healthy`), потом — пробы Kubernetes. Остановка плавная (по умолчанию в Spring Boot): новые запросы не принимаем, текущие дорабатывают.
- Swagger UI — `http://localhost:<порт>/swagger-ui.html`, спецификация — `/v3/api-docs`. У account две группы: «Публичный API» и «Для сервисов» (`/api/internal/**`). Выключить (прод) — `SWAGGER_ENABLED=false`.
- Redis недоступен — отказ за 1–2 с (`spring.data.redis.connect-timeout` / `timeout`): кэш идёт мимо, readiness — DOWN, liveness — UP.
- compose: autopayments стартует, когда готовы account, pricing, payment и biller (`depends_on: service_healthy`). Образы собираются параллельно с общим кэшем `~/.m2` — в Dockerfile включены файловые блокировки Maven (`MAVEN_ARGS`).

## Платёж по СБП и по карте (сага)

`POST /api/payments` (payment) — заголовки `X-User-Id` (ставит gateway из токена Keycloak) и `X-Idempotency-Key`.

**Устройство payment.** Контроллер только принимает запрос; приём — `create/PaymentService` (ключ идемпотентности → котировка → подготовка → создание → сага). Подготовка своего вида — `PaymentPreparer` на каждый тип (`SbpPreparer`, `CardTransferPreparer`, `OwnTransferPreparer`, `WalletTransferPreparer`, `RequisitesPreparer`, `BillPreparer`, `AbroadPreparer`): проверка полей, получатель, реквизиты. Новый тип платежа — новый класс. Ошибки — enum `PaymentError`. Соседи — HTTP-интерфейсы (`client/*Api`, группы `spring.http.serviceclient.*`) через `ResilientCalls`: перевод в процессинг и оплату у поставщика повторяем только при ошибке соединения. Настройки — `payment.*` (минимальная сумма, БИК нашего банка, правила округления, группы с отложенным расчётом — пожертвования, пороги RecoveryJob).

**Устройство pricing.** Комиссия — `CommissionService`, курс за рубеж — `FxService`, условия счёта — `TariffService` (разделы — enum `TariffSection`). Профиль из account (подписка и счета) — в кэше Redis на 30 с (`account/AccountDirectory`); если счёта в кэше нет (карту только что привязали), профиль перечитывается мимо кэша. Группа поставщика из biller — в кэше на 1 ч. Тарифы и курсы — `@Immutable` (меняются только миграциями); кэша второго уровня нет — без замеров нагрузки он не нужен. Соседи — `client/*Api` через `ResilientCalls`; сбой — `ACCOUNT_UNAVAILABLE` / `BILLER_UNAVAILABLE` (503). Ошибки — enum `PricingError`. Срок котировки — `quote.ttl`.

1. **Котировка.** Фронтенд через 0,5 с после ввода суммы запрашивает в pricing комиссию. Pricing берёт подписку и счета из account, определяет «откуда» (кошелёк или карта) и «куда» (СБП; для перевода по карте — наша карта или карта другого банка, это pricing спрашивает у account) и возвращает расчёт и `quoteToken`: HMAC-подпись поверх `quoteId`, пользователя, счёта, вида операции, назначения, хеша реквизита получателя, суммы, комиссии, тарифа и срока (`quote.ttl`, 10 минут). Для перевода по карте комиссию считаем, только когда номер карты введён полностью.
2. **Payment: подготовка.**
   - Захватывает ключ идемпотентности (`INSERT … ON CONFLICT DO NOTHING`).
   - Проверяет котировку локально: подпись, срок, совпадение с запросом (в том числе карта получателя — по хешу). Каждую котировку можно использовать один раз — на `quote_id` стоит уникальный индекс.
   - Проверяет реквизиты.
   - Ищет получателя в account (по телефону или номеру карты). Наш клиент → запоминаем его карту для зачисления: по телефону — карту **по умолчанию**, по номеру карты — эту карту. Не наш → перевод во внешний банк.
   - Банк для СБП: выбран из списка → он; не выбран или вписан не из списка → **банк по умолчанию получателя** из его профиля. Получатель не наш и банк не выбран → 422 `RECIPIENT_BANK_UNKNOWN`.
   - Создаёт платёж `CREATED` с комиссией, тарифом, сторонами и сообщением получателю.
3. **Account: резерв.** Одна транзакция:
   - `SELECT FOR UPDATE` пользователя и счёта;
   - проверка владельца, статуса и валюты счёта;
   - лимиты пользователя на вид операции (операция / день / месяц);
   - лимиты счёта списания: максимальная сумма платежа и оборот за календарный месяц (вместе с комиссией);
   - лимит счёта получателя (наш клиент): максимальный остаток — проверяем здесь, потому что после процессинга отказать в зачислении уже нельзя;
   - резерв на сумму вместе с комиссией.

   Бизнес-отказ (нет денег, лимит) → `FAILED`, откатывать нечего.
4. **Fraud.** `REJECTED` или таймаут → `COMPENSATING`: снимаем резерв, затем `FAILED`.
5. **Processing.** Перед вызовом ставим `SENT_TO_PROCESSING`.
   - `DECLINED` → снимаем резерв.
   - `IN_PROGRESS` → **долгий перевод**: `ACCEPTED`, деньги остаются в резерве (см. ниже).
   - Таймаут → спрашиваем статус перевода в processing; используем только найденный итог, остальное решит `RecoveryJob`.
6. **Подтверждение.** `CONFIRMING` → account в одной транзакции переводит резерв в списание и, если получатель наш клиент, зачисляет ему сумму (без комиссии); оба движения — в журнал `account_operations` → `SUCCESS`. В outbox уходит событие `PaymentSucceeded` или `PaymentFailed`.
7. **История.** history читает `PaymentSucceeded` и пишет списание отправителю и поступление получателю (если он наш). Событие несёт данные (имена, названия счетов, суммы), тексты ленты собирает history (`ingest/PaymentEventMapper`, тексты — enum `OperationText`): «На …» / «С …» у перевода между своими счетами, «Округление на пользу · …», «1,75 USD · ARARAT BANK». Событие — типизированный `ingest/PaymentEvent`; тип платежа и группа поставщика — строками, категория по ним — `PaymentCategories` (неизвестный тип — «Другое», чтение событий не падает). Длина пометки и размер страницы ленты — `history.*`, ошибки — `HistoryError`.

Ответ: `200` — платёж завершён (`SUCCESS` или `FAILED`), `202` — ещё идёт; фронтенд опрашивает `GET /api/payments/{id}` (до `SUCCESS`, `FAILED` или `ACCEPTED`). Повтор с тем же ключом возвращает тот же платёж, без второго списания.

### Долгие платежи (`ACCEPTED`)

Перевод, исход которого от нас не зависит и придёт не сразу: за рубеж (`ABROAD`), пополнение со своего счёта в другом банке по СБП (там клиент подтверждает списание; `payments.source_bank_id`), подписка через партнёра (ChatGPT). Процессинг или шлюз поставщика отвечает `IN_PROGRESS` / `PENDING` → платёж `ACCEPTED` («принят, итог придёт позже»), деньги в резерве, фронтенд перестаёт опрашивать и показывает «Перевод принят».
- **Итог процессинг присылает сам**: `POST /api/internal/processing/results` `{paymentId, status, externalId, reason}` (payment). Процессинг — внешняя система, в нашу Kafka его не пускают, поэтому HTTP; уведомление идемпотентно — опоздавший или повторный итог ничего не меняет, при гонке с RecoveryJob — 503, процессинг повторит.
- **Подстраховка**: RecoveryJob раз в `payment.recovery.accepted-check-after` (1 мин) спрашивает статус. Для BILL уведомлений нет — biller дозапрашивает итог у шлюза при запросе статуса.
- Заглушки: процессинг — долгие типы и пополнение по СБП (`processing.async.*`, итог через 20–40 с, очередь в Redis `processing:pending`, повтор уведомления до 5 раз); шлюз — поставщики из `providers.async.providers` (итог через 30 с).

### Входящий перевод по СБП (`INCOMING_SBP`)

В другом банке отправили деньги на телефон нашего клиента. СБП (через процессинг) вызывает `POST /api/internal/sbp/incoming` (payment) `{operationId, senderName, senderBankId, recipientPhone, amount, message}`:
1. Повтор с тем же `operationId` (номер операции СБП, уникальный индекс `payments_incoming_once_uq`) возвращает тот же итог.
2. Получатель — по телефону в account; счёт — карта для входящих (`is_default`), иначе «Мой кошелёк». Нет такого клиента → 404 `RECIPIENT_NOT_FOUND`.
3. Платёж `CREATED` → account `POST /api/internal/credits` (зачисление + запись в журнал, проверки: счёт клиента, активен, валюта, максимальный остаток кошелька по идентификации) → `SUCCESS` / `FAILED`.
4. Ответ: `{decision: CREDITED | DECLINED}`; account недоступен → 503, СБП повторит (и RecoveryJob тоже).
5. В истории — только поступление у получателя.

Эмуляция: `POST /api/processing/sbp/incoming` (processing) `{senderName, senderBankId, recipientPhone, amount, message, operationId?}`.

### Между своими счетами (`OWN_TRANSFER`)

Если списываем со своего счёта в нашем банке, деньги не покидают банк, поэтому без антифрода и процессинга и **одной операцией** в account: `CREATED → SUCCESS` (`POST /api/internal/transfers`). В одной транзакции — те же проверки, что у резерва (лимиты, максимальный остаток счёта зачисления, запреты уровня идентификации), списание и зачисление; счета блокируются в порядке id (встречные переводы не взаимоблокируются). Промежуточного состояния «деньги в резерве, а account упал» нет. Вызов идемпотентен по `paymentId`: при сбое связи платёж остаётся `CREATED`, RecoveryJob повторит перевод. Так же — перевод в «Мой кошелёк» другого клиента (`WALLET_TRANSFER`). Счёт зачисления — любой свой, в том числе «Мой кошелёк»; чужой account отклонит (`RECIPIENT_INVALID`). Котировка привязана к счёту зачисления. Идемпотентность и RecoveryJob — как у остальных платежей. В истории две операции у одного пользователя: «На Мой кошелёк» (списание с комиссией) и «С Зарплатная WEEKEND ·· 3752» (зачисление).

Исключение — привязанная карта другого банка с любой стороны (списание с неё или зачисление на неё): деньги двигает процессинг, поэтому такой перевод идёт полной сагой (антифрод → процессинг → списание/зачисление). Признаки — `payments.source_external` / `destination_external`. Зачисление на свою привязанную карту в нашей истории не показывается как поступление — только списание с кошелька/карты.

Пополнение «Моего кошелька» со своих карт (наших и привязанных) — без комиссии.

### Привязанные карты и инструмент оплаты по умолчанию

- **Номера карт.** Открыто не храним: у наших карт — `card_number_hash` (HMAC-SHA256, по нему ищем получателя и проверяем «наша ли карта») и `card_number_encrypted` (AES-256-GCM); у карт других банков — только `card_fingerprint` (HMAC). У каждой записи — id ключа (`card_key_id`, `fingerprint_key_id`). Ключи — `account.card.keys.<id>` (`v1` — `CARD_HMAC_KEY`, `CARD_ENCRYPTION_KEY` из `.env`), текущий — `CARD_CURRENT_KEY`. **Ротация:** добавить `ACCOUNT_CARD_KEYS_V2_HMAC`, `ACCOUNT_CARD_KEYS_V2_ENCRYPTION`, `CARD_CURRENT_KEY=v2` → при старте `CardKeyRotation` расшифрует номера наших карт старым ключом и защитит новым (пачками, `SKIP LOCKED`); поиск идёт по отпечаткам всеми ключами. Отпечаток карты другого банка (номера нет) переводится на новый ключ при следующей встрече с картой; пока такие есть, старый ключ нужен — счётчик в логе при старте. Шифр нужен именно для ротации: без номера отпечаток новым ключом не посчитать.
- **Привязанная карта другого банка** (`accounts.type = EXTERNAL_CARD`) — только источник списания. Баланс нам неизвестен (`balance`/`available` = `null`), деньги списывает процессинг. Храним последние 4 цифры, срок, платёжную систему (по первой цифре) и HMAC номера (чтобы не привязать одну карту дважды; у карт, привязанных до перехода на HMAC, остался старый SHA-256 — их можно привязать повторно); CVC проверяем на формат и никуда не сохраняем. Карту нашего банка привязать нельзя, максимум 5 привязанных карт. «Удалить» отвязывает карту: строка не удаляется (на неё ссылаются резервы и платежи), а получает `status = CLOSED` — такие счета не показываются и не используются; ту же карту можно привязать снова. Если карта была инструментом оплаты по умолчанию, сердечко сбрасывается. Лимиты: платёж до 100 000, 300 000 в месяц. Зачислять на неё можно только себе (перевод между своими через процессинг); по СБП с неё переводить нельзя (тарифа нет).
- **Инструмент оплаты по умолчанию** («сердечко», `users.default_payment_account_id`) — любой свой счёт, подставляется в «Списать с» во всех переводах. Не путать с картой по умолчанию для входящих переводов (`accounts.is_default`). Если сердечко не выставлено — первая карта нашего банка.

**RecoveryJob** (payment, раз в 10 с; пороги — `payment.recovery.*`) дожимает зависшие платежи. Все вызовы account и processing идемпотентны по `paymentId`, поэтому их можно повторять:
- `CONFIRMING` → повторить списание;
- `COMPENSATING` → повторить снятие резерва;
- `SENT_TO_PROCESSING` дольше 30 с → спросить статус в processing. Три исхода: итог есть → провести; **«не получали» (404)** → снять резерв; **«не удалось узнать»** (сбой связи, 5xx, открытый circuit breaker) → ждать и спросить снова: деньги могли уйти, возвращать их нельзя;
- `ACCEPTED` → раз в минуту спросить итог (подстраховка уведомления); «не получали» после «принят» — противоречие, только ошибка в лог для ручного разбора;
- `CREATED` перевода внутри банка или входящего СБП → повторить операцию в account (идемпотентна);
- остальные `CREATED`, `RESERVED` или `FRAUD_APPROVED` дольше 60 с → отменить.
Проверенный, но не сдвинутый платёж уходит в конец очереди (`updated_at` обновляется), чтобы пачка не застревала на одних и тех же.

**Ключи идемпотентности** хранятся 24 ч (`payment.idempotency.*`) — дольше, чем клиент может повторять запрос; `IdempotencyCleanup` раз в час удаляет старые пачками по 1000 (ShedLock).

### Тестовые суммы

Заглушки отвечают случайно: антифрод одобряет ~90%, процессинг проводит ~90% (доли и тестовые копейки — `fraud.*`, `processing.*`). Чтобы получить нужный сценарий, укажите копейки в сумме:

| Копейки | Что произойдёт |
|---|---|
| `.66` | антифрод отклоняет |
| `.77` | антифрод не отвечает (таймаут) |
| `.88` | процессинг отклоняет |
| `.99` | процессинг отвечает дольше таймаута, payment узнаёт результат запросом статуса → успех |

Правила лимитов и тарифов взяты из документов «Памятка об электронных денежных средствах», «Переводы за рубеж» и «Тарифы на переводы»; их наша версия — `payments-frontend/src/data/documents.ts` (страницы `/docs/emoney`, `/docs/abroad`, `/docs/tariffs`, ссылки — в блоке «Информация об оказываемых услугах» внизу главной). **Поменяли лимит или тариф — поправьте и документ.**

Лимиты и запреты — **только в БД** (account), проверяются при резерве цепочкой проверок `reservation/check/*` (порядок `@Order`: счёт списания → идентификация → получатель → лимиты операции → лимиты счёта → деньги):
- **на вид операции** (`operation_limits`, одинаковы для всех): СБП, по номеру карты, по реквизитам — от 10 ₽, до 1 000 000 ₽ за операцию и 3 000 000 ₽ в месяц; за рубеж — с кошелька (`source = WALLET`, без открытия счёта) 300 000 ₽ за операцию и 400 000 ₽ в месяц, с карт (`CARD`) — 400 000 ₽ и 3 000 000 ₽;
- **счёта**: «Мой кошелёк» — по уровню идентификации владельца (`identification_limits`); карты — `account_limits` (платёж до 1 000 000, остаток без ограничения, 3 000 000 в месяц); новая привязанная карта получает лимиты из `account_limit_defaults`;
- **израсходованное** — счётчики `operation_usage` (пользователь × вид × источник × день/месяц) и `account_usage` (оборот счёта за месяц): резерв прибавляет, снятие резерва вычитает; проверка лимита — чтение одной строки;
- **Кредитная карта** (`accounts.credit`) не пополняет электронные кошельки — ни свой, ни чужой.
- Справочники лимитов — `@Immutable` (меняются только миграциями); кэша второго уровня нет — без замеров нагрузки он не нужен.

### Уровни идентификации

`account.users.identification_level`, в профиле — `identificationLevel`. Account проверяет при резерве (группу поставщика BILL присылает payment), отказ — `IDENTIFICATION_REQUIRED`. Лимиты — `identification_limits`, запреты — `identification_restrictions` (уровень, вид операции, группа поставщика, источник, код ошибки из `AccountError`).

| Уровень | Кошелёк: платёж / остаток / в месяц | Недоступно |
|---|---|---|
| `ANONYMOUS` — только телефон | — / 15 000 / 40 000 | переводы людям (СБП, по карте, на чужой кошелёк), пополнение чужих электронных кошельков (EMONEY), за рубеж (ABROAD, зарубежная связь); кошелёк не принимает переводы от других людей |
| `SIMPLIFIED` — паспорт + СНИЛС/ИНН через Госуслуги | 60 000 / 60 000 / 200 000 | с кошелька — переводы на другие электронные кошельки (WALLET_TRANSFER, EMONEY) |
| `FULL` — офис, салон связи или ЕБС | 600 000 / 600 000 / 1 200 000 | — |

Снятия и пополнения наличными, вкладов, кредитов и резидентства (запрет переводов за рубеж нерезидентам недружественных стран) у нас нет — их ограничения не моделируем.

### Комиссии

`pricing.commission_rules` — матрица «вид операции × откуда × куда × подписка» → процент, минимум, фиксированная часть, `max_fee` (не больше) и `free_monthly_amount` (сколько в месяц без комиссии: комиссия — только с превышения; сколько уже потрачено, pricing спрашивает у account `GET /api/users/{id}/operation-usage?operationType=`). Комиссия = min(max(сумма сверх бесплатного × %, минимум) + фиксированная часть, max_fee). Нет строки — перевод недоступен.

Значения — по документу «Тарифы на переводы» (миграция `pricing/014-tariffs-document.sql`), полная таблица — `/docs/tariffs`. Главное: внутри МТС Банка 0%; с карты на карту другого банка 1,5% (мин. 50 ₽); по СБП только с карт: до 100 000 ₽ в месяц бесплатно, дальше 0,5% (мин. 1 ₽, макс. 1 500 ₽); с кошелька по СБП перевода нет; платежи с карты МТС Банка 0%, с кошелька и чужой карты — 1–3% по группе, игры — 50 ₽ с любого источника.

Подписки (`users.subscription`): `NONE`; `PREMIUM` — «Премиум», развлекательная, банковские тарифы не меняет; `BANK_PREMIUM` — «Банк Премиум», пакет банковских услуг: по СБП бесплатно до 1 500 000 ₽ в месяц, на карту другого банка — 99 ₽ за перевод. Подписка видна в профиле («Ещё»).

### Тестовые пользователи

Карта **по умолчанию** (★) — на неё приходят переводы по номеру телефона.

| Пользователь | Телефон | Подписка | Банк СБП по умолчанию | Карты |
|---|---|---|---|---|
| Артур Руднев (фронтенд работает от его имени), полная идентификация | +7 996 448 00 00 | NONE | Т-Банк | ★ Зарплатная МИР `2200 7001 2347 3752`, Кредитная Mastercard `5400 1234 0987 1006`, Накопительная МИР `2200 7001 5555 1004` |
| Мария Иванова | +7 916 123 45 67 | PREMIUM | Сбербанк | ★ Дебетовая МИР `2200 3004 5678 1002`, Зарплатная МИР `2200 3004 5679 2009`, Travel VISA `4790 1234 5678 3006` |
| Иван Петров | +7 903 111 22 33 | BANK_PREMIUM | Альфа-Банк | ★ Премиальная МИР `2202 2009 8765 1005` |
| Ольга Смирнова | +7 925 765 43 21 | NONE | ВТБ | ★ Дебетовая МИР `2202 2000 1234 4006` |
| Анна Ковалёва — без идентификации (`…0005`) | +7 977 000 11 22 | NONE | Т-Банк | — (только кошелёк, 12 000 ₽) |
| Пётр Соколов — упрощённая (`…0006`) | +7 985 000 33 44 | NONE | Т-Банк | — (только кошелёк, 50 000 ₽) |

У каждого ещё ровно один «Мой кошелёк» — только для самого пользователя: переводы от других на него не принимаются (зачислять можно только на карту), пополнить его можно переводом между своими счетами. В `account.accounts` у всех кошельков одно название — владельца видно по `user_id`.

Перевод на телефон или карту не из этого списка — во «внешний банк»: у нас только списание, зачисление — дело процессинга (заглушка).

## База данных

Одна Postgres (`payments`), у каждого сервиса **своя схема**: `account`, `pricing`, `payment`, `history`. Схемы создаёт `infra/postgres/init.sql` при первом запуске тома. Сервис ходит только в свою схему (её задаёт `spring.datasource.hikari.schema`), чужие данные получает через REST. Позже разнесём по отдельным базам.

Миграции — **Liquibase**, SQL-файлы в `payments-<сервис>/src/main/resources/db/changelog/`. Hibernate только проверяет схему (`ddl-auto: validate`).

- `account.users` — пользователь, телефон, подписка (`NONE`, `PREMIUM`, `BANK_PREMIUM`), `sbp_default_bank_id` — банк по умолчанию для входящих СБП, `default_payment_account_id` — инструмент оплаты по умолчанию, `identification_level` — идентификация владельца кошелька.
- `account.accounts` — счета: `WALLET` (ровно один у каждого), `CARD` (наш банк) и `EXTERNAL_CARD` (привязанная карта другого банка: `card_last4`, `card_expiry`, `card_fingerprint`); `is_default` — карта для входящих переводов (одна на пользователя). `balance` — реальные деньги, `reserved` — заблокированные под платежи в процессе; доступно = `balance − reserved`.
- `account.operation_limits` — лимиты на вид операции × источник (`ANY`/`WALLET`/`CARD`) × период (`SINGLE` с минимумом, `DAY`, `MONTH`).
- `account.identification_limits`, `account.identification_restrictions` — лимиты кошелька и запреты по уровню идентификации.
- `account.account_limits` — лимиты счёта: `max_payment`, `max_balance`, `max_monthly_turnover` (`NULL` — без ограничения); `account_limit_defaults` — для новых счетов по типу.
- `account.operation_usage`, `account.account_usage` — счётчики израсходованных лимитов.
- `account.reservations` — резервы под платежи (`RESERVED` → `CAPTURED` / `RELEASED`), `recipient_account_id` — карта нашего получателя; у перевода внутри банка резерв сразу `CAPTURED`. Израсходованный лимит — в счётчиках, снятые резервы его возвращают.
- `account.account_operations` — журнал движений денег: `OPENING` (остаток до появления журнала), `DEBIT`, `CREDIT`; `balance_after`. Баланс счёта = сумма его записей; уникальный индекс (платёж, счёт, вид) — одно движение платежа по счёту один раз.
- `pricing.commission_rules` — тарифы: вид операции × откуда × куда × подписка → процент, минимум, фикс, подпись для экрана условий; `id` — тариф.
- `payment.payments` — платежи и их статус; номер карты получателя хранится только маской.
- `payment.payment_status_history` — каждый шаг саги с пояснением.
- `payment.idempotency_keys` — ключи идемпотентности.
- `payment.outbox` — события до отправки в Kafka.
- `history.operations` — все операции всех пользователей: дата, счёт, направление (`INCOME`/`EXPENSE`), категория, спецификация (`title`: магазин, контрагент, «Кешбэк», «Платье»), сообщение, сумма и комиссия, валюта (`RUB`/`USD`/`EUR`) и сумма в рублях, кешбэк, программа лояльности (`CASHBACK`/`PREMIUM`/`DISCOUNT`), контрагент-клиент.
  Плюс детали для карточки и чека: `mcc` (по умолчанию из категории), `discount`, `transaction_code` (12 цифр; у платежа одинаковый у отправителя и получателя).
- `history.categories` — справочник категорий и MCC по умолчанию (`default_mcc`).

В history ~320 тестовых операций за 4 месяца (`002-seed-operations.sql`, сгенерированы скриптом; даты — относительно момента создания базы). С балансами счетов они не сверяются — это демо-данные.

## Kafka

Сервисы пишут события в outbox в той же транзакции, что и данные. Планировщик раз в секунду публикует их в Kafka (`SKIP LOCKED`, гарантия «хотя бы один раз»). Имена топиков, партиции и реплики — в `application.yml` (`messaging.*`), у всех топиков 3 партиции, консьюмеры читают в 3 потока (`spring.kafka.listener.concurrency`). Данные Kafka — в томе `kafkadata`. Не обработанное после повторов сообщение — в DLT своей группы (`payment.events.history-dlt`, `payment.events.biller-dlt`, `payment.events.biller-charity-dlt`).

Redis (`localhost:6379`) — блокировки планировщиков; кэш: профиль и группы поставщиков в pricing; итоги заглушек (процессинг `processing:transfer:*`, `processing:charity:*`, очередь долгих переводов `processing:pending`, шлюзы `providers:payment:*`, `providers:pending:*`) — через `IdempotentResults` из платформы: первый записанный итог побеждает (`SET NX`), TTL 7 дней, переживают рестарт и одни на все поды.

- `payment.events` — `PaymentSucceeded`, `PaymentFailed`

account в Kafka не пишет (события резервов никто не читал — убрали) и не использует Redis: ему нужна только Postgres.

`payment.events` читает history (группа `history`). Смотреть сообщения: Kafka UI на http://localhost:8090. С компьютера Kafka доступна на `localhost:29092`.

## API

- account
  - `GET /api/users/{userId}` — профиль, подписка, счета
  - `GET /api/users/{userId}/accounts` — счета (`balance`, `available`, `limits`)
  - `POST /api/internal/reservations` — зарезервировать; `POST /api/internal/reservations/{paymentId}/capture` и `…/release`
  - `GET /api/internal/recipients?phone=…` / `?cardNumber=…` — наш ли клиент получатель и на какую карту зачислять
  - `POST /api/users/{userId}/linked-cards` `{cardNumber, expiry: "MM/YY", cvc}` — привязать карту другого банка; `DELETE /api/users/{userId}/linked-cards/{accountId}` — отвязать
  - `PUT /api/users/{userId}/default-payment-account` `{accountId}` — инструмент оплаты по умолчанию
- pricing
  - `POST /api/pricing/commission` `{userId, sourceAccountId, operationType, amount, recipientCardNumber?, destinationAccountId?}` → комиссия + `quoteToken`. `operationType`: `SBP_PHONE`, `CARD2CARD` (нужен `recipientCardNumber`), `OWN_TRANSFER` (нужен `destinationAccountId`), `ABROAD`, `QR`.
  - `GET /api/pricing/tariffs?userId=…&account=WALLET` — комиссии для экрана «Лимиты и условия счёта» по подписке пользователя: разделы, в каждом `outgoing` («с кошелька») и `incoming` («на кошелёк»).
- payment — `POST /api/payments` (`type`: `SBP_PHONE`, `CARD2CARD`, `OWN_TRANSFER` + `destinationAccountId`), `GET /api/payments/{id}`
- fraud — `POST /api/fraud/check`
- processing — `POST /api/processing/transfers`, `GET /api/processing/transfers/{paymentId}`
- history (заголовок `X-User-Id`)
  - `GET /api/history/operations` — лента с пагинацией по курсору (`limit`, следующая страница — `cursor=<nextCursor>`). Фильтры: `accountId`, `from`/`to` (даты, включительно, по Москве), `direction`, `category` (несколько), `loyalty`, `currency`, `counterpartyId` (переводы от/к конкретному клиенту).
  - `GET /api/history/summary?month=2026-11&direction=EXPENSE` — итог за месяц и разбивка по категориям (без переводов между своими счетами — это не расход и не доход); с `category=…` — разбивка внутри категории по магазинам/контрагентам; с `title=…` — только этот магазин/контрагент. В ответе `previousMonth`/`nextMonth` для листания. Сами операции — через `/operations` с теми же фильтрами (`title` там тоже есть).
  - `GET /api/history/operations/{id}` — карточка операции (чужую не отдаёт — 404)
  - `GET /api/history/categories` — справочник категорий

Фронтенд ходит в API только через **payments-gateway**: локально прокси Vite отправляет весь `/api` в gateway (`localhost:8080`), в кластере `/api` ведёт в gateway вход (Traefik). Gateway разводит запросы по сервисам (маршруты — его `application.yml`); `/api/internal/**` наружу не отдаёт — сервисы вызывают его друг у друга напрямую. **Вход — Keycloak** (OpenID Connect, Authorization Code + PKCE): фронтенд (`src/auth.ts`, oidc-client-ts) без токена отправляет на страницу входа `/auth` — тот же хост (в кластере маршрут Traefik, локально прокси Vite → Keycloak из compose). Каждый запрос в API — с `Authorization: Bearer <access-токен>` (5 минут, продлевается по refresh-токену). Gateway проверяет токен (подпись, срок, `iss`, `aud = payments-api`), ставит сервисам `X-User-Id` из claim `sub` (присланный клиентом выбрасывает), чужой id в пути, параметре или теле — 403, лимит 20 запросов/с на пользователя (Redis) — 429. Сервисы токен не проверяют и доверяют `X-User-Id`. Пользователь — `artur` (id `00000000-0000-0000-0000-000000000001` = id в account); пароль локально — `DEMO_PASSWORD` в `.env`, в кластере — `kubectl -n keycloak get secret keycloak -o jsonpath='{.data.demo-password}' | base64 -d`.

## Kubernetes (окружение)

Одно окружение `prod` — локальный кластер k3d (k3s в Docker), всё описано в `payments-deploy` (подробно — его README). Argo CD внутри кластера раз в минуту сверяет кластер с `main` `payments-deploy` и приводит к описанию (GitOps): руками в кластере ничего не меняем.
- Раскладка: шаблоны — `charts/java-service` (Deployment с пробами liveness/readiness/startup, памятью и обновлением без простоя, Service, HTTPRoute, ServiceMonitor) и `charts/frontend`; общее для сервиса во всех окружениях — `services/<сервис>.yaml`; общее для компонентов платформы — `platform/<компонент>/values.yaml`; **всё, чем отличается окружение, — `envs/prod/`**: приложения Argo CD (`apps/`: ApplicationSet сервисов, инфраструктура, платформа), общие настройки сервисов (`env.yaml`), версии образов, число подов и память (`services/`), настройки платформы (`platform/`). Базы и брокер — `infra/`.
- Вход: Traefik (Ingress-контроллер, ставит Argo CD) по правилам Gateway API (Gateway `external` + HTTPRoute): `payments.localhost/api` → gateway → сервисы, `payments.localhost/auth` → Keycloak, `payments.localhost/` → фронтенд.
- Наблюдаемость (namespace `monitoring`): Prometheus + Grafana (kube-prometheus-stack, свои дашборды «Payments — сервисы» и «Безопасность и платформа»), логи — Loki + Alloy, трассы — Jaeger. Тревоги: правила (`platform/kube-prometheus-stack/manifests/rules-payments.yaml` + готовые kube-prometheus) → Alertmanager → Telegram-бот (`scripts/telegram.sh`).
- Безопасность: Keycloak (namespace `keycloak`); сервисная сетка Istio ambient — mTLS STRICT между подами и AuthorizationPolicy «кто кому звонит» (`platform/mesh`: новый вызов между сервисами — добавить отправителя туда), NetworkPolicy по namespace; секреты — Vault + External Secrets.
- Адреса: приложение http://payments.localhost, Argo CD http://argocd.localhost, Grafana http://grafana.localhost, Prometheus http://prometheus.localhost, Alertmanager http://alertmanager.localhost, Jaeger http://jaeger.localhost, Vault http://vault.localhost, панель Traefik http://traefik.localhost/dashboard/. Swagger и внутренние API — `kubectl -n payments port-forward svc/<сервис> <порт>`.
- Секреты — в Vault: `payments-deploy/scripts/secrets.sh` кладёт туда ключи из `payments-local/.env` и создаёт пароли, External Secrets переносит их в Kubernetes; в git их нет.
- Кластер и compose вместе в память не помещаются: `docker compose stop` перед `payments-deploy/scripts/cluster-up.sh`, `k3d cluster stop payments` перед `scripts/up.sh`.

## Запуск

Java и Node на компьютер ставить не нужно — всё собирается и работает в Docker.

Секреты — в `payments-local/.env` (в git не попадает): `cp .env.example .env` и заполнить (`openssl rand -base64 32`). Без них compose не запустится. Пароли Keycloak (`KEYCLOAK_ADMIN_PASSWORD`, `DEMO_PASSWORD`) `scripts/up.sh` создаёт сам. Вход в приложение на http://localhost:5173 — `artur` и `DEMO_PASSWORD` из `.env`; админка Keycloak — http://localhost:8180/auth/admin (`admin`, `KEYCLOAK_ADMIN_PASSWORD`).

Токен для скачивания `payments-platform` (право `read:packages`): `scripts/up.sh` берёт его из `gh auth token`, либо задайте `GITHUB_TOKEN` в `.env`.

Тесты сервиса: unit — `mvn test`, интеграционные `*IT` на Testcontainers — `mvn verify`, нужен Docker. При сборке образа тесты не запускаются — их прогоняет CI. Из папки сервиса:
```bash
docker run --rm -v "$PWD":/src -v payments-m2:/root/.m2 -v /var/run/docker.sock:/var/run/docker.sock -e TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal -e GITHUB_TOKEN=$(gh auth token) -w /src maven:3.9-eclipse-temurin-21 mvn -B -s .mvn/settings.xml verify
```

Из `payments-local`:
```bash
scripts/up.sh                  # поднять всё (собрать образы из соседних папок)
scripts/up.sh payment          # пересобрать и перезапустить один сервис
docker compose logs -f payment # логи сервиса
docker compose down            # остановить (данные БД сохраняются в volume)
docker compose down -v         # остановить и стереть БД (пересоздастся из миграций)
```

Postgres с компьютера: `localhost:5433`, база `payments`, `payments` / `payments`.

После изменения `package.json` — `scripts/up.sh --renew-anon-volumes web`.

## Страницы

Весь интерфейс — в масштабе 80% (`html { zoom: 0.8 }` в `styles.css`; на время снимка для PDF масштаб снимается в `pdf.ts`). Иконка вкладки — `frontend/public/favicon.svg` («Pay», как в шапке).

- `/` — Платежи и переводы. Переключатель «Платежи / Переводы» (`/?tab=transfers`). Слева блоки «Кошельки» и «Карты» сворачиваются (состояние запоминается в браузере).
- `/cards` — «Счета и карты» (из левой панели: клик по любой карте или «Привязать карту другого банка»). Страница во всю ширину, без левой панели; сверху «‹ Назад». В блоке кошелька: «Пополнить» → `/wallet/topup`, «Перевести» → `/wallet/transfer`, «Оплатить» → главная, «Справка по счёту». У привязанных карт есть «Удалить» (с подтверждением). В левой панели привязанная карта — «Карта *1111» со значком связи и маской номера вместо баланса. «Мой кошелёк» (номер, баланс, идентификация, действия) и все карты — наши и привязанные — с балансом и кнопками «Пополнить / Оплатить / Перевести» (ведут на переводы). «Добавить карту» — окно привязки. Сердечко — инструмент оплаты по умолчанию, при наведении подсказка.
- `/wallet/topup` — «Пополнить кошелёк»: «Откуда списать» (окно со своими картами и «Новая карта» — привязка), фиксированное «на Мой кошелёк», сумма. Без комиссии.
- `/wallet/transfer` — «Между своими» с кошелька: «Куда перевести» (свои карты, наши и других банков, «Новая карта»), сумма, комиссия.
- Справка по счёту («Счета и карты» → «Справка по счёту»): выбор даты или периода в календаре → PDF «Справка по счёту «Мой Кошелёк»» (реквизиты счёта и таблица операций за период, многостраничный A4). Номер счёта — `accounts.account_number` (20 цифр).
- `/wallet` — «Мой кошелёк» (из левой панели по клику на кошелёк): баланс, телефон, «Пополнить» (перевод между своими счетами с кошельком в «Зачислить на»), «Перевести», три последние операции по кошельку и «Посмотреть все» (история с фильтром по кошельку), «Информация», частые вопросы.
- `/wallet/conditions` — «Лимиты и условия счёта»: «Лимиты счёта» и комиссии по разделам в модальных окнах (с переключателем «С кошелька / На кошелёк»).
- `/transfers/phone`, `/transfers/card` — переводы по СБП и по карте, проходят через сагу. Банк получателя — из списка с логотипами (`payments-frontend/src/data/banks.ts`) или любой текст: не из списка → банк по умолчанию получателя. Логотипы — favicon сайтов банков через сервис Google, если его нет — буква на цветном фоне.
- `/transfers/own` — между своими счетами, через payment и account (без антифрода и процессинга). `?to=wallet` — кошелёк уже выбран в «Зачислить на» (так открывает «Пополнить»).
- `/history/:id` — карточка операции: сумма, статус, дата, «Детали операции» (кешбэк, категория, MCC, получатель/отправитель, сумма, комиссия, скидка, счёт, сообщение, код транзакции) и «Сохранить чек» — окно с чеком и «Скачать чек». PDF собирается в браузере (`html2canvas` снимает бланк чека, `jspdf` кладёт снимок на страницу A5); текст в PDF — картинка. Для продакшена чеки лучше генерировать на сервере.
- `/history/analytics?direction=EXPENSE|INCOME&month=&category=&title=` — «Аналитика финансов»: вкладки «Расходы / Доходы», итог за месяц, кольцевая диаграмма с листанием месяцев, чипы с суммами; клик по сегменту или чипу проваливается: категории → магазины/люди → операции. Фильтры показаны чипами с «×». Цвета — 7 слотов проверенной палитры, закреплены за категорией по её порядку в справочнике (не по сумме), всё сверх — в серое «Остальное».
- `/history` — сверху плитки «Расходы / Доходы» за текущий месяц (ведут в аналитику), ниже история из сервиса history (клик по операции открывает её карточку): по дням, бесконечная прокрутка, кнопка «Фильтры» (карта/счёт, период: неделя / месяц / свой, поступления/списания, категории, программа лояльности, валюта). Дни — по московскому времени, как на сервере.
- `/more` — вкладка «Ещё» в шапке: профиль (аватар с инициалами, ФИО, телефон) и список функций. Пока одна — «Округление платежей» (`/more/roundup`).

## Известные упрощения

- Если запрос резервирования дошёл до account уже после того, как payment по таймауту снял резерв, резерв останется висеть. Лечится «надгробием» в account — записью о снятии до прихода резерва.
- Все сервисы ходят в Postgres одним пользователем `payments`; в идеале — своя база на сервис, пока не делаем из-за ресурсов.
- Миграции схемы базы лежат в репозиториях сервисов, а `infra/postgres/init.sql` (создание схем) — в `payments-local`: новый сервис со своей схемой — правка в обоих.

## Переводы за рубеж (`ABROAD`)

- **biller** (схема `biller`): `countries` (251 страна: названия из CLDR по-русски и на местном языке; нет России и направлений, куда перевести нельзя — КНДР, Иран, Сирия, Куба, Украина, Афганистан), `country_currencies` (популярным — местная валюта, RUB, USD; остальным — USD, еврозоне — EUR+USD), `transfer_methods` (местные банки и кошельки для популярных стран, Visa/Mastercard/SEPA/SWIFT для остальных), `field_templates` + `template_fields` — какие поля получателя спрашивать и как их проверять (карта; карта+имя; телефон; IBAN+имя; счёт+SWIFT; счёт+IFSC; UPI). Сид генерируется скриптом. У каждого способа — пределы суммы одного перевода в ₽ (`min_amount`, `max_amount`: на карту 100–150 000, по телефону 100–100 000, на счёт 1 000–1 000 000, в кошелёк 100–50 000). API: `GET /api/biller/countries`, `/countries/{code}` — способы сразу с полями получателя и пределами (форма строится одним запросом), `/methods/{id}` — для payment.
- **pricing**: `exchange_rates` — курс ЦБ и наценка, `sell_rate` считает база (пока статично). `POST /api/pricing/fx-quote` `{userId, sourceAccountId, currency, amountRub | receiveAmount}` — пересчёт в обе стороны (к получению округляем вниз, списание — вверх), комиссия 0, подписанная котировка с валютой, суммой к получению и курсом.
- **payment**: проверяет по biller, что способ из этой страны, сумма в его пределах (`METHOD_AMOUNT_RANGE`), валюта доступна, поля заполнены по шаблону; котировка — на ту же сумму к получению. Дальше сага (антифрод → процессинг); перевод за рубеж долгий — `ACCEPTED`, итог приходит уведомлением. Данные получателя — `payments.recipient_details` (JSON, карта маской).
- Фронтенд `/transfers/abroad`: страна (поиск, флаги) → откуда → валюта → суммы (пересчёт через 0,5 с) → способ (поиск, фильтр по типу, курс и итог) → «Данные получателя» по полям шаблона → перевод.

## На кошелёк, по реквизитам, госуслуги

- **Минимум 10 ₽** у любого платежа (проверяет payment). Под суммой во всех формах — «От 10 ₽ до …»: меньший из лимитов на одну операцию этого вида (`GET /api/users/{id}/operation-limits`) и на платёж со счёта.
- **СБП: банк получателя.** Справочник НСПК «телефон → банки, где есть счёт» — заглушка в processing (`GET /api/processing/sbp/banks?phone=`; у тестовых пользователей наборы фиксированные, у остальных номеров — стабильные «случайные»). Фронтенд спрашивает его через `GET /api/payments/sbp/banks` параллельно с расчётом комиссии и сразу пишет «У получателя нет счёта в этом банке. Есть в: …»; payment перепроверяет при создании платежа (422 `RECIPIENT_BANK_NOT_FOUND`).
- **На кошелёк** (`WALLET_TRANSFER`, `/transfers/wallet`) — на «Мой кошелёк» другого клиента по телефону. Внутренний платёж: payment → account, без антифрода и процессинга, 1%. На свой кошелёк — нельзя (для этого «между своими»).
- **Свободные реквизиты** (`/transfers/requisites`):
  - **Оплата по УИН** (`BILL`, поставщик `uin`): biller по УИН спрашивает ГИС ГМП (заглушка `providers`; УИН на 0 — начислений нет, штрафы ГИБДД первые 20 дней — со скидкой 50%) и сохраняет начисления в `biller.gov_charges`. Payment сверяет сумму и получателя с начислением в biller, а не с запросом; одно начисление — один живой платёж. После успешной оплаты biller (читает `payment.events`) помечает начисление `PAID`. Комиссия 0%.
  - **Юрлицу в другой банк** (`REQUISITES`, 1%, мин. 30 ₽) и **юрлицу в нашем банке** (`REQUISITES_OUR`, 0,5%, БИК `044525999` подставлен). Реквизиты проверяются по правилам ЦБ/ФНС: ключ счёта по БИК, контрольные числа ИНН, КПП (у ИП не нужен). Хранятся в платеже (`payments.recipient_details` + `purpose`), отдельного справочника не нужно.
  - Тестовые реквизиты: счёт `40702810938000012345` + БИК `044525225`; счёт в нашем банке `40702810700000004567`; ИНН ООО `7707123458`, ИНН ИП `771234567859`, КПП `770701001`.
- **Поставщики в biller**: общая `providers` (группа, код для ссылок, название, заголовок формы, юрлицо, сайт для логотипа, код интеграции) + таблица группы: `gov_providers` (госуслуги), `mobile_providers` (связь). Группы ЖКХ, интернет, игры заведены в `provider_groups` — их таблицы появятся вместе с оплатами.

## Шаблоны и автоплатежи (сервис autopayments)

**Устройство autopayments.** Соседи — HTTP-интерфейсы `client/*Api` через `ResilientCalls` и обёртки `AccountClient`, `BillerClient`, `PricingClient`, `PaymentClient` с типизированными запросами; отказ соседа (4xx) — `DomainException` его текстом, платёж в payment повторяем только при ошибке соединения. SQL — в репозиториях (`TemplateRepository`, `AutopaymentRepository`, `TopupRepository`), сервисы — правила. Статусы, виды расписаний и пополнений — enum (`Status`, `RunStatus`, `ScheduleKind`, `TopupKind`, `SourceKind`), ошибки — `AutopaymentsError`, итоги запусков — `RunMessage`. Проверка расписания — `ScheduleRules`, решение «пополнять ли и на сколько» — `TopupPlan`. Планировщик забирает пачку (`autopay.batch-size`) с бронью на `autopay.claim-for` и проводит её параллельно (`autopay.parallelism`); не довёл — запись вернётся в работу, когда истечёт бронь. Настройки — `autopay.*` (минимум суммы, пределы расписания, длина названий, паузы автопополнения).

- Схема `autopayments`: `templates`, `autopayments`, `autopayment_runs`. API (`X-User-Id`): `GET/POST /api/autopayments/templates`, `GET/PUT/DELETE /api/autopayments/templates/{id}`; `GET/POST /api/autopayments`, `GET /api/autopayments/{id}` (с историей запусков), `PATCH /api/autopayments/{id}` `{status: ACTIVE|PAUSED}`, `DELETE /api/autopayments/{id}`.
- Шаблон и автоплатёж — платёж поставщику (`BILL`): `providerCode` + поля + сумма. При сохранении проверяем как настоящий платёж: biller `POST /api/biller/bills/check` (поля, сумма, номинал, оператор по номеру) и account (счета пользователя, не карта другого банка). Подходит любой поставщик: у госуслуг, ГИС ЖКХ и Образования Москвы платим сумму плательщика без найденного счёта (biller: госуслуги — на реквизиты администратора из `gov_providers`, налоги — ЕНП; ГИС ЖКХ — по всем полям поставщика). Такой шаблон открывается на своей странице оплаты `/templates/{id}/pay`.
- Расписание: `MONTHLY` — каждый месяц в `day_of_month` (в коротком месяце — в последний день); `PERIOD` — каждые `period_days` (1–180) с `start_date`. Планировщик (`autopay.interval`, 30 с; день — по Москве) бронирует активные с `next_run_date <= сегодня`, создаёт запуск (уникален по автоплатежу и дате), получает котировку в pricing и платит в payment с ключом идемпотентности `auto:<запуск>:<счёт>` — повтор после сбоя не спишет дважды. Не хватило денег на основном (`INSUFFICIENT_FUNDS`) — вся сумма с запасного счёта. Сервис недоступен — запуск остаётся `PENDING` и повторится, когда истечёт бронь.
- **Автопополнение** своего счёта (`topups`, `topup_runs`; API `/api/autopayments/topups`): откуда — свой кошелёк/карта или «Ваш счёт в другом банке» (по СБП, без комиссии: в account это счёт `EXTERNAL_SBP` с банком-участником, деньги забирает процессинг, как с привязанной карты); куда — свой кошелёк или карта. Платёж — `OWN_TRANSFER`. Типы: `MONTHLY` — каждое N-е число на сумму; `BY_BALANCE` — когда баланс счёта зачисления ≤ порога, на сумму; `CONSTANT_BALANCE` — когда баланс < целевого, на разницу. Лимит в месяц — для двух последних (по балансу: не пополняем, если сумма не влезает; постоянный — пополняем на остаток). Планировщик проверяет баланс в account каждые 30 с; после пополнения — пауза `autopay.topup.after-success` (1 мин), после отказа — `after-failure` (30 мин). Фронтенд: `/topups/new` (откуда / куда / название / тип), карточка `/topups/{id}`.
- Фронтенд: на главной — лента «Шаблоны и автоплатежи» (шаблоны, автоплатежи со значком календаря, «Создать новый») и «Все» → `/templates`. «Создать новый» → «Шаблон платежа» (`/templates/new` → категория → поставщик → `/templates/new/{код}`: название, откуда списать, поля, сумма) или «Автоплатёж» (`/autopayments/new` → … → мастер `/autopayments/new/{код}`: данные → вид → дата → сумма → основной и запасной счёт). Шаблон открывает форму оплаты с подставленными данными (`?template=<id>`), карточка автоплатежа `/autopayments/{id}` — пауза, удаление, история.

## Платежи

**Устройство biller.** Проверка платежа поставщику (`BillService`) выбирает первый подходящий `BillMethod` по `@Order`: `MobileBill` (оператор по номеру), `GovFeeBill` (квитанция без начисления, Росреестр), `GovChargeBill` (найденное начисление), `GovDirectBill` (госуслуга на реквизиты администратора), `FieldsBill` (остальные — поля по шаблону). Поля проверяет `FieldValidator`. Группы, типы и стадии полей, способы поиска начислений, статусы — enum (`ProviderGroup`, `FieldType`, `FieldStage`, `LookupMethod`, `BillStatus`…), ошибки — `BillerError`. Интеграции (шлюзы, ГИС ГМП, процессинг) — HTTP-интерфейсы `client/*Api` через `ResilientCalls`. Справочники читаются из своей базы без кэша: поход в Redis стоил бы столько же, сколько в Postgres. Оплата у шлюза может быть долгой (`PENDING`): biller хранит её и при запросе статуса дозапрашивает итог у шлюза. Настройки — `biller.*` (минимум оплаты госуслуги, период оплаты, длина названия шаблона).

- **Тип BILL** — всё, что платим через biller: связь, госуслуги, транспорт, игры, зарубежные операторы. Запрос: `providerCode` + `recipientFields` (+ `chargeId` для найденного начисления). Payment спрашивает biller `POST /api/biller/bills/check` (поля по шаблону поставщика, сумма, номинал, оператор по номеру, начисление) и хранит в платеже `provider_code`, `provider_group` и `bill_fields` — JSON-массив `[{key, label, value, display}]`. Сага: резерв → антифрод → оплата у поставщика через biller (`POST /api/biller/payments`, идемпотентно по paymentId; ответ шлюза — в `biller_payments`) → списание. Тариф pricing — `BILL` × группа поставщика (её pricing спрашивает у biller): всё 0%, зарубежная связь 2% (мин. 20 ₽). Категория в истории — по группе.
- **Шаблоны полей** — `biller.provider_fields` (TEXT, DIGITS, EMAIL, PHONE, LOCAL_PHONE, CHOICE, NOMINAL; подсказка под полем, пояснение по «i», pattern) + `provider_field_options`. Таблицы групп: `transport_providers` (вид, регион), `game_providers` (вид, платформа, что получит покупатель) + `game_nominals` (цены, по региону аккаунта), `foreign_mobile_providers` (код страны, длина номера, префиксы, операторы). Фронтенд `/payments/bill/{код}` строит форму по шаблону.
- **Заглушка шлюзов** в `providers` (`/gateway/payments`): «зачисляет», для ваучеров и подписок выпускает код. Отказ — если номер / карта / счёт оканчивается на `0000` или логин `banned`.
- **Категории**: `/payments/transport` (Тройка — 10 цифр, Автодор-транспондер — 19 цифр + email для чека, Парковки — город + телефон, Kupibilet — заказ + email…), `/payments/games` (ChatGPT — почта, страна аккаунта, номинал; Steam — логин; PSN, Xbox — регион и номинал; Genshin — UID и сервер…), `/payments/foreign-mobile` (6 стран + Azercell, Bakcell, Nar: номер без кода страны по формату страны).
- **Ещё категории**: `/payments/emoney` (ЮMoney — телефон или счёт 4100…, комиссия 1%, мин. 10 ₽), `/payments/education`, `/payments/shops` (Орифлэйм, Amway), `/payments/travel` (8 туроператоров и агентств), `/payments/insurance` (ВСК по счёту и ОСАГО, Хоум Кредит Страхование), `/payments/security` (охранные системы: номер договора или устройства — у каждого своей длины, `security_providers`), `/payments/donations` (8 фондов: ФИО отправителя из профиля и сумма, `charity_providers` — ИНН и направление помощи). Группы — `emoney_providers`, `education_providers`, `shop_providers`, `travel_providers`, `insurance_providers`. Список категорий фронтенда — `payments-frontend/src/data/paymentGroups.ts`.
  - **Поиск счетов у поставщика**: поля с `stage = SEARCH` (Образование Москвы: ФИО, СНИЛС ребёнка, свидетельство, паспорт родителя) → «Найти» → `POST /api/biller/invoices/search` → шлюз поставщика (заглушка `/gateway/invoices`, данные на 0 — счетов нет) → `biller.provider_invoices`. Платёж — `BILL` с `chargeId` = id счёта; сумма — из счёта; после оплаты biller помечает счёт `PAID` (`billReference = inv/<id>`).
  - Поле `MONTH` — период оплаты (МШП), не дальше года от текущего месяца. `prefill` — подставить ФИО (`USER_FULL_NAME`) или телефон (`USER_PHONE`) клиента из профиля.
- **Регион** — фильтр поставщиков: `biller.regions` + `provider_regions`. Поставщик с привязкой виден только в своих регионах, без привязки (ГИС ЖКХ, Ростелеком, игры, Автодор…) — федеральный, виден везде. `GET /api/biller/regions`, `GET /api/biller/providers?group=&region=`. На фронтенде «Регион: … ▾» на страницах категорий и в поиске; выбор хранится в браузере (`payments.region`, по умолчанию `moscow`).
- **Услуги ЖКХ** (`/payments/utilities`, `utility_providers`: вид, `direct_pay`, пояснение над формой): ЖКХ Москвы — вкладки «Найти» (ФИО + код плательщика → счета) / «Оплатить» (код плательщика + любая сумма); ГИС ЖКХ — только поиск по ЕЛС (10 знаков, например 60ЫЩ123456); Мосэнергосбыт и Петроэлектросбыт — лицевой счёт + показания (необязательно); МосОблЕИРЦ, ЕРЦ Екатеринбург — счёт + период; СПб, Казань, Екатеринбург — свои поставщики. Поле `stage = BOTH` нужно и для поиска, и для оплаты без поиска.
- **Интернет и ТВ, Телефония** (`/payments/internet`, `internet_providers`) — номер телефона / счёта / договора / ID приёмника и сумма. **Разное** (`/payments/misc`, `misc_providers`) — Биглион и услуги банка (возврат долга при увольнении, информационно-консультационные услуги, комиссия за выпуск зарубежной карты).
- **Счета на оплату** (`/bills`; карточка над вкладками «Платежи / Переводы» — просто ссылка). Шаблон = поставщик + данные плательщика (`biller.bill_subscriptions`, по `X-User-Id`). Подписаться можно только на поставщиков, которые выставляют счета (`providers.bills_order`: ЖКХ, налоги и сборы, ФССП, ГИБДД, интернет и ТВ, Образование Москвы; список — с учётом региона). Поля шаблона — поля поставщика со `stage` SEARCH/BOTH (у госуслуг — как в поиске начислений). При открытии списка и шаблона biller заново спрашивает поставщика: госуслуги — начисления ГИС ГМП, остальные — счета шлюза (`/gateway/invoices`); итог проверки — в `checked_at`, `unpaid_count`, `unpaid_total`. Счёт оплачивается как `BILL` с `chargeId` и полями шаблона. API: `GET/POST /api/biller/subscriptions`, `GET/PUT/DELETE /api/biller/subscriptions/{id}`, `GET /api/biller/subscription-providers?region=`. Фронтенд: `/bills`, «Создать новый» → «Выберите категорию» → `/bills/new/{код}`, шаблон `/bills/{id}` (карандаш → `/bills/{id}/edit`: сохранить / удалить).
- **Поиск по всем поставщикам** на вкладке «Платежи» и на страницах категорий: `GET /api/biller/providers?q=&group=` + банки погашения кредитов (они пока только на фронтенде).
- **Мобильная связь** (`BILL`, `/payments/mobile`, `/payments/mobile/{код}`). Оператора по номеру определяет biller по реестру нумерации (`mobile_number_ranges`: код DEF + диапазон → оператор; `GET /api/biller/mobile/operator?phone=`). Шапка формы становится шапкой оператора (логотип, «Пополнить счет …», юрлицо). Biller при проверке платежа перепроверяет оператора: номер чужого оператора — 422 «Номер обслуживается оператором …». Антифрод, затем оплата через шлюз оператора. Комиссия 0%. Тест: `+7 996 448-80-61` — Yota, `+7 916 …` — МТС, `+7 903 …` — Билайн, `+7 925 …` — МегаФон.
- **Госуслуги** (`/payments/gov`): 6 поставщиков группы GOV, у каждого свой способ поиска (`gov_providers.lookup`): ГИБДД — СТС и/или ВУ, «Оплата по УИН» и «Налоги по УИН» — УИН, «Налоги и сборы» — ИНН физлица, ФССП — паспорт и/или ИНН (`GET /api/biller/gov/charges?provider=…`). Найденные начисления оплачиваются как `BILL` с `chargeId`. Данные, оканчивающиеся на 0, — начислений нет.
  - **Росреестр** (`lookup = FREE`): начисления не ищем — плательщик вводит УИН (начинается с 321), ФИО, адрес, телефон и сумму; получатель — из `gov_providers`. Платёж — `BILL` с `providerCode` и `recipientFields`; один УИН — одна оплата.
- **Погашение кредитов** (`/payments/loans`): только интерфейс — список банков («Показать ещё») и форма (счёт или карта, ФИО владельца, сумма). Платёж будет уходить в команду кредитования; интеграции нет, «Оплатить» только проверяет поля.

## Округление на пользу и пожертвования

- Настройка — в account (`users.roundup_step`, `roundup_fund_code`, `roundup_fund_name`; допустимые шаги — `account.roundup.steps`, `GET /api/users/roundup/options`): `PUT /api/users/{id}/roundup` `{step, fundCode, fundName}`, `DELETE /api/users/{id}/roundup`; в профиле — `roundup`.
- Расчёт — в payment (`create/RoundUpPolicy`, `payment.roundup.*`): для `BILL` групп MOBILE, GAMES, UTILITIES, GOV, INTERNET, EDUCATION, SHOPS, TRAVEL, INSURANCE, SECURITY и оплаты по свободным реквизитам — `ceil(сумма/шаг)*шаг − сумма`. Переводы людям, транспорт, кошельки, пожертвования не округляем. Разница — `round_up_amount` / `round_up_fund_*`, входит в `total` и в резерв, уходит в событии `payment.events`. Карты и QR — подключить сюда, когда появятся.
- Пожертвования (`BILL` групп из `payment.settlement.deferred-groups` — DONATIONS) не идут в шлюз фонда: после антифрода сразу списание, в событии `charitySettlement: true`.
- Biller копит (`charity/CharityListener`, группа `biller-charity`) в `charity_accruals` (ROUNDUP / DONATION, уникально по платежу и источнику, день — по Москве). В конце дня (`charity.settle-cron`, 23:55 МСК) — один запрос на фонд в processing `POST /api/processing/charity-transfers` (идемпотентно по settlementId), итог — `charity_settlements`. Вручную: `POST /api/biller/charity/settle?upTo=YYYY-MM-DD`, посмотреть — `GET /api/biller/charity`.
- История: округление — отдельная операция категории DONATIONS («фонд», «Округление на пользу · получатель»), основная — без него. Уникальный индекс операций включает категорию.
