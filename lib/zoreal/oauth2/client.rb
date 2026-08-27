require 'json'
require 'net/http'
require 'securerandom'
require 'uri'
require 'jwt'

module Zoreal
  module OAuth2
    # The relying-party client. One instance per registered ZOREAL client;
    # thread-safe, so build it once at boot and share it.
    #
    #   ZOREAL_CLIENT = Zoreal::OAuth2::Client.new(
    #     client_id: ENV['ZOREAL_CLIENT_ID'],
    #     client_secret: Rails.application.credentials.dig(:zoreal, :client_secret),
    #     issuer: ENV.fetch('ZOREAL_ISSUER', 'https://id.zoreal.com'),
    #     cache: Rails.cache
    #   )
    #
    #   login = ZOREAL_CLIENT.authenticate(code: params[:code],
    #                                      code_verifier: params[:code_verifier],
    #                                      nonce: params[:nonce])
    #   login.sub            # the pairwise subject: your stable user key
    #   login.userinfo       # Tier B claims (email, name, ...), fetched once
    class Client
      DEFAULT_ISSUER = 'https://id.zoreal.com'.freeze
      # The provider serves its JWKS with a 10-minute public cache; mirroring
      # it here keeps a busy relying party off the endpoint without holding a
      # rotated-out key longer than the provider itself would.
      JWKS_TTL = 600
      JWKS_CACHE_KEY = 'zoreal_oauth2_jwks'.freeze

      AUTH_METHODS = %w[none client_secret_basic private_key_jwt tls_client_auth].freeze
      # The provider rejects an assertion whose exp is more than 60 seconds
      # out, so that is the lifetime, not a choice.
      ASSERTION_LIFETIME = 60

      attr_reader :client_id, :issuer, :auth_method

      # Every registered token_endpoint_auth_method is supported:
      #
      #   none               a public client: no secret, no key, PKCE alone,
      #                      and only ever Tier A scopes.
      #   client_secret_basic  the secret travels as an HTTP Basic header.
      #   private_key_jwt    the library signs a fresh RFC 7523 assertion per
      #                      exchange from private_key (an OpenSSL::PKey or a
      #                      PEM string; P-256 signs ES256, RSA signs RS256;
      #                      private_key_kid sets the JWS kid header when your
      #                      registered JWKS carries one).
      #   tls_client_auth    tls_client_cert/tls_client_key are presented as
      #                      the TLS client certificate. Registrable today;
      #                      the provider itself still answers 501 at /token,
      #                      and that surfaces as the ExchangeError it is.
      #
      # auth_method may be omitted: a client_secret implies
      # client_secret_basic, a private_key implies private_key_jwt, neither
      # means none.
      #
      # cache takes anything with read(key) and write(key, value, expires_in:)
      # (ActiveSupport::Cache::Store is the intended shape). Without one, an
      # in-process store is used; that is fine for one process and means each
      # process of a multi-process server fetches the JWKS for itself.
      def initialize(client_id:, client_secret: nil, issuer: DEFAULT_ISSUER,
                     auth_method: nil, private_key: nil, private_key_kid: nil,
                     tls_client_cert: nil, tls_client_key: nil,
                     cache: nil, timeout: 10)
        raise ConfigurationError, 'client_id is required' if nil_or_empty?(client_id)
        raise ConfigurationError, 'issuer is required' if nil_or_empty?(issuer)

        @client_id = client_id
        @client_secret = client_secret
        @private_key = import_private_key(private_key)
        @private_key_kid = private_key_kid
        @tls_client_cert = import_certificate(tls_client_cert)
        @tls_client_key = import_private_key(tls_client_key)
        @auth_method = resolve_auth_method(auth_method)
        @issuer = issuer.chomp('/')
        @cache = cache || MemoryCache.new
        @timeout = timeout
      end

      # The whole login, in order: exchange the code (with the PKCE verifier
      # the browser SDK handed over), verify the ID token against the JWKS,
      # check the nonce when the caller has it. Returns a Login; personal data
      # is NOT fetched here, because the ID token never carries it and not
      # every caller wants it — Login#userinfo fetches on first use.
      def authenticate(code:, code_verifier:, nonce: nil)
        tokens = exchange(code: code, code_verifier: code_verifier)
        claims = verify_id_token(tokens['id_token'], nonce: nonce)
        Login.new(client: self, claims: claims,
                  id_token: tokens['id_token'],
                  access_token: tokens['access_token'],
                  scope: tokens['scope'])
      end

      # POST /token. The verifier is mandatory: PKCE is required for every
      # ZOREAL client, and the browser SDK that generated it hands it to your
      # frontend precisely so your backend can present it here.
      def exchange(code:, code_verifier:)
        raise ArgumentError, 'code is required' if nil_or_empty?(code)
        raise ArgumentError, 'code_verifier is required' if nil_or_empty?(code_verifier)

        response = post_form("#{issuer}/token", {
                               'grant_type' => 'authorization_code',
                               'code' => code,
                               'code_verifier' => code_verifier,
                               'client_id' => client_id
                             })
        body = parse_json(response.body)
        unless response.is_a?(Net::HTTPSuccess)
          raise ExchangeError.new(body['error'] || 'server_error',
                                  body['error_description'] || "the provider answered #{response.code}",
                                  status: response.code.to_i)
        end
        raise ExchangeError.new('server_error', 'no id_token in the token response') if nil_or_empty?(body['id_token'])

        body
      end

      # ES256 against the provider's JWKS, plus iss, aud, exp and — when the
      # caller passes the nonce the SDK generated — the nonce binding. Returns
      # the claims. There is no RS256 fallback on purpose: ZOREAL signs
      # nothing with RSA, and accepting a second algorithm is how algorithm
      # confusion starts.
      def verify_id_token(id_token, nonce: nil)
        claims, = JWT.decode(
          id_token, nil, true,
          algorithms: ['ES256'],
          iss: issuer, verify_iss: true,
          aud: client_id, verify_aud: true,
          jwks: ->(options) {
            @cache.write(JWKS_CACHE_KEY, nil, expires_in: 0) if options[:kid_not_found]
            jwks
          }
        )
        if !nil_or_empty?(nonce) && claims['nonce'] != nonce
          raise VerificationError, 'the ID token nonce is not the one this login started with'
        end

        claims
      rescue JWT::DecodeError => e
        raise VerificationError, e.message
      end

      # GET /userinfo with the Bearer access token from the exchange. This is
      # the only place personal claims (email, profile.*) are served, and the
      # access token lives ten minutes, so call it as part of handling the
      # login rather than storing the token for later.
      def userinfo(access_token)
        raise ArgumentError, 'access_token is required' if nil_or_empty?(access_token)

        uri = URI("#{issuer}/userinfo")
        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = "Bearer #{access_token}"
        response = http_for(uri).request(request)
        unless response.is_a?(Net::HTTPSuccess)
          body = parse_json(response.body)
          raise UserinfoError,
                body['error_description'] || "userinfo answered #{response.code}"
        end
        parse_json(response.body)
      end

      private

      def jwks
        cached = @cache.read(JWKS_CACHE_KEY)
        return cached if cached

        uri = URI("#{issuer}/jwks")
        begin
          response = http_for(uri).request(Net::HTTP::Get.new(uri))
        rescue SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
          raise VerificationError, "could not fetch the provider JWKS: #{e.message}"
        end
        raise VerificationError, "could not fetch the provider JWKS (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

        keys = JSON.parse(response.body, symbolize_names: true)
        @cache.write(JWKS_CACHE_KEY, keys, expires_in: JWKS_TTL)
        keys
      end

      def post_form(url, form)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri)
        # The form always carries client_id, whatever the auth method: the
        # provider matches the code against it.
        case auth_method
        when 'client_secret_basic'
          # The secret travels as the Basic password, never as a form field.
          request.basic_auth(client_id, @client_secret)
        when 'private_key_jwt'
          form = form.merge(
            'client_assertion_type' => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
            'client_assertion' => build_client_assertion
          )
        end
        request.set_form_data(form)
        http_for(uri).request(request)
      end

      # RFC 7523, in the shape the provider verifies: iss and sub are the
      # client_id, aud is the token endpoint, exp is the capped 60 seconds,
      # and jti is fresh because the provider enforces single use on it.
      def build_client_assertion
        now = Time.now.to_i
        algorithm = @private_key.is_a?(OpenSSL::PKey::EC) ? 'ES256' : 'RS256'
        headers = @private_key_kid ? { kid: @private_key_kid } : {}
        JWT.encode(
          {
            iss: client_id, sub: client_id, aud: "#{issuer}/token",
            exp: now + ASSERTION_LIFETIME, iat: now, jti: SecureRandom.uuid
          },
          @private_key, algorithm, headers
        )
      end

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        if auth_method == 'tls_client_auth' && http.use_ssl?
          http.cert = @tls_client_cert
          http.key = @tls_client_key
        end
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http
      end

      def resolve_auth_method(explicit)
        method = explicit&.to_s
        method ||= if !nil_or_empty?(@client_secret) then 'client_secret_basic'
                   elsif @private_key then 'private_key_jwt'
                   else 'none'
                   end
        raise ConfigurationError, "unknown auth_method #{method}" unless AUTH_METHODS.include?(method)
        raise ConfigurationError, 'client_secret_basic needs a client_secret' if method == 'client_secret_basic' && nil_or_empty?(@client_secret)
        raise ConfigurationError, 'private_key_jwt needs a private_key' if method == 'private_key_jwt' && @private_key.nil?
        if method == 'tls_client_auth' && (@tls_client_cert.nil? || @tls_client_key.nil?)
          raise ConfigurationError, 'tls_client_auth needs tls_client_cert and tls_client_key'
        end

        method
      end

      def import_private_key(key)
        return nil if key.nil?
        return key unless key.is_a?(String)

        OpenSSL::PKey.read(key)
      rescue OpenSSL::PKey::PKeyError => e
        raise ConfigurationError, "the private key did not parse: #{e.message}"
      end

      def import_certificate(cert)
        return nil if cert.nil?
        return cert unless cert.is_a?(String)

        OpenSSL::X509::Certificate.new(cert)
      rescue OpenSSL::X509::CertificateError => e
        raise ConfigurationError, "the certificate did not parse: #{e.message}"
      end

      def parse_json(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        {}
      end

      def nil_or_empty?(value)
        value.nil? || value.to_s.strip.empty?
      end

      # The fallback JWKS cache: one process, TTL respected, no eviction
      # beyond overwrite, because it only ever holds the one key set.
      class MemoryCache
        def initialize
          @mutex = Mutex.new
          @store = {}
        end

        def read(key)
          @mutex.synchronize do
            value, expires_at = @store[key]
            expires_at && expires_at > Time.now ? value : nil
          end
        end

        def write(key, value, expires_in:)
          @mutex.synchronize { @store[key] = [value, Time.now + expires_in] }
        end
      end
    end
  end
end
