# zoreal-oauth2

Login with ZOREAL for Ruby backends: the relying-party half of the flow that
[`@zoreal/oauth2-react`](https://github.com/Bynn-Intelligence/zoreal-oauth2-react)
starts in the browser.

The browser SDK runs the pairing (QR or app link), and hands your frontend an
authorization `code` plus the `code_verifier` and `nonce` it generated. Your
frontend posts all three to your backend, and this gem does the rest: the code
exchange with your client authentication, ES256 verification of the ID token
against the provider's JWKS, and the `/userinfo` read for personal claims.

```
zoreal-oauth2 (this gem)   your backend: exchange, verify, userinfo
@zoreal/oauth2-react       your frontend: the button, the QR, the polling
```

## Install

```ruby
# Gemfile
gem 'zoreal-oauth2'
```

Or directly: `gem install zoreal-oauth2`.

Ruby >= 3.1. One dependency: `jwt`.

## Quick start

Build one client at boot and share it; it is thread-safe.

```ruby
ZOREAL_OAUTH = Zoreal::OAuth2::Client.new(
  client_id: ENV['ZOREAL_CLIENT_ID'],                                   # ast_...
  client_secret: Rails.application.credentials.dig(:zoreal, :client_secret),
  issuer: ENV.fetch('ZOREAL_ISSUER', 'https://id.zoreal.com'),
  cache: Rails.cache                                                    # optional, for the JWKS
)
```

The endpoint your frontend posts to:

```ruby
login = ZOREAL_OAUTH.authenticate(
  code: params[:code],
  code_verifier: params[:code_verifier],   # PKCE is mandatory; the SDK hands it over
  nonce: params[:nonce]                    # binds the ID token to this login
)

login.sub          # "TC5X-JN7G-YTSE-6E63" — pairwise, stable for YOUR domain
login.acr          # "zoreal.live" | "zoreal.device" | "zoreal.session"
login.assurance    # uniqueness basis, verification month, chip liveness, trust tier
login.email        # from /userinfo, when your client has the email scope
login.email_verified?
login.name         # from /userinfo, profile.name scope
```

Account matching, the shape that works:

```ruby
user = User.find_by(provider: 'zoreal', uid: login.sub)
if user.nil?
  user = User.find_by(email: login.email) if login.email_verified?  # claim, don't collide
  user ||= User.new(email: login.email)
  user.update!(provider: 'zoreal', uid: login.sub)
end
```

## Client authentication: all four registered methods

| `token_endpoint_auth_method` | Configuration | What travels |
|---|---|---|
| `none` | nothing | a public client: PKCE alone, Tier A scopes only |
| `client_secret_basic` | `client_secret:` | the secret, as HTTP Basic |
| `private_key_jwt` | `private_key:` (PEM or `OpenSSL::PKey`), `private_key_kid:` optional | a fresh RFC 7523 assertion per exchange: `iss`=`sub`=client id, `aud`=`{issuer}/token`, 60-second life, single-use `jti`. P-256 signs ES256, RSA signs RS256 |
| `tls_client_auth` | `tls_client_cert:`, `tls_client_key:` | the TLS client certificate. Registrable today; the provider still answers 501 at `/token`, and that surfaces as the `ExchangeError` it is |

`auth_method:` may be omitted: a `client_secret` implies `client_secret_basic`,
a `private_key` implies `private_key_jwt`, neither means `none`.

## What each call does

| Call | What happens |
|---|---|
| `authenticate(code:, code_verifier:, nonce: nil)` | `exchange` + `verify_id_token`, returns a `Login` |
| `exchange(code:, code_verifier:)` | `POST {issuer}/token` with the configured client authentication |
| `verify_id_token(jwt, nonce: nil)` | ES256 against `{issuer}/jwks`, checks `iss`, `aud`, `exp`, and `nonce` when given |
| `userinfo(access_token)` | `GET {issuer}/userinfo` with the Bearer token |
| `Login#userinfo` | the above, once, memoized; `{}` when there is no access token |

`Login` exposes every claim the scope catalogue can grant: `sub`, `acr`, `amr`,
`assurance`, `age_over?(n)`, `nationality` from the ID token; `email`,
`email_verified?`, `name`, `given_name`, `family_name`, `birthdate`,
`document_type`, `document_number`, `issuing_country`, `document_expires_on`
and `portrait` from `/userinfo` (`portrait` is registrable but not served by
the provider yet, and returns nil until it is).

Errors: `ConfigurationError`, `ExchangeError` (carries the provider's OAuth
error code and reason, verbatim), `VerificationError`, `UserinfoError`. A
returning user matched on `sub` can survive a rescued `UserinfoError`; a
signup that needs the email cannot.

## Things worth knowing before you integrate

- **The ID token never carries personal data.** `sub`, timing, `acr`/`amr`,
  the assurance block, and — if registered — `age_over_*` booleans and
  `nationality`. Email, names, birthdate and document fields come only from
  `/userinfo`, which is why `authenticate` alone is not enough for a signup.
- **The access token lives 10 minutes.** Read `/userinfo` while handling the
  login; do not store the token for later.
- **`sub` is pairwise per verified domain.** It is the right account key and
  it is derived from your registered sector: changing your asset's domain
  rotates every `sub` you have stored. Plan domain changes as a migration.
- **ES256 only.** The provider signs with nothing else, and this gem refuses
  other algorithms rather than negotiating.
- **Always pass the nonce through.** The SDK generates it and gives it to your
  frontend in `onSuccess`; without it your backend cannot tell a substituted
  ID token from the real one.
- **Email is a deliberate choice.** It is a Tier B scope precisely because a
  shared email defeats the unlinkability the pairwise `sub` provides. Request
  it because you need it, not because the checkbox is familiar.
- **Sandbox clients accept localhost origins; production clients do not.**
  Registration lives in the ZOREAL dashboard on the asset's OAuth2 tab; Tier B
  scopes (email, profile.\*) need a confidential client on a verified domain.

## Development against a local provider

Point `issuer:` at your provider instance. The issuer value must match the `iss` inside the
tokens exactly — it is compared, not normalized.

## The ZOREAL OAuth2 library family

| Repository | Package | Role |
|---|---|---|
| zoreal-oauth2-react | @zoreal/oauth2-react (npm) | React frontend: the button, the QR, the polling |
| zoreal-oauth2-js | @zoreal/oauth2-js (npm) | Framework-free browser core |
| zoreal-oauth2-react-native | @zoreal/oauth2-react-native (npm) | React Native frontend |
| zoreal-oauth2-node | @zoreal/oauth2-node (npm) | Node.js backend |
| zoreal-oauth2-ruby | zoreal-oauth2 (RubyGems) | Ruby backend |
| zoreal-oauth2-python | zoreal-oauth2 (PyPI) | Python backend |
| zoreal-oauth2-php | zoreal/oauth2 (Packagist) | PHP backend |
| zoreal-oauth2-go | github.com/Bynn-Intelligence/zoreal-oauth2-go | Go backend |
| zoreal-oauth2-java | com.zoreal:oauth2 (Maven Central) | JVM backend |
| zoreal-oauth2-dotnet | Zoreal.OAuth2 (NuGet) | .NET backend |

The repository always carries the platform suffix; the package drops it where
the registry already scopes the ecosystem. None of them are named after a
framework, because none of them depend on one.

## License

MIT.
