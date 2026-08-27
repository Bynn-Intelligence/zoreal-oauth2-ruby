module Zoreal
  module OAuth2
    class Error < StandardError; end

    # The client was built without something it cannot work without.
    class ConfigurationError < Error; end

    # The provider refused the code exchange. `oauth_error` is the RFC 6749
    # error code and `description` the provider's own reason, verbatim: the
    # provider's words are the only signal that says WHY (a consumed code, a
    # PKCE mismatch, a lapsed sector), and rewriting them hides it.
    class ExchangeError < Error
      attr_reader :oauth_error, :description, :status

      def initialize(oauth_error, description, status: nil)
        @oauth_error = oauth_error
        @description = description
        @status = status
        super([oauth_error, description].compact.join(': '))
      end
    end

    # The ID token did not verify: bad signature, wrong issuer or audience,
    # expired, or a nonce that was not the one this login started with.
    class VerificationError < Error; end

    # /userinfo answered with anything but the claims. Callers that can live
    # without personal data (a returning user matched by sub) may rescue this
    # and continue; callers that need the email should not.
    class UserinfoError < Error; end
  end
end
