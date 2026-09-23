require "json"
require "faraday"

module Portage
  module Ucp
    module Decision
      module ModelBackends
        # Client for TypeSafe AI's Jev — the "System One Model" the plan doc's
        # title borrowed its name from (docs.typesafe.ai/introduction/quickstart).
        # A hosted decision API: POST state + typed questions, get back typed
        # answers with a calibrated `confidence` per answer.
        class Jev
          BASE_URL = "https://api.typesafe.ai/v1/systemone".freeze
          DEFAULT_MODEL = "jev-latest".freeze
          # This gem's own name for the credential, matching this backend's
          # name in the registry. TYPESAFE_API_KEY — the name TypeSafe's own
          # docs and SDKs use — is read as a fallback, so a key already set up
          # for TypeSafe works here without being copied to a second name.
          ENV_KEY = "JEV_API_KEY".freeze
          FALLBACK_ENV_KEY = "TYPESAFE_API_KEY".freeze

          def self.env_api_key
            [ENV_KEY, FALLBACK_ENV_KEY].map { |key| ENV.fetch(key, nil).to_s.strip }.find { |key| !key.empty? }
          end

          def initialize(api_key: self.class.env_api_key, model: DEFAULT_MODEL, connection: nil)
            @api_key = api_key
            @model = model
            @connection = connection || Faraday.new(url: BASE_URL)
          end

          def configured? = !@api_key.to_s.strip.empty?

          # @param state [String] the text (or JSON-serialized context) to
          #   evaluate — a checkout, an offer list, a merchant signal.
          # @param questions [Hash{String => Question}]
          # @return [Hash{String => Answer}]
          def ask(state:, questions:)
            unless configured?
              raise Portage::Ucp::Decision::BackendNotConfiguredError,
                    "#{ENV_KEY} is not set (nor #{FALLBACK_ENV_KEY}) — get a key at " \
                    "https://console.typesafe.ai and set #{ENV_KEY}"
            end

            response = post(state, questions)
            raise_for_status!(response)
            parse(JSON.parse(response.body))
          end

          private

          def post(state, questions)
            @connection.post("") do |req|
              req.headers["Authorization"] = "Bearer #{@api_key}"
              req.headers["Content-Type"] = "application/json"
              req.body = JSON.generate(state: state, model: @model,
                                       questions: questions.transform_values(&:to_wire_h))
            end
          end

          def raise_for_status!(response)
            return if response.status.between?(200, 299)

            raise Portage::Ucp::Decision::BackendError,
                  "Jev request failed: #{response.status} #{response.body}"
          end

          def parse(body)
            body.fetch("answers").transform_values do |answer|
              Answer.new(type: answer["type"], confidence: answer["confidence"],
                         value: answer["choice"] || answer["score"] || answer["noul"],
                         probabilities: answer["probabilities"])
            end
          end
        end
      end
    end
  end
end
