require 'minitest/autorun'
require 'zoreal/oauth2'
require 'jwt'

# Offline verification tests: the JWKS is pre-warmed into the client's cache,
# so nothing here touches the network. The exchange and userinfo paths are
# covered by the live integration test (integration_test.rb), which needs a
# running provider.
class VerifyTest < Minitest::Test
  ISSUER = 'https://id.zoreal.example'.freeze
  CLIENT_ID = 'ast_test_client'.freeze

  def setup
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    jwk = JWT::JWK.new(@key, use: 'sig', alg: 'ES256')
    @jwks = { keys: [jwk.export] }
    @client = Zoreal::OAuth2::Client.new(client_id: CLIENT_ID, issuer: ISSUER)
    @client.instance_variable_get(:@cache)
           .write(Zoreal::OAuth2::Client::JWKS_CACHE_KEY, @jwks,
                  expires_in: Zoreal::OAuth2::Client::JWKS_TTL)
    @kid = jwk.export[:kid]
  end

  def sign(claims)
    JWT.encode(claims, @key, 'ES256', kid: @kid)
  end

  def base_claims(overrides = {})
    {
      'iss' => ISSUER,
      'sub' => '7QK3-9F2M-XR84-B5NP',
      'aud' => CLIENT_ID,
      'exp' => Time.now.to_i + 120,
      'iat' => Time.now.to_i,
      'nonce' => 'n-1',
      'acr' => 'zoreal.device'
    }.merge(overrides)
  end

  def test_valid_token_verifies_and_returns_claims
    claims = @client.verify_id_token(sign(base_claims), nonce: 'n-1')
    assert_equal '7QK3-9F2M-XR84-B5NP', claims['sub']
  end

  def test_nonce_mismatch_is_refused
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(sign(base_claims), nonce: 'other')
    end
  end

  def test_nonce_is_not_checked_when_caller_has_none
    assert @client.verify_id_token(sign(base_claims))
  end

  def test_wrong_audience_is_refused
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(sign(base_claims('aud' => 'ast_other')))
    end
  end

  def test_wrong_issuer_is_refused
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(sign(base_claims('iss' => 'https://evil.example')))
    end
  end

  def test_expired_token_is_refused
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(sign(base_claims('exp' => Time.now.to_i - 5)))
    end
  end

  def test_foreign_key_is_refused
    other = OpenSSL::PKey::EC.generate('prime256v1')
    other_kid = JWT::JWK.new(other).export[:kid]
    token = JWT.encode(base_claims, other, 'ES256', kid: other_kid)
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(token)
    end
  end

  def test_login_conveniences_read_the_claims
    login = Zoreal::OAuth2::Login.new(
      client: @client,
      claims: base_claims('age_over_18' => true, 'nationality' => 'SWE',
                          'zoreal' => { 'trust_tier' => 'high' }),
      id_token: 'x'
    )
    assert_equal '7QK3-9F2M-XR84-B5NP', login.sub
    assert_equal true, login.age_over?(18)
    assert_equal 'SWE', login.nationality
    assert_equal 'high', login.assurance['trust_tier']
    # No access token: userinfo is an empty hash, never a fetch.
    assert_equal({}, login.userinfo)
    assert_nil login.email
    refute login.email_verified?
  end
end

# The assurance floor at verification (products/oauth2/02 section 5.1): the
# request was advisory, the signed claim is the proof, and this is the check.
class AcrVerifyTest < Minitest::Test
  ISSUER = VerifyTest::ISSUER
  CLIENT_ID = VerifyTest::CLIENT_ID

  def setup
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    jwk = JWT::JWK.new(@key, use: 'sig', alg: 'ES256')
    @client = Zoreal::OAuth2::Client.new(client_id: CLIENT_ID, issuer: ISSUER)
    @client.instance_variable_get(:@cache)
           .write(Zoreal::OAuth2::Client::JWKS_CACHE_KEY, { keys: [jwk.export] },
                  expires_in: Zoreal::OAuth2::Client::JWKS_TTL)
    @kid = jwk.export[:kid]
  end

  def token(acr)
    claims = { 'iss' => ISSUER, 'sub' => 's', 'aud' => CLIENT_ID,
               'exp' => Time.now.to_i + 120, 'acr' => acr }.compact
    JWT.encode(claims, @key, 'ES256', kid: @kid)
  end

  def test_equal_acr_satisfies
    assert @client.verify_id_token(token('zoreal.live'), acr: 'zoreal.live')
  end

  def test_stronger_acr_satisfies
    assert @client.verify_id_token(token('zoreal.live'), acr: 'zoreal.device')
  end

  def test_weaker_acr_is_refused
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(token('zoreal.device'), acr: 'zoreal.live')
    end
  end

  def test_missing_acr_is_refused_when_required
    assert_raises(Zoreal::OAuth2::VerificationError) do
      @client.verify_id_token(token(nil), acr: 'zoreal.session')
    end
  end

  def test_unknown_required_acr_is_a_caller_bug
    assert_raises(Zoreal::OAuth2::ConfigurationError) do
      @client.verify_id_token(token('zoreal.live'), acr: 'zoreal.liveness')
    end
  end

  def test_no_required_acr_checks_nothing
    assert @client.verify_id_token(token(nil))
  end

  def test_login_conveniences
    login = Zoreal::OAuth2::Login.new(client: @client, claims: { 'acr' => 'zoreal.live' }, id_token: 'x')
    assert login.live?
    assert login.satisfies_acr?('zoreal.device')
    refute login.satisfies_acr?('made.up')
    device = Zoreal::OAuth2::Login.new(client: @client, claims: { 'acr' => 'zoreal.device' }, id_token: 'x')
    refute device.live?
    refute device.satisfies_acr?('zoreal.live')
  end
end
