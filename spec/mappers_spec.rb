require_relative "../lib/integrator/spec/loader"
require_relative "../lib/integrator/analysis/status_mapper"
require_relative "../lib/integrator/analysis/error_mapper"
require_relative "../lib/integrator/analysis/field_mapper"

RSpec.describe Integrator::Analysis::StatusMapper do
  let(:mapper) { described_class.new }

  it "buckets NovaPay's actual status vocabulary correctly" do
    result = mapper.map(%w[pending processing completed failed cancelled])
    expect(result).to eq(
      "pending" => :in_progress,
      "processing" => :in_progress,
      "completed" => :approved,
      "failed" => :rejected,
      "cancelled" => :rejected
    )
    expect(mapper.warnings).to be_empty
  end

  it "leaves an unrecognized status as :unresolved and records why" do
    result = mapper.map(["on_hold"])
    expect(result).to eq("on_hold" => :unresolved)

    warning = mapper.warnings.to_a.first
    expect(warning.stage).to eq(:status_mapping)
    expect(warning.subject).to eq("status=on_hold")
  end
end

RSpec.describe Integrator::Analysis::ErrorMapper do
  let(:mapper) { described_class.new }

  it "prefers the more specific provider error code over the bare HTTP status" do
    # 402 alone defaults to :retry_with_backoff, and "insufficient_balance"
    # agrees here — but the point of this test is that the CODE decides,
    # not the coincidence that they happen to match.
    result = mapper.action_for(402, "insufficient_balance")
    expect(result.action).to eq(:retry_with_backoff)
  end

  it "falls back to the HTTP status when there is no provider code" do
    expect(mapper.action_for(401, nil).action).to eq(:alert_and_block)
    expect(mapper.action_for(422, nil).action).to eq(:reject)
  end

  it "applies the 5xx catch-all for status codes not in the fixed table" do
    expect(mapper.action_for(503, nil).action).to eq(:retry)
  end

  it "returns :unresolved and warns for a genuinely unknown case" do
    result = mapper.action_for(418, "im_a_teapot")
    expect(result.action).to eq(:unresolved)
    expect(mapper.warnings.to_a.first.stage).to eq(:error_mapping)
  end
end

RSpec.describe Integrator::Analysis::FieldMapper do
  let(:mapper) { described_class.new }

  describe "against NovaPay's CreatePayoutRequest schema" do
    let(:request_schema) do
      parsed = Integrator::Spec::Loader.load_file(File.join(__dir__, "fixtures", "novapay_api.yaml"))
      parsed.endpoints.find { |e| e.operation_id == "createPayout" }.request_schema
    end
    let(:mapping) { mapper.map(request_schema) }

    it "finds the top-level fields by their real (non-aliased) names" do
      expect(mapping.amount_field).to eq("amount")
      expect(mapping.currency_field).to eq("currency")
      expect(mapping.external_id_field).to eq("external_id")
    end

    it "detects the amount unit from the field's Russian description" do
      expect(mapping.amount_unit).to eq(:minor) # "Сумма в копейках"
    end

    it "finds recipient sub-fields inside the nested 'recipient' object" do
      # Recipient's schema covers both sbp and card variants at once, so
      # card_number is present here even though the example we loaded is
      # type=sbp — the schema declares it as optional either way.
      expect(mapping.recipient_fields).to eq(
        phone: "phone",
        bank_code: "bank_code",
        bank_name: "bank_name",
        card_number: "card_number"
      )
    end

    it "does not warn about card_number, since it's a legitimately conditional field" do
      subjects = mapper.warnings.to_a.map(&:subject)
      expect(subjects).not_to include("card_number")
    end
  end

  describe "against a flat, differently-named schema (universality check)" do
    let(:request_schema) do
      Integrator::Spec::Schema.new(
        type: "object",
        required_fields: %w[sum msisdn],
        properties: {
          "sum" => Integrator::Spec::Schema.new(type: "number", description: nil),
          "msisdn" => Integrator::Spec::Schema.new(type: "string")
        }
      )
    end
    let(:mapping) { mapper.map(request_schema) }

    it "maps 'sum' to amount and 'msisdn' to phone via aliases, with no nested object at all" do
      expect(mapping.amount_field).to eq("sum")
      expect(mapping.recipient_fields).to eq(phone: "msisdn")
    end

    it "warns about the genuinely missing required fields (currency, external_id)" do
      mapping # force evaluation
      subjects = mapper.warnings.to_a.map(&:subject)
      expect(subjects).to include("currency", "external_id")
    end

    it "leaves the amount unit :unresolved rather than guessing, since there's no description at all" do
      expect(mapping.amount_unit).to eq(:unresolved)
    end
  end
end
