# NovaPay: интеграция

## Авторизация
- Тип: API Key
- Header: `X-API-Key: <credentials.api_key>`
- Хранение: `providers.credentials` (encrypted)

## Методы

| Метод | Эндпоинт | Назначение | Идемпотентность |
|-------|-----------|------------|-----------------|
| create_payout | POST /payouts | Создать выплату | Idempotency-Key |
| get_payout_status | GET /payouts/{payout_id} | Получить статус выплаты | - |
| cancel_payout | POST /payouts/{payout_id}/cancel | Отменить выплату | - |
| payout_webhook | POST /webhooks/payout | Webhook уведомление о смене статуса | подпись в X-NovaPay-Signature |
| get_balance | GET /balance | Баланс провайдера | - |

## Маппинг статусов

| Провайдер | Space Payments |
|----------|----------------|
| pending | in_progress |
| processing | in_progress |
| completed | approved |
| failed | rejected |
| cancelled | rejected |

## Обработка ошибок

| HTTP | Код провайдера | Действие |
|------|----------------|----------|
| 400 | _не указан в спеке_ | отклонить |
| 401 | unauthorized | заблокировать провайдера |
| 402 | insufficient_balance | повторить с задержкой |
| 409 | _не указан в спеке_ | отклонить |
| 422 | validation_error | отклонить |
| 429 | rate_limit_exceeded | повторить с задержкой |
| 500 | _не указан в спеке_ | повторить |

## ProviderGateway

```json
{ "external_method": "TODO", "gateway": "TODO" }
```
> `external_method` и `gateway` не определяются по API-спецификации. заполните вручную.

## Подпись webhook
HMAC-SHA256(body, callback_secret) → hex → `X-NovaPay-Signature`

## Неподдерживаемые / неоднозначные элементы спецификации
| Этап | Элемент | Причина |
|------|---------|---------|
| field_mapping | ProviderGateway config (external_method / gateway) | не определяется по API-спецификации, заполните вручную |
