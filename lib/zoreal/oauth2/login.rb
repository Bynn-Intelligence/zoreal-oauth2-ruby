module Zoreal
  module OAuth2
    # One verified login. The ID token claims are already checked when this
    # exists; userinfo is fetched on first use, because the ID token never
    # carries personal data and not every login needs any.
    class Login
      # The verified ID token claims and the raw compact JWT they came from.
      attr_reader :claims, :id_token
      # From the token response. The access token lives ten minutes.
      attr_reader :access_token, :scope

      def initialize(client:, claims:, id_token:, access_token: nil, scope: nil)
        @client = client
        @claims = claims
        @id_token = id_token
        @access_token = access_token
        @scope = scope
      end

      # The pairwise subject: stable for your verified domain, meaningless to
      # anyone else. This is the value to key accounts on — and it is derived
      # from YOUR registered sector, so changing your asset's domain rotates
      # every sub you have stored.
      def sub
        claims['sub']
      end

      # How the login was authenticated: zoreal.live, zoreal.device or
      # zoreal.session. Describes what happened, never what was requested.
      def acr
        claims['acr']
      end

      def amr
        claims['amr']
      end

      # The assurance block: uniqueness basis, verification month, chip
      # liveness, trust tier, key protection.
      def assurance
        claims['zoreal']
      end

      # zoreal.age scope: the registered thresholds arrive as booleans
      # (age_over_18 and so on), never an age.
      def age_over?(threshold)
        claims["age_over_#{threshold.to_i}"]
      end

      # zoreal.nationality scope: ISO 3166-1 alpha-3, read from the chip.
      def nationality
        claims['nationality']
      end

      # The Tier B claims, from /userinfo, fetched once and memoized. Raises
      # UserinfoError when the endpoint refuses — rescue it if your flow can
      # continue without personal data, as a returning user matched on sub
      # can. Returns an empty hash when the exchange carried no access token.
      def userinfo
        @userinfo ||= access_token ? @client.userinfo(access_token) : {}
      end

      def email
        userinfo['email']
      end

      def email_verified?
        userinfo['email_verified'] == true
      end

      def name
        userinfo['name']
      end

      def given_name
        userinfo['given_name']
      end

      def family_name
        userinfo['family_name']
      end

      # ISO 8601, from the profile.birthdate scope.
      def birthdate
        userinfo['birthdate']
      end

      # The profile.document scope: the document as presented, not an
      # assertion about the person beyond it.
      def document_type
        userinfo['document_type']
      end

      def document_number
        userinfo['document_number']
      end

      def issuing_country
        userinfo['issuing_country']
      end

      def document_expires_on
        userinfo['document_expires_on']
      end

      # The profile.portrait scope (Tier C): the chip's DG2 image. The scope
      # is registrable but the provider does not serve the claim yet, so this
      # returns nil until it does.
      def portrait
        userinfo['portrait']
      end
    end
  end
end
