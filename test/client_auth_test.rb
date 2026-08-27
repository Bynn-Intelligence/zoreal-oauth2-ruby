require 'minitest/autorun'
require 'zoreal/oauth2'
require 'jwt'

# The client authentication matrix, offline: method resolution, configuration
# refusals, and the private_key_jwt assertion the client signs.
class ClientAuthTest < Minitest::Test
  ISSUER = 'https://id.zoreal.example'.freeze

  def ec_key
    OpenSSL::PKey::EC.generate('prime256v1')
  end

  def test_method_inference
    assert_equal 'none', Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER).auth_method
    assert_equal 'client_secret_basic',
                 Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, client_secret: 's').auth_method
    assert_equal 'private_key_jwt',
                 Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, private_key: ec_key).auth_method
  end

  def test_explicit_method_without_material_is_refused
    assert_raises(Zoreal::OAuth2::ConfigurationError) do
      Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, auth_method: 'client_secret_basic')
    end
    assert_raises(Zoreal::OAuth2::ConfigurationError) do
      Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, auth_method: 'private_key_jwt')
    end
    assert_raises(Zoreal::OAuth2::ConfigurationError) do
      Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, auth_method: 'tls_client_auth')
    end
    assert_raises(Zoreal::OAuth2::ConfigurationError) do
      Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, auth_method: 'made_up')
    end
  end

  def test_pem_private_key_is_accepted
    pem = ec_key.to_pem
    client = Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, private_key: pem)
    assert_equal 'private_key_jwt', client.auth_method
  end

  def test_garbage_private_key_is_refused
    assert_raises(Zoreal::OAuth2::ConfigurationError) do
      Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER, private_key: 'not a key')
    end
  end

  def test_assertion_carries_the_rfc7523_claims
    key = ec_key
    client = Zoreal::OAuth2::Client.new(client_id: 'ast_x', issuer: ISSUER,
                                        private_key: key, private_key_kid: 'kid-1')
    assertion = client.send(:build_client_assertion)
    claims, headers = JWT.decode(assertion, key, true, algorithm: 'ES256')
    assert_equal 'ast_x', claims['iss']
    assert_equal 'ast_x', claims['sub']
    assert_equal "#{ISSUER}/token", claims['aud']
    assert_in_delta Time.now.to_i + 60, claims['exp'], 2
    refute_empty claims['jti']
    assert_equal 'kid-1', headers['kid']
    # A second assertion never reuses the jti: the provider enforces single use.
    other, = JWT.decode(client.send(:build_client_assertion), key, true, algorithm: 'ES256')
    refute_equal claims['jti'], other['jti']
  end

  def test_rsa_key_signs_rs256
    rsa = OpenSSL::PKey::RSA.new(2048)
    client = Zoreal::OAuth2::Client.new(client_id: 'ast_x', issuer: ISSUER, private_key: rsa)
    claims, = JWT.decode(client.send(:build_client_assertion), rsa, true, algorithm: 'RS256')
    assert_equal 'ast_x', claims['iss']
  end

  def test_tls_client_auth_requires_both_halves
    key = ec_key
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=test')
    cert.public_key = key
    cert.not_before = Time.now
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new('SHA256'))

    client = Zoreal::OAuth2::Client.new(client_id: 'a', issuer: ISSUER,
                                        auth_method: 'tls_client_auth',
                                        tls_client_cert: cert.to_pem, tls_client_key: key.to_pem)
    assert_equal 'tls_client_auth', client.auth_method
  end
end
