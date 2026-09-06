module Integrator
  module Analysis
    # запись о результате, который нельзя определить уверенно
    # анализаторы добавляют её сюда вместо исключения или пропуска
    Warning = Struct.new(
      :stage,      # этап анализа
      :subject,    # объект анализа
      :reason,     # причина в языке отчёта
      keyword_init: true
    )

    EndpointAnalysis = Struct.new(
      :endpoint,       # ссылка на объект Integrator::Spec::Endpoint
      :role,           # роль эндпоинта
      :confidence,     # уровень уверенности
      :matched_rule,   # правило, по которому выбрана роль
      keyword_init: true
    )

    ErrorAction = Struct.new(
      :http_status,    # http-статус
      :provider_code,  # код ошибки провайдера
      :action,         # действие при ошибке
      keyword_init: true
    )

    FieldMapping = Struct.new(
      :amount_field,        # поле суммы у провайдера
      :amount_unit,         # единица суммы
      :currency_field,      # поле валюты
      :external_id_field,   # внешнее поле идентификатора
      :recipient_container_field, # контейнер реквизитов у провайдера
                            # nil означает плоские поля
                            # nil означает, что вложенного объекта нет
      :recipient_fields,    # соответствие канонических и полей провайдера
                            #   канонические ключи: :phone, :bank_code, :bank_name, :card_number
      keyword_init: true
    )

    # единый объект для генерации
    # содержит результаты классификации и маппинга по спецификации
    SpecAnalysis = Struct.new(
      :info,                    # данные спецификации
      :class_name,              # имя класса из info[:title]
      :env_prefix,              # префикс переменной окружения
      :base_url,                # sandbox URL или первый сервер
      :security_scheme,         # схема авторизации для :create
      :create,                  # анализ эндпоинта создания
      :status,                  # анализ эндпоинта статуса
      :cancel,                  # анализ эндпоинта отмены
      :callback,                # анализ callback
      :balance,                 # анализ баланса
      :field_mapping,           # маппинг полей
      :recipient_type_field,    # поле типа реквизитов
      :recipient_type_value,    # значение типа реквизитов
      :status_map,              # соответствие статусов
      :event_status_map,        # соответствие событий webhook статусам
      :error_rows,              # строки обработки ошибок, отсортированные по HTTP-статусу
      :webhook_signature_header,    # заголовок подписи webhook
      :webhook_signature_algorithm, # алгоритм подписи webhook
      :idempotency_header,      # заголовок идемпотентности
      :amount_minimum,          # минимальная сумма из схемы
      :warnings,                # общий сборщик предупреждений
      keyword_init: true
    )
  end
end
