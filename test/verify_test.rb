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
