require_relative 'lib/zoreal/oauth2/version'

Gem::Specification.new do |spec|
  spec.name = 'zoreal-oauth2'
  spec.version = Zoreal::OAuth2::VERSION
  spec.authors = ['ZOREAL']
  spec.summary = 'Login with ZOREAL for Ruby backends.'
  spec.description = 'The relying-party half of Login with ZOREAL: exchanges the ' \
                     'authorization code your frontend received from ' \
                     '@zoreal/oauth2-react, verifies the ID token against the ' \
                     "provider's JWKS, and reads personal claims from /userinfo."
  spec.homepage = 'https://zoreal.com'
  spec.license = 'MIT'
  spec.metadata['source_code_uri'] = 'https://github.com/Bynn-Intelligence/zoreal-oauth2-ruby'

  spec.required_ruby_version = '>= 3.1'
  spec.files = Dir['lib/**/*.rb'] + %w[README.md LICENSE]
  spec.require_paths = ['lib']

  # The one dependency. Everything else is stdlib: Net::HTTP for the two
  # provider calls, OpenSSL through the jwt gem for ES256.
  spec.add_dependency 'jwt', '>= 2.7', '< 4'
end
