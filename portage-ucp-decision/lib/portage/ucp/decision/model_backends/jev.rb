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
          # Seconds. A confidence check sits in front of a checkout the
          # shopper is waiting on; Net::HTTP's defaults would stall it for up
          # to two minutes on a hung connection.
          OPEN_TIMEOUT = 5
          TIMEOUT = 15
          USER_AGENT = "portage-ucp-decision/#{VERSION} (+https://github.com/tomtom87/Portage)".freeze
          ENV_KEY = "JEV_API_KEY".freeze
          FALLBACK_ENV_KEY = "TYPESAFE_API_KEY".freeze

          def self.env_api_key
            [ENV_KEY, FALLBACK_ENV_KEY].map { |key| ENV.fetch(key, nil).to_s.strip }.find { |key| !key.empty? }
          end

          def initialize(api_key: self.class.env_api_key, model: DEFAULT_MODEL, connection: nil)
            @api_key = api_key
            @model = model
            @connection = connection ||
                          Faraday.new(url: BASE_URL, headers: { "User-Agent" => USER_AGENT },
                                      request: { open_timeout: OPEN_TIMEOUT, timeout: TIMEOUT })
          end

          def configured? = configuration_problem.nil?

          # @return [String, nil] why this backend can't answer yet, or nil
          #   when it can — same contract as Laya#configuration_problem.
          def configuration_problem
            return nil unless @api_key.to_s.strip.empty?

            "#{ENV_KEY} is not set (nor #{FALLBACK_ENV_KEY}) — get a key at https://console.typesafe.ai " \
              "and set #{ENV_KEY}"
          end

          # @param state [String] the text (or JSON-serialized context) to
          #   evaluate — a checkout, an offer list, a merchant signal.
          # @param questions [Hash{String => Question}]
          # @return [Hash{String => Answer}]
          def ask(state:, questions:)
            problem = configuration_problem
            raise Portage::Ucp::Decision::BackendNotConfiguredError, problem if problem

            response = post(state, questions)
            raise_for_status!(response)
            ModelBackends.parse_answers(response.body, source: "Jev")
          rescue Faraday::Error => e
            raise Portage::Ucp::Decision::BackendError, "Jev request failed: #{e.class}: #{e.message}"
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
                  "Jev request failed: #{response.status} #{response.body.to_s[0, 300]}"
          end
        end
      end
    end
  end
end
