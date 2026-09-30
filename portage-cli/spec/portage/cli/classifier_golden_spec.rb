require "spec_helper"
require "yaml"

# The golden set behind docs/plans/local-catalogue.md Phase 5: real product
# texts (Light Yard, JB Hi-Fi), shopper queries and browser-import style
# urls/titles, each with the top-1 category a person would choose. It runs the
# shipped known-stores/categories.yml, so a keyword or scoring change that
# helps one store and hurts another shows up here.
RSpec.describe "Classifier golden set" do
  cases = YAML.safe_load_file(File.expand_path("../../fixtures/classifier_golden.yml", __dir__), permitted_classes: [])
  taxonomy = YAML.safe_load_file(Portage::Cli::Classifier::KNOWN_PATH, permitted_classes: [])

  # Top-1 accuracy the golden set must reach. It was 0.12 (12 of 100) before the
  # taxonomy pass (docs/plans/local-catalogue.md, "Phase 5 results") and is raised
  # as the pass lands, never lowered to make a change pass.
  minimum_accuracy = 0.55

  def classify(text) = Portage::Cli::Classifier.categories_for(text)

  def correct?(golden, found)
    top_one = golden["expect"] == "none" ? found.empty? : found.first == golden["expect"]
    top_one && !Array(golden["must_not_include"]).intersect?(found)
  end

  it "has 60 to 100 labelled cases" do
    expect(cases.size).to be_between(60, 100)
  end

  it "labels only nodes the shipped taxonomy has" do
    unknown = cases.map { |golden| golden["expect"] }.uniq.reject { |id| id == "none" || taxonomy.key?(id) }
    expect(unknown).to eq([])
  end

  it "reaches the minimum top-1 accuracy" do
    missed = cases.reject { |golden| correct?(golden, classify(golden["text"])) }
    accuracy = (cases.size - missed.size).fdiv(cases.size)
    detail = missed.map { |golden| "#{golden['expect']} <- #{golden['text'][0, 60]}" }.first(10)
    expect(accuracy).to be >= minimum_accuracy, "accuracy #{accuracy.round(3)}; first misses: #{detail.inspect}"
  end

  # The Phase 2 failures that started the taxonomy pass. `pending` flips to a
  # failure once an example passes, so none can be forgotten.
  describe "the Phase 2 failures" do
    it "classifies 'Pendant Light' as Lighting" do
      pending "the taxonomy has no word for pendant"
      expect(classify("Pendant Light").first).to eq("594")
    end

    it "never classifies 'New Collection' as Toll Collection Devices" do
      expect(classify("New Collection")).not_to include("4488")
    end

    it "ranks Lighting first for a lighting product tagged Kitchen" do
      pending "the taxonomy has no word for pendant"
      expect(classify("Pendant Light Kitchen Pendant Lights Hanging Lights").first).to eq("594")
    end

    it "gives a Light Yard storefront text Lighting as its top category" do
      pending "the taxonomy has no word for pendant"
      text = "Pendant Light Bedroom Pendant Lights British Hand-Made Kitchen Pendant Lights Hanging Lights £250-£500"
      expect(classify(text).first).to eq("594")
    end
  end
end
