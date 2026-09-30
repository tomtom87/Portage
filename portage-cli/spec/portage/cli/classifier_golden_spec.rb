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

  # Top-1 accuracy the golden set must reach: the 70 of 100 the taxonomy pass
  # achieves. It was 12 of 100 before the pass (docs/plans/local-catalogue.md,
  # "Phase 5 results"). The misses left are listed there; raise this number
  # when one is fixed, never lower it to make a change pass.
  minimum_accuracy = 0.70

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

  # The Phase 2 failures that started the taxonomy pass.
  describe "the Phase 2 failures" do
    it "classifies 'Pendant Light' as Lighting" do
      expect(classify("Pendant Light").first).to eq("594")
    end

    it "never classifies 'New Collection' as Toll Collection Devices" do
      expect(classify("New Collection")).not_to include("4488")
    end

    it "ranks Lighting first for a lighting product tagged Kitchen" do
      expect(classify("Pendant Light Kitchen Pendant Lights Hanging Lights").first).to eq("594")
    end

    it "gives a Light Yard storefront text Lighting as its top category" do
      text = "Pendant Light Bedroom Pendant Lights British Hand-Made Kitchen Pendant Lights Hanging Lights £250-£500"
      expect(classify(text).first).to eq("594")
    end
  end

  describe "the shipped synonyms" do
    synonyms = YAML.safe_load_file(File.expand_path("../../../known-stores/category-synonyms.yml", __dir__),
                                   permitted_classes: [])

    it "names, for each word, a golden case of that category whose text contains it" do
      synonyms.each do |id, words|
        words.each do |word, case_text|
          golden = cases.find { |entry| entry["text"] == case_text }
          expect(golden).not_to be_nil, "#{word}: no golden case with the text #{case_text.inspect}"
          expect(golden["expect"]).to eq(id), "#{word}: the case expects #{golden['expect']}, not #{id}"
          expect(Portage::Cli::Classifier.tokenize(case_text)).to include(word),
                                                                  "#{word} is not in #{case_text.inspect}"
        end
      end
    end

    it "only names nodes the taxonomy has" do
      expect(synonyms.keys - taxonomy.keys).to eq([])
    end
  end
end
