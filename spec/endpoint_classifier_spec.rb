require_relative "../lib/integrator/spec/loader"
require_relative "../lib/integrator/analysis/endpoint_classifier"

RSpec.describe Integrator::Analysis::EndpointClassifier do
  def role_for(analyses, method, path)
    analyses.find { |a| a.endpoint.method == method && a.endpoint.path == path }
  end

  describe "against the NovaPay fixture" do
    let(:parsed) { Integrator::Spec::Loader.load_file(File.join(__dir__, "fixtures", "novapay_api.yaml")) }
    let(:classifier) { described_class.new }
    let(:analyses) { classifier.classify(parsed.endpoints) }

    it "classifies every endpoint with high confidence — the spec is unambiguous" do
      expect(role_for(analyses, "POST", "/payouts").role).to eq(:create)
      expect(role_for(analyses, "GET", "/payouts/{payout_id}").role).to eq(:status)
      expect(role_for(analyses, "POST", "/payouts/{payout_id}/cancel").role).to eq(:cancel)
      expect(role_for(analyses, "POST", "/webhooks/payout").role).to eq(:callback)
      expect(role_for(analyses, "GET", "/balance").role).to eq(:balance)

      expect(analyses.map(&:confidence)).to all(eq(:high))
    end

    it "records no warnings" do
      classifier.classify(parsed.endpoints)
      expect(classifier.warnings).to be_empty
    end
  end

  describe "against a differently-named spec (universality check)" do
    let(:parsed) { Integrator::Spec::Loader.load_file(File.join(__dir__, "fixtures", "generic_disbursement_api.yaml")) }
    let(:classifier) { described_class.new }
    let(:analyses) { classifier.classify(parsed.endpoints) }

    it "classifies create via tag/path keyword, with zero NovaPay-specific logic" do
      result = role_for(analyses, "POST", "/disbursements")
      expect(result.role).to eq(:create)
      expect(result.confidence).to eq(:high)
    end

    it "classifies status via the bare-{id}-at-end-of-path rule" do
      result = role_for(analyses, "GET", "/disbursements/{ref}")
      expect(result.role).to eq(:status)
    end

    it "classifies cancel via the /void suffix" do
      result = role_for(analyses, "POST", "/disbursements/{ref}/void")
      expect(result.role).to eq(:cancel)
    end

    it "classifies callback via security=[] plus a 'callback' keyword" do
      result = role_for(analyses, "POST", "/gateway/callback")
      expect(result.role).to eq(:callback)
    end

    it "classifies balance via the 200 response body shape, as a medium-confidence fallback" do
      # Deliberately named /funds-summary (tag "Disbursements") so neither
      # the path, operationId, nor the tag contains a balance/wallet/account
      # keyword — this exercises the schema-shape fallback specifically,
      # not the keyword rule.
      result = role_for(analyses, "GET", "/funds-summary")
      expect(result.role).to eq(:balance)
      expect(result.confidence).to eq(:medium)
    end

    it "refuses to guess on the receipt-download endpoint and records a warning instead" do
      result = role_for(analyses, "GET", "/disbursements/{ref}/receipt")
      expect(result.role).to eq(:unclassified)
      expect(result.confidence).to eq(:low)

      warning = classifier.warnings.to_a.find { |w| w.subject == "GET /disbursements/{ref}/receipt" }
      expect(warning).not_to be_nil
      expect(warning.stage).to eq(:classification)
    end

    it "does not warn about endpoints it successfully classified" do
      analyses # force the memoized classify call exactly once
      subjects_with_warnings = classifier.warnings.to_a.map(&:subject)
      expect(subjects_with_warnings).to eq(["GET /disbursements/{ref}/receipt"])
    end
  end
end
