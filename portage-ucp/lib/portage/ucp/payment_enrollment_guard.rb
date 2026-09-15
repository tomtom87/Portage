module Portage
  module Ucp
    # Boundary guard for `Adapter#create_payment_enrollment` /
    # `#get_payment_enrollment` results (design-log §33/Phase B).
    # `PaymentEnrollment` (value_objects.rb) has no validation of its own —
    # every Data.define in that file is raise-free by convention — so an
    # adapter can otherwise hand back `status: "banana"`, or a "complete"
    # enrollment with no `payment_token`, and it would construct and ship
    # fine. Same posture as PaymentTokenGuard: catch clear misintegration,
    # don't try to prove full validity.
    module PaymentEnrollmentGuard
      VALID_STATUSES = %w[pending complete].freeze

      def self.validate!(enrollment)
        status = enrollment.status
        unless VALID_STATUSES.include?(status)
          raise Portage::Ucp::InvalidPaymentEnrollmentError,
                "payment enrollment #{enrollment.id.inspect} has unknown status #{status.inspect} — " \
                "expected one of #{VALID_STATUSES}"
        end

        status == "pending" ? validate_pending!(enrollment) : validate_complete!(enrollment)
      end

      def self.validate_pending!(enrollment)
        return if enrollment.setup_url && !enrollment.payment_token

        raise Portage::Ucp::InvalidPaymentEnrollmentError,
              "payment enrollment #{enrollment.id.inspect} is \"pending\" but must carry a setup_url " \
              "and no payment_token"
      end
      private_class_method :validate_pending!

      def self.validate_complete!(enrollment)
        return if enrollment.payment_token && !enrollment.setup_url

        raise Portage::Ucp::InvalidPaymentEnrollmentError,
              "payment enrollment #{enrollment.id.inspect} is \"complete\" but must carry a payment_token " \
              "and no setup_url"
      end
      private_class_method :validate_complete!
    end
  end
end
