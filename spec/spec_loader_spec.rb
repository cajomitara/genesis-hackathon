require_relative "../lib/integrator/spec/loader"

RSpec.describe Integrator::Spec::Loader do
  let(:fixture_path) { File.join(__dir__, "fixtures", "novapay_api.yaml") }
  let(:parsed) { described_class.load_file(fixture_path) }

  describe "top-level document" do
    it "extracts basic info" do
      expect(parsed.info[:title]).to eq("NovaPay Payout API")
      expect(parsed.info[:version]).to eq("1.0.0")
    end

    it "extracts security schemes" do
      scheme = parsed.security_schemes["ApiKeyAuth"]
      expect(scheme.type).to eq("apiKey")
      expect(scheme.location).to eq(:header)
      expect(scheme.param_name).to eq("X-API-Key")
    end
  end

  describe "endpoints" do
    it "finds every operation across every path" do
      expect(parsed.endpoints.size).to eq(5)
      expect(parsed.endpoints.map { |e| [e.method, e.path] }).to contain_exactly(
        ["POST", "/payouts"],
        ["GET", "/payouts/{payout_id}"],
        ["POST", "/payouts/{payout_id}/cancel"],
        ["POST", "/webhooks/payout"],
        ["GET", "/balance"]
      )
    end

    it "inherits security from operation-level requirements, keeping explicit [] distinct from unset" do
      create = parsed.endpoints.find { |e| e.operation_id == "createPayout" }
      webhook = parsed.endpoints.find { |e| e.operation_id == "payoutWebhook" }

      expect(create.security).to eq(["ApiKeyAuth"])
      expect(webhook.security).to eq([]) # explicit `security: []` in the spec
    end

    it "resolves the request schema, including $refs, minimums and descriptions" do
      create = parsed.endpoints.find { |e| e.operation_id == "createPayout" }
      schema = create.request_schema

      expect(schema.required_fields).to eq(%w[amount currency external_id recipient])
      expect(schema.properties["amount"].minimum).to eq(100_000)
      expect(schema.properties["recipient"].source_name).to eq("Recipient")
      expect(schema.properties["recipient"].required_fields).to eq(%w[type phone])
    end

    it "pulls named examples straight from the spec" do
      create = parsed.endpoints.find { |e| e.operation_id == "createPayout" }
      expect(create.request_examples.map(&:name)).to eq(["sbp_payout"])
      expect(create.request_examples.first.value["recipient"]["phone"]).to eq("79001234567")
    end

    it "resolves every declared response, including nested $ref'd error schemas" do
      create = parsed.endpoints.find { |e| e.operation_id == "createPayout" }
      expect(create.responses.keys).to contain_exactly(201, 400, 401, 402, 409, 422, 429, 500)

      error_schema = create.responses[402].schema.properties["error"]
      expect(error_schema.source_name).to eq("PayoutError")
      expect(error_schema.properties["code"].enum).to include("insufficient_balance")
    end
  end

  describe "OpenAPI 3.0 webhook-as-endpoint (no top-level `webhooks:` key)" do
    it "leaves webhooks array empty, per the 3.0/3.1 split documented on WebhookDef" do
      expect(parsed.webhooks).to eq([])
    end

    it "still fully parses the webhook path as a regular Endpoint" do
      webhook = parsed.endpoints.find { |e| e.path == "/webhooks/payout" }

      expect(webhook.security).to eq([])
      expect(webhook.parameters.map(&:name)).to include("X-NovaPay-Signature")
      expect(webhook.request_schema.properties["event"].enum).to include("payout.completed")
      expect(webhook.request_examples.map(&:name)).to contain_exactly("completed", "failed")
    end
  end

  describe "error handling" do
    it "raises InvalidSpecError for a missing file" do
      expect { described_class.load_file("nope.yaml") }
        .to raise_error(Integrator::Spec::Loader::InvalidSpecError, /file not found/)
    end

    it "raises InvalidSpecError for a document with no 'openapi' key" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad.yaml")
        File.write(path, { "info" => { "title" => "x" }, "paths" => {} }.to_yaml)
        expect { described_class.load_file(path) }
          .to raise_error(Integrator::Spec::Loader::InvalidSpecError, /missing 'openapi'/)
      end
    end

    it "raises InvalidSpecError for an unsupported OpenAPI version" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bad_version.yaml")
        File.write(path, { "openapi" => "2.0", "info" => {}, "paths" => {} }.to_yaml)
        expect { described_class.load_file(path) }
          .to raise_error(Integrator::Spec::Loader::InvalidSpecError, /unsupported OpenAPI version/)
      end
    end
  end
end

RSpec.describe "Integrator::Spec::Loader with a minimal, differently-shaped spec" do
  # A universality smoke test: different field/tag names than NovaPay, no
  # webhook, no idempotency header, minimal schema depth. The loader should
  # not care — it has zero NovaPay-specific logic. (The classifier/mappers,
  # tested separately, are what actually need to generalize semantically.)
  let(:minimal_spec) do
    {
      "openapi" => "3.0.3",
      "info" => { "title" => "Minimal Disbursement API", "version" => "0.1.0" },
      "paths" => {
        "/disbursements" => {
          "post" => {
            "operationId" => "createDisbursement",
            "tags" => ["Disbursements"],
            "requestBody" => {
              "content" => {
                "application/json" => {
                  "schema" => {
                    "type" => "object",
                    "required" => %w[sum msisdn],
                    "properties" => {
                      "sum" => { "type" => "number" },
                      "msisdn" => { "type" => "string" }
                    }
                  }
                }
              }
            },
            "responses" => {
              "200" => { "description" => "ok" }
            }
          }
        }
      }
    }
  end

  it "parses without any NovaPay-specific assumptions" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "minimal.yaml")
      File.write(path, minimal_spec.to_yaml)
      parsed = Integrator::Spec::Loader.load_file(path)

      expect(parsed.endpoints.size).to eq(1)
      endpoint = parsed.endpoints.first
      expect(endpoint.request_schema.properties.keys).to contain_exactly("sum", "msisdn")
      expect(endpoint.security).to eq([]) # no security schemes declared anywhere
    end
  end
end
