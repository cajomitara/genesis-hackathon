require "optparse"
require "fileutils"
require_relative "spec/loader"
require_relative "analysis/spec_analyzer"
require_relative "generation/service_generator"
require_relative "generation/doc_generator"
require_relative "generation/fixtures_generator"

module Integrator
  # объединяет этапы анализа и генерации
  class CLI
    Options = Struct.new(:spec_path, :output_dir)
    TOTAL_STEPS = 4

    def self.start(argv)
      new.run(argv)
    end

    def run(argv)
      parse_result = parse_options(argv)
      case parse_result
      in [:help, usage_text]
        puts usage_text
        return 0
      in [:error, nil]
        return 1
      in [:ok, options]
        run_pipeline(options)
      end
    rescue Spec::Loader::InvalidSpecError => e
      warn "\nСпецификация не может быть обработана: #{e.message}"
      1
    rescue StandardError => e
      # InvalidSpecError обрабатывается выше
      # остальные исключения считаются внутренними ошибками
      warn "\nВнутренняя ошибка (#{e.class}): #{e.message}"
      1
    end

    private

    def run_pipeline(options)
      FileUtils.mkdir_p(options.output_dir)

      parsed = run_step(1, "Загрузка и валидация спецификации") do
        spec = Spec::Loader.load_file(options.spec_path)
        [spec, "#{spec.info[:title]} v#{spec.info[:version]}"]
      end

      analysis = run_step(2, "Анализ (классификация ролей, статусы, ошибки, поля)") do
        result = Analysis::SpecAnalyzer.new(parsed).call
        roles_found = %i[create status cancel callback balance].count { |role| result.send(role) }
        [result, "#{roles_found}/5 ролей найдено, #{result.warnings.to_a.size} предупреждений"]
      end

      paths = output_paths(options.output_dir, analysis)

      run_step(3, "Генерация Ruby-сервиса") do
        Generation::ServiceGenerator.new(analysis).write(paths[:service])
        [nil, File.basename(paths[:service])]
      end

      run_step(4, "Генерация документации и фикстур") do
        Generation::DocGenerator.new(analysis).write(paths[:doc])
        Generation::FixturesGenerator.new(analysis).write(paths[:fixtures])
        [nil, "#{File.basename(paths[:doc])}, #{File.basename(paths[:fixtures])}"]
      end

      print_report(analysis, paths)
      0
    end

    # возвращает результат разбора аргументов: ok, help или error
    def parse_options(argv)
      options = Options.new(nil, "output")
      help_requested = false

      parser = OptionParser.new do |opts|
        opts.banner = "Использование: integrate --spec PATH [--output DIR]"
        opts.on("-s", "--spec PATH", "Путь к OpenAPI-спецификации провайдера (обязательно)") { |v| options.spec_path = v }
        opts.on("-o", "--output DIR", "Каталог для сгенерированных файлов (по умолчанию: ./output)") { |v| options.output_dir = v }
        opts.on("-h", "--help", "Показать эту справку") { help_requested = true }
      end

      parser.parse!(argv)
      return [:help, parser.to_s] if help_requested

      if options.spec_path.nil?
        warn parser.banner
        return [:error, nil]
      end
      [:ok, options]
    rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
      warn "#{e.message}"
      [:error, nil]
    end

    def output_paths(output_dir, analysis)
      {
        service: File.join(output_dir, "#{analysis.class_name.downcase}_service.rb"),
        doc: File.join(output_dir, "INTEGRATION.md"),
        fixtures: File.join(output_dir, "fixtures.json")
      }
    end

    # выполняет один этап, выводит его статус и возвращает результат
    def run_step(index, label)
      print "[#{index}/#{TOTAL_STEPS}] #{label}... "
      value, detail = yield
      puts "OK#{detail ? " (#{detail})" : ''}"
      value
    rescue StandardError
      puts "ОШИБКА"
      raise
    end

    def print_report(analysis, paths)
      puts
      puts "Файлы записаны в:"
      paths.each_value { |p| puts "  #{p}" }

      warnings = analysis.warnings.to_a
      puts
      if warnings.empty?
        puts "Предупреждений нет"
      else
        puts "Неподдерживаемые/неоднозначные элементы (#{warnings.size}):"
        warnings.each { |w| puts "  [#{w.stage}] #{w.subject} – #{w.reason}" }
        puts
        puts "Подробности: INTEGRATION.md; TODO отмечены в сгенерированном коде"
      end
    end
  end
end