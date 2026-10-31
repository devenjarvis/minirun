var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// node_modules/@cloudflare/workers-oauth-provider/dist/oauth-provider.js
import { WorkerEntrypoint } from "cloudflare:workers";
var OAUTH_SCOPE_TOKEN_PATTERN = /^[\x21\x23-\x5B\x5D-\x7E]+$/;
function authorizationErrorRedirect(request, code, description) {
  const redirect2 = new URL(request.redirectUri);
  for (const key of ERROR_RESPONSE_PARAMETERS) redirect2.searchParams.delete(key);
  redirect2.searchParams.set("error", code);
  if (description) redirect2.searchParams.set("error_description", description);
  if (request.state) redirect2.searchParams.set("state", request.state);
  if (request.issuer) redirect2.searchParams.set("iss", request.issuer);
  return redirect2.href;
}
__name(authorizationErrorRedirect, "authorizationErrorRedirect");
var ERROR_RESPONSE_PARAMETERS = [
  "error",
  "error_description",
  "error_uri",
  "state",
  "iss"
];
var AuthorizationError = class extends Error {
  static {
    __name(this, "AuthorizationError");
  }
  constructor(code, options) {
    super(options.description);
    this.name = "AuthorizationError";
    this.code = code;
    this.description = options.description;
    this.redirectUri = options.redirectUri;
    this.state = options.state;
    this.issuer = options.issuer;
    this.redirectTo = options.redirectUri ? safeErrorRedirect(code, options) : void 0;
  }
};
function safeErrorRedirect(code, options) {
  try {
    return authorizationErrorRedirect({
      redirectUri: options.redirectUri,
      state: options.state,
      issuer: options.issuer
    }, code, options.description);
  } catch {
    return;
  }
}
__name(safeErrorRedirect, "safeErrorRedirect");
function withAuthorizationRedirect(error, redirectUri, state, issuer) {
  return new AuthorizationError(error.code, {
    description: error.description,
    redirectUri,
    state,
    issuer
  });
}
__name(withAuthorizationRedirect, "withAuthorizationRedirect");
function buildOAuthServerCapabilities(options) {
  return {
    grantTypes: [
      "authorization_code",
      "refresh_token",
      ...options.allowTokenExchangeGrant ? ["urn:ietf:params:oauth:grant-type:token-exchange"] : [],
      ...options.enterpriseManagedAuthorization ? ["urn:ietf:params:oauth:grant-type:jwt-bearer"] : []
    ],
    responseTypes: ["code"],
    tokenEndpointAuthMethods: [
      "client_secret_basic",
      "client_secret_post",
      "none"
    ],
    codeChallengeMethods: ["S256"],
    allowPrivateUseRedirectUris: options.allowPrivateUseRedirectUris
  };
}
__name(buildOAuthServerCapabilities, "buildOAuthServerCapabilities");
function validateClientCapabilities(server, client) {
  if (!server.tokenEndpointAuthMethods.includes(client.tokenEndpointAuthMethod)) throw new Error(`Unsupported token_endpoint_auth_method: ${client.tokenEndpointAuthMethod}`);
  const unsupportedGrant = client.grantTypes.find((grantType) => !server.grantTypes.includes(grantType));
  if (unsupportedGrant) throw new Error(`Unsupported grant_type: ${unsupportedGrant}`);
  const unsupportedResponse = client.responseTypes.find((responseType) => !server.responseTypes.includes(responseType));
  if (unsupportedResponse) throw new Error(`Unsupported response_type: ${unsupportedResponse}`);
  if (client.grantTypes.includes("authorization_code") !== client.responseTypes.includes("code")) throw new Error("grant_types authorization_code and response_types code must be registered together");
}
__name(validateClientCapabilities, "validateClientCapabilities");
var SHARED_SECRET_TOKEN_ENDPOINT_AUTH_METHODS = /* @__PURE__ */ new Set([
  "client_secret_basic",
  "client_secret_post",
  "client_secret_jwt"
]);
function negotiateTokenEndpointAuthMethod(options) {
  const { acceptedMethods, defaultMethod, preferredMethod, supportedMethods, context } = options;
  if (preferredMethod !== void 0 && supportedMethods !== void 0 && !supportedMethods.includes(preferredMethod)) throw new Error("token_endpoint_auth_method must be included in token_endpoint_auth_methods_supported");
  const advertisedMethods = supportedMethods ?? [preferredMethod ?? defaultMethod];
  const effectiveMethod = preferredMethod !== void 0 && acceptedMethods.includes(preferredMethod) ? preferredMethod : acceptedMethods.find((method) => advertisedMethods.includes(method));
  if (effectiveMethod !== void 0) return effectiveMethod;
  const advertised = [.../* @__PURE__ */ new Set([...preferredMethod === void 0 ? [] : [preferredMethod], ...advertisedMethods])];
  throw new Error(`${context} does not support an accepted token endpoint authentication method. Supported methods: ${acceptedMethods.join(", ")}. Client advertised: ${advertised.length > 0 ? advertised.join(", ") : "(none)"}`);
}
__name(negotiateTokenEndpointAuthMethod, "negotiateTokenEndpointAuthMethod");
var PRIVATE_KEY_JWT = "private_key_jwt";
function negotiateCimdTokenEndpointAuthMethods(server, preferredMethod, supportedMethods, privateKeyJwt) {
  if (preferredMethod !== void 0 && SHARED_SECRET_TOKEN_ENDPOINT_AUTH_METHODS.has(preferredMethod)) throw new Error(`CIMD clients cannot use symmetric token endpoint authentication method: ${preferredMethod}`);
  if (preferredMethod !== void 0 && supportedMethods !== void 0 && !supportedMethods.includes(preferredMethod)) throw new Error("token_endpoint_auth_method must be included in token_endpoint_auth_methods_supported");
  const acceptedMethods = [...server.tokenEndpointAuthMethods.filter((method) => !SHARED_SECRET_TOKEN_ENDPOINT_AUTH_METHODS.has(method)), ...privateKeyJwt ? [PRIVATE_KEY_JWT] : []];
  const advertisedMethods = supportedMethods ?? [preferredMethod ?? "none"];
  const methods = acceptedMethods.filter((method) => advertisedMethods.includes(method));
  if (methods.length > 0) return methods;
  const advertised = [.../* @__PURE__ */ new Set([...preferredMethod === void 0 ? [] : [preferredMethod], ...advertisedMethods])];
  throw new Error(`CIMD client does not support an accepted token endpoint authentication method. Supported methods: ${acceptedMethods.join(", ")}. Client advertised: ${advertised.length > 0 ? advertised.join(", ") : "(none)"}`);
}
__name(negotiateCimdTokenEndpointAuthMethods, "negotiateCimdTokenEndpointAuthMethods");
function negotiateDynamicClientRegistrationCapabilities(server, client) {
  const effective = {
    grantTypes: [...client.grantTypes],
    responseTypes: [...client.responseTypes],
    tokenEndpointAuthMethod: negotiateTokenEndpointAuthMethod({
      acceptedMethods: server.tokenEndpointAuthMethods,
      defaultMethod: "client_secret_basic",
      preferredMethod: client.tokenEndpointAuthMethod,
      supportedMethods: client.tokenEndpointAuthMethodsSupported,
      context: "Client"
    })
  };
  validateClientCapabilities(server, effective);
  return effective;
}
__name(negotiateDynamicClientRegistrationCapabilities, "negotiateDynamicClientRegistrationCapabilities");
function negotiateCimdClientCapabilities(server, client, options = { privateKeyJwt: false }) {
  const tokenEndpointAuthMethods = negotiateCimdTokenEndpointAuthMethods(server, client.tokenEndpointAuthMethod, client.tokenEndpointAuthMethodsSupported, options.privateKeyJwt);
  const effective = {
    grantTypes: client.grantTypes.filter((grantType) => server.grantTypes.includes(grantType)),
    responseTypes: client.responseTypes.filter((responseType) => server.responseTypes.includes(responseType)),
    tokenEndpointAuthMethod: tokenEndpointAuthMethods[0],
    tokenEndpointAuthMethods
  };
  validateClientCapabilities({
    ...server,
    tokenEndpointAuthMethods: [...server.tokenEndpointAuthMethods, PRIVATE_KEY_JWT]
  }, effective);
  return effective;
}
__name(negotiateCimdClientCapabilities, "negotiateCimdClientCapabilities");
function validateAuthorizationResponseType(server, responseType, clientResponseTypes) {
  if (!responseType) throw new AuthorizationError("invalid_request", { description: "response_type is required" });
  if (!server.responseTypes.includes(responseType)) throw new AuthorizationError("unsupported_response_type", { description: `The authorization server does not support response_type ${responseType}` });
  if (!(clientResponseTypes ?? ["code"]).includes(responseType)) throw new AuthorizationError("unauthorized_client", { description: `The client is not registered for response_type ${responseType}` });
}
__name(validateAuthorizationResponseType, "validateAuthorizationResponseType");
function normalizePkceCodeChallengeMethod(method) {
  const effectiveMethod = method ?? "plain";
  if (effectiveMethod !== "plain" && effectiveMethod !== "S256") throw new AuthorizationError("invalid_request", { description: `Unsupported PKCE code_challenge_method: ${effectiveMethod}` });
  return effectiveMethod;
}
__name(normalizePkceCodeChallengeMethod, "normalizePkceCodeChallengeMethod");
function validatePkceCodeChallengeMethod(server, method) {
  const effectiveMethod = normalizePkceCodeChallengeMethod(method);
  if (!server.codeChallengeMethods.includes(effectiveMethod)) throw new AuthorizationError("invalid_request", { description: "The plain PKCE method is not allowed. Use S256 instead." });
  return effectiveMethod;
}
__name(validatePkceCodeChallengeMethod, "validatePkceCodeChallengeMethod");
function validateAuthorizationPkce(server, request, client) {
  if (request.codeChallenge) {
    validatePkceCodeChallengeMethod(server, request.codeChallengeMethod);
    return;
  }
  if (request.codeChallengeMethod) throw new AuthorizationError("invalid_request", { description: "PKCE code_challenge is required when code_challenge_method is provided." });
  if (request.responseType === "code" && client.tokenEndpointAuthMethod === "none") throw new AuthorizationError("invalid_request", { description: "Public clients must use PKCE with the authorization code flow." });
}
__name(validateAuthorizationPkce, "validateAuthorizationPkce");
function validateAuthorizationServerScopes(scopes) {
  if (!scopes) return;
  if (scopes.some((scope) => !isValidOAuthScopeToken(scope))) throw new TypeError("scopesSupported must contain valid OAuth scope tokens");
  if (new Set(scopes).size !== scopes.length) throw new TypeError("scopesSupported must not contain duplicate values");
}
__name(validateAuthorizationServerScopes, "validateAuthorizationServerScopes");
function isValidOAuthScopeToken(scopeToken) {
  return OAUTH_SCOPE_TOKEN_PATTERN.test(scopeToken);
}
__name(isValidOAuthScopeToken, "isValidOAuthScopeToken");
var version = "1.2.4";
var OUTBOUND_USER_AGENT = `workers-oauth-provider/${version} (+https://github.com/cloudflare/workers-oauth-provider)`;
function withCorsHeaders(response, request) {
  const origin = request.headers.get("Origin");
  if (!origin) return response;
  const cors = new Response(response.body, response);
  const setUnlessPresent = /* @__PURE__ */ __name((name, value) => {
    if (!cors.headers.has(name)) cors.headers.set(name, value);
  }, "setUnlessPresent");
  setUnlessPresent("Access-Control-Allow-Origin", origin);
  setUnlessPresent("Access-Control-Allow-Methods", "*");
  setUnlessPresent("Access-Control-Allow-Headers", "Authorization, *");
  setUnlessPresent("Access-Control-Max-Age", "86400");
  appendHeaderValue(cors.headers, "Vary", "Origin");
  appendHeaderValue(cors.headers, "Access-Control-Expose-Headers", "WWW-Authenticate");
  appendHeaderValue(cors.headers, "Access-Control-Expose-Headers", "Retry-After");
  return cors;
}
__name(withCorsHeaders, "withCorsHeaders");
function appendHeaderValue(headers, name, value) {
  const values = (headers.get(name) ?? "").split(",").map((item) => item.trim()).filter(Boolean);
  if (!values.some((item) => item.toLowerCase() === value.toLowerCase())) values.push(value);
  headers.set(name, values.join(", "));
}
__name(appendHeaderValue, "appendHeaderValue");
function resolveRequiredScopes(requiredScopes, deprecatedScopesSupported) {
  if (requiredScopes !== void 0 && deprecatedScopesSupported !== void 0) throw new TypeError("Set requiredScopes only: resourceMetadata.scopes_supported is deprecated in its favour");
  const scopes = requiredScopes ?? deprecatedScopesSupported;
  return scopes === void 0 ? void 0 : [...scopes];
}
__name(resolveRequiredScopes, "resolveRequiredScopes");
function baselineResourceScopes(scopes) {
  return [...new Set(scopes)].filter((scope) => scope !== "offline_access");
}
__name(baselineResourceScopes, "baselineResourceScopes");
var OAuthError = class extends Error {
  static {
    __name(this, "OAuthError");
  }
  constructor(code, options) {
    super(options.description);
    this.name = "OAuthError";
    this.code = code;
    this.options = {
      ...options,
      statusCode: options.statusCode ?? 400
    };
    this.description = this.options.description;
    this.statusCode = this.options.statusCode;
    this.headers = this.options.headers;
    this.requiredScopes = this.options.requiredScopes;
  }
};
var EMA_ID_JAG_JWT_TYPE = "oauth-id-jag+jwt";
var EMA_ID_JAG_GRANT_PROFILE = "urn:ietf:params:oauth:grant-profile:id-jag";
var EMA_MAX_JWT_BYTES = 16 * 1024;
var EMA_JWKS_MAX_SIZE_BYTES = 64 * 1024;
var EMA_JWKS_FETCH_TIMEOUT_MS = 1e4;
var EMA_DEFAULT_JWKS_CACHE_TTL_SECONDS = 300;
var EMA_DEFAULT_CLOCK_SKEW_SECONDS = 60;
var EMA_DEFAULT_MAX_ASSERTION_LIFETIME_SECONDS = 300;
var EMA_JWKS_FORCE_REFRESH_COOLDOWN_SECONDS = 30;
var EMA_JTI_MIN_TTL_SECONDS = 60;
var EMA_DEFAULT_JWT_ALGORITHM = "RS256";
var EMA_SUPPORTED_JWT_ALGORITHMS = /* @__PURE__ */ new Set(["RS256", "ES256"]);
var ok = /* @__PURE__ */ __name((value) => ({
  ok: true,
  value
}), "ok");
var err = /* @__PURE__ */ __name((error) => ({
  ok: false,
  error
}), "err");
function emaErrorToWire(e) {
  switch (e.reason) {
    case "assertion_missing":
      return {
        code: "invalid_request",
        message: "assertion is required"
      };
    case "invalid_scope_param":
      return {
        code: "invalid_request",
        message: "Invalid scope parameter format"
      };
    case "resource_invalid":
    case "resource_mismatch":
      return {
        code: "invalid_target",
        message: "Invalid resource"
      };
    case "mapper_denied":
    case "mapper_threw":
      return {
        code: "invalid_grant",
        message: "Assertion was not authorized"
      };
    case "invalid_mapped_user":
      return {
        code: "invalid_grant",
        message: "Invalid mapped user"
      };
    case "invalid_mapped_scope":
      return {
        code: "invalid_grant",
        message: "Invalid mapped scope"
      };
    case "invalid_mapped_props":
      return {
        code: "invalid_grant",
        message: "Invalid mapped props"
      };
    case "invalid_mapped_ttl":
      return {
        code: "invalid_grant",
        message: "Invalid access token TTL"
      };
    case "assertion_expired_after_processing":
      return {
        code: "invalid_grant",
        message: "Assertion has expired"
      };
    case "assertion_too_large":
    case "assertion_malformed":
    case "invalid_typ":
    case "invalid_alg":
    case "issuer_not_trusted":
    case "no_matching_key":
    case "signature_failed":
    case "jwks_fetch_failed":
    case "invalid_claim":
    case "aud_mismatch":
    case "unsupported_claim":
    case "expired":
    case "iat_in_future":
    case "nbf_in_future":
    case "lifetime_too_long":
    case "replayed":
    case "client_id_mismatch":
      return {
        code: "invalid_grant",
        message: "Invalid assertion"
      };
  }
}
__name(emaErrorToWire, "emaErrorToWire");
async function sha256Hex$1(input) {
  const data = new TextEncoder().encode(input);
  const buffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(sha256Hex$1, "sha256Hex$1");
var EMA_JTI_KV_PREFIX = "enterprise-jti:";
function createKvJtiStore(keyPrefix = EMA_JTI_KV_PREFIX) {
  return { async markUsed({ issuer, jti, exp, now, env }) {
    const ttl = Math.max(EMA_JTI_MIN_TTL_SECONDS, exp - now);
    const key = `${keyPrefix}${await sha256Hex$1(`${issuer}
${jti}`)}`;
    if (await env.OAUTH_KV.get(key)) return err({
      reason: "replayed",
      jti
    });
    await env.OAUTH_KV.put(key, "1", { expirationTtl: ttl });
    return ok(void 0);
  } };
}
__name(createKvJtiStore, "createKvJtiStore");
function createDefaultJwksProvider(opts = {}) {
  const cache = /* @__PURE__ */ new Map();
  const cacheTtl = opts.cacheTtlSeconds ?? EMA_DEFAULT_JWKS_CACHE_TTL_SECONDS;
  return { async fetch(issuer, { forceRefresh, now }) {
    const cached = cache.get(issuer.issuer);
    if (!forceRefresh && cached && cached.expiresAt > now) return ok(cached.jwks);
    if (forceRefresh && cached && cached.nextForceRefreshAllowedAt > now) return ok(cached.jwks);
    const abortController = new AbortController();
    const timeoutId = setTimeout(() => abortController.abort(), EMA_JWKS_FETCH_TIMEOUT_MS);
    try {
      const response = await fetch(issuer.jwksUri, {
        headers: {
          Accept: "application/json",
          "User-Agent": OUTBOUND_USER_AGENT
        },
        signal: abortController.signal,
        cf: { cacheEverything: true }
      });
      if (!response.ok) return err({
        reason: "jwks_fetch_failed",
        status: response.status
      });
      const contentLength = response.headers.get("content-length");
      if (contentLength && parseInt(contentLength, 10) > EMA_JWKS_MAX_SIZE_BYTES) return err({
        reason: "jwks_fetch_failed",
        status: response.status
      });
      const rawJwks = await readJsonWithSizeLimit$1(response, EMA_JWKS_MAX_SIZE_BYTES);
      if (!rawJwks.ok) return err({ reason: "jwks_fetch_failed" });
      if (!Array.isArray(rawJwks.value.keys)) return err({ reason: "jwks_fetch_failed" });
      const jwks = { keys: rawJwks.value.keys };
      cache.delete(issuer.issuer);
      if (opts.maxEntries !== void 0 && cache.size >= opts.maxEntries) {
        const oldest = cache.keys().next();
        if (!oldest.done) cache.delete(oldest.value);
      }
      cache.set(issuer.issuer, {
        jwks,
        expiresAt: now + cacheTtl,
        nextForceRefreshAllowedAt: now + EMA_JWKS_FORCE_REFRESH_COOLDOWN_SECONDS
      });
      return ok(jwks);
    } catch {
      return err({ reason: "jwks_fetch_failed" });
    } finally {
      clearTimeout(timeoutId);
    }
  } };
}
__name(createDefaultJwksProvider, "createDefaultJwksProvider");
async function readJsonWithSizeLimit$1(response, maxBytes) {
  if (!response.body) return { ok: false };
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        reader.cancel();
        return { ok: false };
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const parsed = JSON.parse(new TextDecoder().decode(merged));
    if (typeof parsed !== "object" || parsed === null) return { ok: false };
    return {
      ok: true,
      value: parsed
    };
  } catch {
    return { ok: false };
  }
}
__name(readJsonWithSizeLimit$1, "readJsonWithSizeLimit$1");
function parseIdJag(assertion, maxBytes) {
  if (typeof assertion !== "string" || assertion.length === 0) return err({ reason: "assertion_missing" });
  if (assertion.length > maxBytes) return err({
    reason: "assertion_too_large",
    size: assertion.length,
    max: maxBytes
  });
  const parts = assertion.split(".");
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) return err({ reason: "assertion_malformed" });
  const [encodedHeader, encodedClaims, encodedSignature] = parts;
  let header;
  let rawClaims;
  let signature;
  try {
    header = parseJwtJsonPart(encodedHeader);
    rawClaims = parseJwtJsonPart(encodedClaims);
    signature = base64UrlToBytes(encodedSignature);
  } catch {
    return err({ reason: "assertion_malformed" });
  }
  const signingInput = new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`);
  return ok({
    header,
    rawClaims,
    signingInput,
    signature
  });
}
__name(parseIdJag, "parseIdJag");
function base64UrlToBytes(base64Url) {
  const base64 = base64Url.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(base64.length + (4 - base64.length % 4) % 4, "=");
  const binaryString = atob(padded);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) bytes[i] = binaryString.charCodeAt(i);
  return bytes;
}
__name(base64UrlToBytes, "base64UrlToBytes");
function parseJwtJsonPart(encoded) {
  try {
    const json2 = new TextDecoder().decode(base64UrlToBytes(encoded));
    const parsed = JSON.parse(json2);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("JWT part must be an object");
    return parsed;
  } catch {
    throw new Error("Malformed JWT part");
  }
}
__name(parseJwtJsonPart, "parseJwtJsonPart");
function selectJwk(jwks, alg, kid) {
  const matching = (jwks.keys ?? []).filter((key) => {
    if (kid && key.kid !== kid) return false;
    if (key.alg && key.alg !== alg) return false;
    if (key.use && key.use !== "sig") return false;
    if (Array.isArray(key.key_ops) && !key.key_ops.includes("verify")) return false;
    if (alg.startsWith("RS") && key.kty !== "RSA") return false;
    if (alg.startsWith("ES") && key.kty !== "EC") return false;
    return true;
  });
  if (kid) {
    const picked = matching[0];
    if (!picked) return err({
      reason: "no_matching_key",
      kid
    });
    return ok(picked);
  }
  if (matching.length !== 1) return err({ reason: "no_matching_key" });
  return ok(matching[0]);
}
__name(selectJwk, "selectJwk");
async function verifyIdJagSignature(input) {
  try {
    const { importAlgorithm, verifyAlgorithm } = getJwtCryptoAlgorithms(input.alg);
    const key = await crypto.subtle.importKey("jwk", input.jwk, importAlgorithm, false, ["verify"]);
    return await crypto.subtle.verify(verifyAlgorithm, key, input.signature, input.signingInput);
  } catch {
    return false;
  }
}
__name(verifyIdJagSignature, "verifyIdJagSignature");
function getJwtCryptoAlgorithms(alg) {
  if (alg === "RS256") {
    const algorithm = {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256"
    };
    return {
      importAlgorithm: algorithm,
      verifyAlgorithm: algorithm
    };
  }
  if (alg === "ES256") return {
    importAlgorithm: {
      name: "ECDSA",
      namedCurve: "P-256"
    },
    verifyAlgorithm: {
      name: "ECDSA",
      hash: "SHA-256"
    }
  };
  throw new Error(`Unsupported JWT alg: ${alg}`);
}
__name(getJwtCryptoAlgorithms, "getJwtCryptoAlgorithms");
var JWT_BEARER_CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";
var CLIENT_ASSERTION_ALGORITHMS = ["RS256", "ES256"];
var CLIENT_ASSERTION_MAX_BYTES = 16 * 1024;
var CLIENT_ASSERTION_CLOCK_SKEW_SECONDS = 60;
var CLIENT_ASSERTION_MAX_LIFETIME_SECONDS = 3600;
var CLIENT_JWKS_CACHE_MAX_ENTRIES = 256;
var CLIENT_ASSERTION_JTI_KV_PREFIX = "client-assertion-jti:";
var CLIENT_AUTHENTICATION_JWT_TYPES = /* @__PURE__ */ new Set(["client-authentication+jwt", "application/client-authentication+jwt"]);
function isKeyUsableForAlgorithm(key, alg) {
  if (key.use !== void 0 && key.use !== "sig") return false;
  if (key.alg !== void 0 && key.alg !== alg) return false;
  if (Array.isArray(key.key_ops) && !key.key_ops.includes("verify")) return false;
  return alg === "RS256" ? key.kty === "RSA" : key.kty === "EC" && key.crv === "P-256";
}
__name(isKeyUsableForAlgorithm, "isKeyUsableForAlgorithm");
function readClientAssertionIssuer(assertion) {
  if (typeof assertion !== "string") return void 0;
  const parsed = parseIdJag(assertion, CLIENT_ASSERTION_MAX_BYTES);
  if (!parsed.ok) return void 0;
  const iss = parsed.value.rawClaims.iss;
  return typeof iss === "string" && iss.length > 0 ? iss : void 0;
}
__name(readClientAssertionIssuer, "readClientAssertionIssuer");
function createClientAssertionVerifier() {
  const jwksProvider = createDefaultJwksProvider({ maxEntries: CLIENT_JWKS_CACHE_MAX_ENTRIES });
  const jtiStore = createKvJtiStore(CLIENT_ASSERTION_JTI_KV_PREFIX);
  return { async verify(input) {
    if (typeof input.assertion !== "string") return err({ reason: "assertion_missing" });
    const parsed = parseIdJag(input.assertion, CLIENT_ASSERTION_MAX_BYTES);
    if (!parsed.ok) return parsed;
    const header = validateHeader(parsed.value.header, input.keys.algorithms);
    if (!header.ok) return header;
    const now = Math.floor(Date.now() / 1e3);
    const claims = validateClaims(parsed.value.rawClaims, input, header.value.typed, now);
    if (!claims.ok) return claims;
    const verified = await verifySignature({
      parsed: parsed.value,
      alg: header.value.alg,
      kid: header.value.kid,
      keys: input.keys,
      jwksProvider,
      now
    });
    if (!verified.ok) return verified;
    return jtiStore.markUsed({
      issuer: input.clientId,
      jti: claims.value.jti,
      exp: claims.value.exp + CLIENT_ASSERTION_CLOCK_SKEW_SECONDS,
      now: Math.floor(Date.now() / 1e3),
      env: input.env
    });
  } };
}
__name(createClientAssertionVerifier, "createClientAssertionVerifier");
function validateHeader(header, algorithms) {
  if (header.crit !== void 0 || header.b64 !== void 0) return err({ reason: "assertion_malformed" });
  const alg = header.alg;
  if (typeof alg !== "string" || !algorithms.includes(alg)) return err({
    reason: "invalid_alg",
    got: alg
  });
  const typ = header.typ;
  let typed = false;
  if (typ !== void 0) {
    const normalized = typeof typ === "string" ? typ.toLowerCase() : "";
    typed = CLIENT_AUTHENTICATION_JWT_TYPES.has(normalized);
    if (!typed && normalized !== "jwt") return err({
      reason: "invalid_typ",
      got: typ
    });
  }
  const kid = header.kid;
  if (kid !== void 0 && (typeof kid !== "string" || kid.length === 0)) return err({ reason: "assertion_malformed" });
  return ok({
    alg,
    kid,
    typed
  });
}
__name(validateHeader, "validateHeader");
function validateClaims(claims, input, typed, now) {
  if (claims.iss !== input.clientId) return err({
    reason: "client_id_mismatch",
    expected: input.clientId,
    got: String(claims.iss)
  });
  if (claims.sub !== input.clientId) return err({
    reason: "client_id_mismatch",
    expected: input.clientId,
    got: String(claims.sub)
  });
  const aud = claims.aud;
  if (!(typed ? aud === input.issuer : aud === input.issuer || aud === input.tokenEndpoint || Array.isArray(aud) && aud.every((value) => typeof value === "string") && (aud.includes(input.issuer) || aud.includes(input.tokenEndpoint)))) return err({
    reason: "aud_mismatch",
    expected: input.issuer,
    got: Array.isArray(aud) ? aud.map(String) : String(aud)
  });
  const exp = claims.exp;
  if (typeof exp !== "number" || !Number.isInteger(exp)) return err({
    reason: "invalid_claim",
    claim: "exp"
  });
  if (exp + CLIENT_ASSERTION_CLOCK_SKEW_SECONDS <= now) return err({
    reason: "expired",
    exp,
    now
  });
  if (exp - now > CLIENT_ASSERTION_MAX_LIFETIME_SECONDS) return err({
    reason: "lifetime_too_long",
    lifetime: exp - now,
    max: CLIENT_ASSERTION_MAX_LIFETIME_SECONDS
  });
  const nbf = claims.nbf;
  if (nbf !== void 0) {
    if (typeof nbf !== "number" || !Number.isInteger(nbf)) return err({
      reason: "invalid_claim",
      claim: "nbf"
    });
    if (nbf > now + CLIENT_ASSERTION_CLOCK_SKEW_SECONDS) return err({
      reason: "nbf_in_future",
      nbf,
      now,
      skew: CLIENT_ASSERTION_CLOCK_SKEW_SECONDS
    });
  }
  const iat = claims.iat;
  if (iat !== void 0) {
    if (typeof iat !== "number" || !Number.isInteger(iat)) return err({
      reason: "invalid_claim",
      claim: "iat"
    });
    if (iat > now + CLIENT_ASSERTION_CLOCK_SKEW_SECONDS) return err({
      reason: "iat_in_future",
      iat,
      now,
      skew: CLIENT_ASSERTION_CLOCK_SKEW_SECONDS
    });
  }
  const jti = claims.jti;
  if (typeof jti !== "string" || jti.length === 0) return err({
    reason: "invalid_claim",
    claim: "jti"
  });
  return ok({
    jti,
    exp
  });
}
__name(validateClaims, "validateClaims");
async function verifySignature(args) {
  const { keys, alg, kid, parsed } = args;
  const verifyWith = /* @__PURE__ */ __name(async (jwks) => {
    const jwk = selectJwk(jwks, alg, kid);
    if (!jwk.ok) return jwk;
    return await verifyIdJagSignature({
      alg,
      jwk: jwk.value,
      signingInput: parsed.signingInput,
      signature: parsed.signature
    }) ? ok(void 0) : err({ reason: "signature_failed" });
  }, "verifyWith");
  if (keys.jwks) return verifyWith(keys.jwks);
  if (!keys.jwksUri) return err({ reason: "no_matching_key" });
  const source = {
    issuer: keys.jwksUri,
    jwksUri: keys.jwksUri
  };
  const initial = await args.jwksProvider.fetch(source, {
    forceRefresh: false,
    now: args.now
  });
  if (!initial.ok) return initial;
  const result = await verifyWith(initial.value);
  if (result.ok) return result;
  const refreshed = await args.jwksProvider.fetch(source, {
    forceRefresh: true,
    now: args.now
  });
  if (!refreshed.ok) return refreshed;
  return verifyWith(refreshed.value);
}
__name(verifySignature, "verifySignature");
function isLoopbackHostname(hostname) {
  const host = hostname.toLowerCase();
  if (host === "localhost" || host === "::1" || host === "[::1]") return true;
  const ipv4 = /^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  return ipv4 !== null && ipv4.slice(1).every((octet) => Number(octet) <= 255);
}
__name(isLoopbackHostname, "isLoopbackHostname");
function hasAcceptedCanonicalScheme(url) {
  return url.protocol === "https:" || url.protocol === "http:" && isLoopbackHostname(url.hostname);
}
__name(hasAcceptedCanonicalScheme, "hasAcceptedCanonicalScheme");
function validateResourceUri(uri) {
  if (!uri || typeof uri !== "string") return false;
  if (!/^[\x21-\x7e]+$/.test(uri) || /["\\#]/.test(uri) || !/^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/?#]+(?:\/[^?#]*)?(?:\?[^#]*)?$/.test(uri) || /%(?![0-9A-Fa-f]{2})/.test(uri) || !/^[A-Za-z0-9:/?@!$&'()*+,;=._~%\[\]-]+$/.test(uri)) return false;
  try {
    const parsed = new URL(uri);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}
__name(validateResourceUri, "validateResourceUri");
function resourceMatches(requested, granted) {
  const foldedRequested = foldResourceSchemeAndHost(requested);
  const foldedGranted = foldResourceSchemeAndHost(granted);
  if (foldedRequested === void 0 || foldedGranted === void 0) return false;
  return normalizeEmptyPath(foldedRequested) === normalizeEmptyPath(foldedGranted);
}
__name(resourceMatches, "resourceMatches");
function foldResourceSchemeAndHost(resource) {
  const schemeSeparator = resource.indexOf("://");
  if (schemeSeparator <= 0) return void 0;
  const authorityStart = schemeSeparator + 3;
  const authorityEndOffset = resource.slice(authorityStart).search(/[/?#]/);
  const authorityEnd = authorityEndOffset === -1 ? resource.length : authorityStart + authorityEndOffset;
  const authority = resource.slice(authorityStart, authorityEnd);
  const hostStart = authority.lastIndexOf("@") + 1;
  let hostEnd;
  if (authority[hostStart] === "[") {
    const closingBracket = authority.indexOf("]", hostStart + 1);
    if (closingBracket === -1) return void 0;
    hostEnd = closingBracket + 1;
  } else {
    const portSeparator = authority.indexOf(":", hostStart);
    hostEnd = portSeparator === -1 ? authority.length : portSeparator;
  }
  const asciiLower = /* @__PURE__ */ __name((value) => value.replace(/[A-Z]/g, (character) => character.toLowerCase()), "asciiLower");
  return asciiLower(resource.slice(0, schemeSeparator)) + "://" + authority.slice(0, hostStart) + asciiLower(authority.slice(hostStart, hostEnd)) + authority.slice(hostEnd) + resource.slice(authorityEnd);
}
__name(foldResourceSchemeAndHost, "foldResourceSchemeAndHost");
function normalizeEmptyPath(resource) {
  const authorityStart = resource.indexOf("://") + 3;
  const pathOffset = resource.slice(authorityStart).search(/[/?#]/);
  if (pathOffset === -1) return `${resource}/`;
  const pathStart = authorityStart + pathOffset;
  return resource[pathStart] === "/" ? resource : `${resource.slice(0, pathStart)}/${resource.slice(pathStart)}`;
}
__name(normalizeEmptyPath, "normalizeEmptyPath");
function requestCarriesResourceQuery(requestUrl, resourceUrl) {
  for (const [name, value] of resourceUrl.searchParams) if (!requestUrl.searchParams.getAll(name).includes(value)) return false;
  return true;
}
__name(requestCarriesResourceQuery, "requestCarriesResourceQuery");
function findCoveringResource(requested, configured) {
  let url;
  try {
    url = new URL(requested);
  } catch {
    return;
  }
  if (url.search === "") return void 0;
  const covering = configured.map((resource) => ({
    resource,
    url: new URL(resource)
  })).filter((candidate) => candidate.url.origin === url.origin && (candidate.url.pathname || "/") === (url.pathname || "/") && requestCarriesResourceQuery(url, candidate.url)).map(({ resource, url: url$1 }) => ({
    resource,
    specificity: [...url$1.searchParams].length
  })).sort((a, b) => b.specificity - a.specificity);
  if (covering.length === 0) return void 0;
  if (covering.length > 1 && covering[0].specificity === covering[1].specificity) return void 0;
  return covering[0].resource;
}
__name(findCoveringResource, "findCoveringResource");
var CIMD_MAX_SIZE_BYTES = 5 * 1024;
var CIMD_FETCH_TIMEOUT_MS = 1e4;
var CIMD_CACHE_NAME = "workers-oauth-provider:cimd:v1";
var CIMD_CACHE_MAX_TTL_SECONDS = 10080 * 60;
function requireJsonObject(value) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Client metadata must be a JSON object");
  return value;
}
__name(requireJsonObject, "requireJsonObject");
function optionalString(value, fieldName) {
  if (value === void 0) return void 0;
  if (typeof value !== "string") throw new Error(`Invalid ${fieldName}: expected string, got ${typeof value}`);
  return value;
}
__name(optionalString, "optionalString");
function optionalStringArray(value, fieldName) {
  if (value === void 0) return void 0;
  if (!Array.isArray(value)) throw new Error(`Invalid ${fieldName}: expected array, got ${typeof value}`);
  if (!value.every((item) => typeof item === "string")) throw new Error(`Invalid ${fieldName}: array must contain only strings`);
  return [...value];
}
__name(optionalStringArray, "optionalStringArray");
function optionalHttpUri(value, fieldName) {
  const uri = optionalString(value, fieldName);
  if (uri === void 0) return void 0;
  let parsed;
  try {
    parsed = new URL(uri);
  } catch {
    throw new Error(`Invalid ${fieldName}: must be an absolute http: or https: URL`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error(`Invalid ${fieldName}: must be an absolute http: or https: URL`);
  return uri;
}
__name(optionalHttpUri, "optionalHttpUri");
var I18N_FIELDS = {
  client_name: "string",
  client_uri: "uri",
  logo_uri: "uri",
  tos_uri: "uri",
  policy_uri: "uri"
};
function extractI18nFields(raw) {
  const result = {};
  for (const key of Object.keys(raw)) {
    const hashIndex = key.indexOf("#");
    if (hashIndex <= 0 || hashIndex === key.length - 1) continue;
    const kind = I18N_FIELDS[key.slice(0, hashIndex)];
    if (!kind) continue;
    const value = kind === "uri" ? optionalHttpUri(raw[key], key) : optionalString(raw[key], key);
    if (value !== void 0) result[key] = value;
  }
  return Object.keys(result).length > 0 ? result : void 0;
}
__name(extractI18nFields, "extractI18nFields");
function validateChoiceConsistency(preferredName, preferredValue, choicesName, choices) {
  if (preferredValue !== void 0 && choices !== void 0 && !choices.includes(preferredValue)) throw new Error(`${preferredName} must be included in ${choicesName}`);
}
__name(validateChoiceConsistency, "validateChoiceConsistency");
function parseOAuthClientMetadata(raw) {
  const tokenEndpointAuthMethod = optionalString(raw.token_endpoint_auth_method, "token_endpoint_auth_method");
  const tokenEndpointAuthMethodsSupported = optionalStringArray(raw.token_endpoint_auth_methods_supported, "token_endpoint_auth_methods_supported");
  const tokenEndpointAuthSigningAlg = optionalString(raw.token_endpoint_auth_signing_alg, "token_endpoint_auth_signing_alg");
  const tokenEndpointAuthSigningAlgValuesSupported = optionalStringArray(raw.token_endpoint_auth_signing_alg_values_supported, "token_endpoint_auth_signing_alg_values_supported");
  validateChoiceConsistency("token_endpoint_auth_method", tokenEndpointAuthMethod, "token_endpoint_auth_methods_supported", tokenEndpointAuthMethodsSupported);
  validateChoiceConsistency("token_endpoint_auth_signing_alg", tokenEndpointAuthSigningAlg, "token_endpoint_auth_signing_alg_values_supported", tokenEndpointAuthSigningAlgValuesSupported);
  return {
    clientId: optionalString(raw.client_id, "client_id"),
    redirectUris: optionalStringArray(raw.redirect_uris, "redirect_uris"),
    clientName: optionalString(raw.client_name, "client_name"),
    clientUri: optionalHttpUri(raw.client_uri, "client_uri"),
    logoUri: optionalHttpUri(raw.logo_uri, "logo_uri"),
    policyUri: optionalHttpUri(raw.policy_uri, "policy_uri"),
    tosUri: optionalHttpUri(raw.tos_uri, "tos_uri"),
    jwksUri: optionalHttpUri(raw.jwks_uri, "jwks_uri"),
    i18n: extractI18nFields(raw),
    contacts: optionalStringArray(raw.contacts, "contacts"),
    grantTypes: optionalStringArray(raw.grant_types, "grant_types"),
    responseTypes: optionalStringArray(raw.response_types, "response_types"),
    tokenEndpointAuthMethod,
    tokenEndpointAuthMethodsSupported,
    tokenEndpointAuthSigningAlg,
    tokenEndpointAuthSigningAlgValuesSupported
  };
}
__name(parseOAuthClientMetadata, "parseOAuthClientMetadata");
function pickDisplayMetadata(metadata) {
  const { clientName, clientUri, logoUri, policyUri, tosUri, jwksUri, i18n, contacts } = metadata;
  return {
    clientName,
    clientUri,
    logoUri,
    policyUri,
    tosUri,
    jwksUri,
    i18n,
    contacts
  };
}
__name(pickDisplayMetadata, "pickDisplayMetadata");
function validateRedirectUriSafety(redirectUri) {
  const dangerousSchemes = [
    "javascript:",
    "data:",
    "vbscript:",
    "file:",
    "mailto:",
    "blob:"
  ];
  const normalized = redirectUri.trim();
  for (let i = 0; i < normalized.length; i++) {
    const code = normalized.charCodeAt(i);
    if (code >= 0 && code <= 31 || code >= 127 && code <= 159) throw new Error("Invalid redirect URI");
  }
  const colonIndex = normalized.indexOf(":");
  if (colonIndex === -1) throw new Error("Invalid redirect URI");
  const scheme = normalized.slice(0, colonIndex + 1).toLowerCase();
  if (dangerousSchemes.includes(scheme)) throw new Error("Invalid redirect URI");
}
__name(validateRedirectUriSafety, "validateRedirectUriSafety");
function validateListedRedirectUri(redirectUri) {
  validateRedirectUriSafety(redirectUri);
  const normalized = redirectUri.trim();
  let url;
  try {
    url = new URL(normalized);
  } catch {
    throw new Error("Invalid redirect URI");
  }
  if (normalized.includes("#") || url.username || url.password) throw new Error("Invalid redirect URI");
  return url;
}
__name(validateListedRedirectUri, "validateListedRedirectUri");
function validateRedirectUri(redirectUri, server) {
  const url = validateListedRedirectUri(redirectUri);
  if (url.protocol === "https:") return;
  if (url.protocol === "http:") {
    if (isLoopbackHostname(url.hostname)) return;
    throw new Error("Redirect URI must use https, or http on a loopback host");
  }
  if (!server.allowPrivateUseRedirectUris) throw new Error("Redirect URI must use https, or http on a loopback host");
}
__name(validateRedirectUri, "validateRedirectUri");
function validateRegisteredRedirectUris(redirectUris, server) {
  if (!redirectUris || redirectUris.length === 0) throw new Error("redirect_uris is required and must not be empty");
  for (const redirectUri of redirectUris) validateListedRedirectUri(redirectUri);
  let firstRefusal;
  for (const redirectUri of redirectUris) try {
    validateRedirectUri(redirectUri, server);
    return redirectUris;
  } catch (error) {
    firstRefusal ??= error;
  }
  throw firstRefusal instanceof Error ? firstRefusal : /* @__PURE__ */ new Error("Invalid redirect URI");
}
__name(validateRegisteredRedirectUris, "validateRegisteredRedirectUris");
function requireValidRedirectUris(redirectUris, validate) {
  if (!redirectUris || redirectUris.length === 0) throw new Error("redirect_uris is required and must not be empty");
  for (const redirectUri of redirectUris) validate(redirectUri);
  return redirectUris;
}
__name(requireValidRedirectUris, "requireValidRedirectUris");
function resolveDynamicClientRegistrationMetadata(raw, server) {
  const metadata = parseOAuthClientMetadata(raw);
  const capabilities = negotiateDynamicClientRegistrationCapabilities(server, {
    tokenEndpointAuthMethod: metadata.tokenEndpointAuthMethod,
    tokenEndpointAuthMethodsSupported: metadata.tokenEndpointAuthMethodsSupported,
    grantTypes: metadata.grantTypes ?? ["authorization_code"],
    responseTypes: metadata.responseTypes ?? ["code"]
  });
  return {
    ...pickDisplayMetadata(metadata),
    redirectUris: validateRegisteredRedirectUris(metadata.redirectUris, server),
    ...capabilities,
    authMethodExplicit: metadata.tokenEndpointAuthMethod !== void 0 || metadata.tokenEndpointAuthMethodsSupported !== void 0
  };
}
__name(resolveDynamicClientRegistrationMetadata, "resolveDynamicClientRegistrationMetadata");
function rawPath(clientId) {
  const schemeEnd = clientId.indexOf("://");
  if (schemeEnd === -1) return "";
  const authorityStart = schemeEnd + 3;
  const authorityEndOffset = clientId.slice(authorityStart).search(/[/?#]/);
  if (authorityEndOffset === -1) return "";
  const pathStart = authorityStart + authorityEndOffset;
  if (clientId[pathStart] !== "/") return "";
  const pathEndOffset = clientId.slice(pathStart).search(/[?#]/);
  return pathEndOffset === -1 ? clientId.slice(pathStart) : clientId.slice(pathStart, pathStart + pathEndOffset);
}
__name(rawPath, "rawPath");
function validateClientIdentifierUrl(clientId) {
  if (clientId !== clientId.trim() || /[\x00-\x20\x7f-\x9f\\]/.test(clientId)) throw new Error("Client Identifier URL contains invalid whitespace or characters");
  if (!/^https:\/\//i.test(clientId)) throw new Error("Client Identifier URL must use an absolute HTTPS URL");
  let parsed;
  try {
    parsed = new URL(clientId);
  } catch {
    throw new Error("Client Identifier URL must be a valid HTTPS URL");
  }
  if (parsed.protocol !== "https:") throw new Error("Client Identifier URL must use HTTPS");
  if (parsed.username || parsed.password) throw new Error("Client Identifier URL must not contain userinfo");
  if (parsed.hash) throw new Error("Client Identifier URL must not contain a fragment");
  const path = rawPath(clientId);
  if (!path) throw new Error("Client Identifier URL must contain a path component");
  for (const segment of path.split("/")) {
    let decodedSegment;
    try {
      decodedSegment = decodeURIComponent(segment);
    } catch {
      throw new Error("Client Identifier URL contains invalid percent encoding");
    }
    if (decodedSegment === "." || decodedSegment === "..") throw new Error("Client Identifier URL must not contain dot path segments");
  }
}
__name(validateClientIdentifierUrl, "validateClientIdentifierUrl");
function isClientIdMetadataDocumentUrl(clientId) {
  try {
    return new URL(clientId).protocol === "https:" && rawPath(clientId) !== "";
  } catch {
    return false;
  }
}
__name(isClientIdMetadataDocumentUrl, "isClientIdMetadataDocumentUrl");
var PRIVATE_JWK_MEMBERS = /* @__PURE__ */ new Set([
  "d",
  "p",
  "q",
  "dp",
  "dq",
  "qi",
  "oth",
  "k"
]);
function parsePublicJwks(value) {
  if (value === void 0) return void 0;
  const jwks = requireJsonObject(value);
  if (!Array.isArray(jwks.keys)) throw new Error("Invalid jwks: keys must be an array");
  return { keys: jwks.keys.map((value$1) => {
    const key = requireJsonObject(value$1);
    if (Object.keys(key).some((member) => PRIVATE_JWK_MEMBERS.has(member))) throw new Error("CIMD documents must not contain private key material");
    return key;
  }) };
}
__name(parsePublicJwks, "parsePublicJwks");
function resolvePrivateKeyJwtKeys(metadata, jwks) {
  const { jwksUri } = metadata;
  if (jwks && jwksUri) return { problem: "jwks and jwks_uri must not both be present" };
  if (!jwks && !jwksUri) return { problem: "private_key_jwt requires jwks or jwks_uri" };
  if (jwks && (jwks.keys ?? []).length === 0) return { problem: "private_key_jwt jwks must contain a key" };
  if (jwksUri) {
    const url = new URL(jwksUri);
    if (url.protocol !== "https:" || url.username || url.password || url.hash) return { problem: "private_key_jwt jwks_uri must be an https: URL without userinfo or a fragment" };
  }
  const signingAlgorithms = CLIENT_ASSERTION_ALGORITHMS.filter((alg) => (metadata.tokenEndpointAuthSigningAlg === void 0 || metadata.tokenEndpointAuthSigningAlg === alg) && (metadata.tokenEndpointAuthSigningAlgValuesSupported === void 0 || metadata.tokenEndpointAuthSigningAlgValuesSupported.includes(alg)));
  if (signingAlgorithms.length === 0) return { problem: `private_key_jwt requires a token_endpoint_auth_signing_alg of ${CLIENT_ASSERTION_ALGORITHMS.join(" or ")}` };
  const algorithms = jwks ? signingAlgorithms.filter((alg) => (jwks.keys ?? []).some((key) => isKeyUsableForAlgorithm(key, alg))) : signingAlgorithms;
  if (algorithms.length === 0) return { problem: `private_key_jwt jwks has no key for ${signingAlgorithms.join(" or ")}` };
  return { keys: jwks ? {
    jwks,
    algorithms
  } : {
    jwksUri,
    algorithms
  } };
}
__name(resolvePrivateKeyJwtKeys, "resolvePrivateKeyJwtKeys");
function resolveClientIdMetadataDocument(metadataUrl, value, server) {
  const raw = requireJsonObject(value);
  const metadata = parseOAuthClientMetadata(raw);
  if (metadata.clientId !== metadataUrl) throw new Error(`client_id "${metadata.clientId}" does not match metadata URL "${metadataUrl}"`);
  if (!metadata.clientName?.trim()) throw new Error("client_name is required and must not be empty");
  const redirectUris = requireValidRedirectUris(metadata.redirectUris, validateRedirectUriSafety);
  if ("client_secret" in raw || "client_secret_expires_at" in raw) throw new Error("CIMD documents must not contain client secrets");
  const jwks = parsePublicJwks(raw.jwks);
  const privateKeyJwt = metadata.tokenEndpointAuthMethod === "private_key_jwt" || !!metadata.tokenEndpointAuthMethodsSupported?.includes("private_key_jwt") ? resolvePrivateKeyJwtKeys(metadata, jwks) : void 0;
  const clientAssertionKeys = privateKeyJwt && "keys" in privateKeyJwt ? privateKeyJwt.keys : void 0;
  let capabilities;
  try {
    capabilities = negotiateCimdClientCapabilities(server, {
      tokenEndpointAuthMethod: metadata.tokenEndpointAuthMethod,
      tokenEndpointAuthMethodsSupported: metadata.tokenEndpointAuthMethodsSupported,
      grantTypes: metadata.grantTypes ?? ["authorization_code"],
      responseTypes: metadata.responseTypes ?? ["code"]
    }, { privateKeyJwt: clientAssertionKeys !== void 0 });
  } catch (error) {
    if (privateKeyJwt && "problem" in privateKeyJwt) throw new Error(privateKeyJwt.problem);
    throw error;
  }
  return {
    ...pickDisplayMetadata(metadata),
    clientId: metadata.clientId,
    clientName: metadata.clientName,
    redirectUris,
    ...capabilities,
    ...capabilities.tokenEndpointAuthMethods.includes("private_key_jwt") ? { clientAssertionKeys } : {}
  };
}
__name(resolveClientIdMetadataDocument, "resolveClientIdMetadataDocument");
function readStreamChunk(reader, signal) {
  if (signal.aborted) return Promise.reject(new DOMException("Aborted", "AbortError"));
  return new Promise((resolve, reject) => {
    const abort = /* @__PURE__ */ __name(() => {
      reader.cancel().catch(() => void 0);
      reject(new DOMException("Aborted", "AbortError"));
    }, "abort");
    signal.addEventListener("abort", abort, { once: true });
    reader.read().then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}
__name(readStreamChunk, "readStreamChunk");
async function readJsonWithSizeLimit(response, maxBytes, signal) {
  const contentLength = response.headers.get("Content-Length");
  if (contentLength !== null) {
    const declaredSize = Number(contentLength);
    if (Number.isFinite(declaredSize) && declaredSize > maxBytes) {
      await response.body?.cancel().catch(() => void 0);
      throw new Error(`Client metadata exceeds size limit: ${contentLength} bytes (max ${maxBytes})`);
    }
  }
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Client metadata response body is empty");
  const chunks = [];
  let totalSize = 0;
  while (true) {
    const { done, value } = await readStreamChunk(reader, signal);
    if (done) break;
    if (!value) continue;
    totalSize += value.length;
    if (totalSize > maxBytes) {
      await reader.cancel().catch(() => void 0);
      throw new Error(`Response exceeded size limit of ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  const bytes = new Uint8Array(totalSize);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  let text;
  try {
    text = new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: false
    }).decode(bytes);
  } catch {
    throw new Error("Client metadata response is not valid UTF-8");
  }
  try {
    return {
      value: JSON.parse(text),
      bytes
    };
  } catch {
    throw new Error("Client metadata response is not valid JSON");
  }
}
__name(readJsonWithSizeLimit, "readJsonWithSizeLimit");
function fetchCimdOrigin(metadataUrl, signal) {
  return fetch(metadataUrl, {
    headers: {
      Accept: "application/json",
      "Cache-Control": "no-store",
      "User-Agent": OUTBOUND_USER_AGENT
    },
    signal,
    cache: "no-store"
  });
}
__name(fetchCimdOrigin, "fetchCimdOrigin");
async function openCimdCache() {
  if (typeof caches === "undefined") return void 0;
  try {
    return await caches.open(CIMD_CACHE_NAME);
  } catch {
    return;
  }
}
__name(openCimdCache, "openCimdCache");
function cacheTtlSeconds(response) {
  const cacheControl = response.headers.get("Cache-Control");
  if (cacheControl === null || /(?:^|,)\s*(?:no-cache|no-store|private)\b/i.test(cacheControl)) return void 0;
  const directive = /(?:^|,)\s*s-maxage\s*=\s*"?(\d+)/i.exec(cacheControl) ?? /(?:^|,)\s*max-age\s*=\s*"?(\d+)/i.exec(cacheControl);
  if (!directive) return void 0;
  const ttl = Math.min(Number(directive[1]), CIMD_CACHE_MAX_TTL_SECONDS);
  return ttl > 0 ? ttl : void 0;
}
__name(cacheTtlSeconds, "cacheTtlSeconds");
async function cacheValidatedDocument(cache, metadataUrl, response, bytes) {
  if (!cache) return;
  const ttl = cacheTtlSeconds(response);
  if (ttl === void 0) return;
  const headers = new Headers({ "Cache-Control": `public, max-age=${ttl}` });
  for (const name of [
    "Content-Type",
    "ETag",
    "Last-Modified"
  ]) {
    const value = response.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  try {
    await cache.put(metadataUrl, new Response(bytes, {
      status: 200,
      headers
    }));
  } catch {
  }
}
__name(cacheValidatedDocument, "cacheValidatedDocument");
async function tryResolveFromCache(cache, metadataUrl, server, signal) {
  let cached;
  try {
    cached = await cache?.match(metadataUrl);
  } catch {
    return;
  }
  if (!cached) return void 0;
  try {
    const { value } = await readJsonWithSizeLimit(cached, CIMD_MAX_SIZE_BYTES, signal);
    return resolveClientIdMetadataDocument(metadataUrl, value, server);
  } catch (error) {
    if (signal.aborted) throw error;
    try {
      await cache?.delete(metadataUrl);
    } catch {
    }
    return;
  }
}
__name(tryResolveFromCache, "tryResolveFromCache");
async function fetchClientIdMetadataDocument(metadataUrl, server) {
  validateClientIdentifierUrl(metadataUrl);
  const abortController = new AbortController();
  const timeoutId = setTimeout(() => abortController.abort(), CIMD_FETCH_TIMEOUT_MS);
  try {
    const cache = await openCimdCache();
    const cachedDocument = await tryResolveFromCache(cache, metadataUrl, server, abortController.signal);
    if (cachedDocument) return cachedDocument;
    const response = await fetchCimdOrigin(metadataUrl, abortController.signal);
    if (!response.ok) throw new Error(`Failed to fetch client metadata: HTTP ${response.status}`);
    const { value, bytes } = await readJsonWithSizeLimit(response, CIMD_MAX_SIZE_BYTES, abortController.signal);
    const resolved = resolveClientIdMetadataDocument(metadataUrl, value, server);
    clearTimeout(timeoutId);
    await cacheValidatedDocument(cache, metadataUrl, response, bytes);
    return resolved;
  } catch (error) {
    if (abortController.signal.aborted) throw new Error(`Client metadata fetch timed out after ${CIMD_FETCH_TIMEOUT_MS}ms`);
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}
__name(fetchClientIdMetadataDocument, "fetchClientIdMetadataDocument");
function validateIdJagHeader(header, expectedTyp, supportedAlgs) {
  const typ = header.typ;
  if (typeof typ !== "string" || typ !== expectedTyp) return err({
    reason: "invalid_typ",
    got: typ
  });
  const alg = header.alg;
  if (typeof alg !== "string" || alg === "none" || !supportedAlgs.has(alg)) return err({
    reason: "invalid_alg",
    got: alg
  });
  const kidRaw = header.kid;
  return ok({
    typ,
    alg,
    kid: typeof kidRaw === "string" && kidRaw.length > 0 ? kidRaw : void 0
  });
}
__name(validateIdJagHeader, "validateIdJagHeader");
async function resolveTrustedIssuer(input) {
  const { iss, alg, resolver, env, request, clientInfo } = input;
  if (typeof iss !== "string" || iss.length === 0) return err({
    reason: "invalid_claim",
    claim: "iss"
  });
  let resolved;
  try {
    resolved = await resolver({
      iss,
      env,
      request,
      clientInfo
    });
  } catch {
    return err({
      reason: "issuer_not_trusted",
      iss
    });
  }
  if (!resolved) return err({
    reason: "issuer_not_trusted",
    iss
  });
  if (resolved.issuer !== iss) return err({
    reason: "issuer_not_trusted",
    iss
  });
  if (!isWellFormedTrustedIssuer(resolved)) return err({
    reason: "issuer_not_trusted",
    iss
  });
  if (!(resolved.algorithms ?? [EMA_DEFAULT_JWT_ALGORITHM]).includes(alg)) return err({
    reason: "invalid_alg",
    got: alg
  });
  return ok(resolved);
}
__name(resolveTrustedIssuer, "resolveTrustedIssuer");
function isWellFormedTrustedIssuer(issuer) {
  let issuerUrl;
  try {
    issuerUrl = new URL(issuer.issuer);
  } catch {
    return false;
  }
  if (issuerUrl.protocol !== "https:") return false;
  let jwksUrl;
  try {
    jwksUrl = new URL(issuer.jwksUri);
  } catch {
    return false;
  }
  if (jwksUrl.protocol !== "https:") return false;
  const algorithms = issuer.algorithms ?? [EMA_DEFAULT_JWT_ALGORITHM];
  if (algorithms.length === 0) return false;
  for (const alg of algorithms) if (!EMA_SUPPORTED_JWT_ALGORITHMS.has(alg)) return false;
  if (issuer.audience !== void 0) try {
    new URL(issuer.audience);
  } catch {
    return false;
  }
  return true;
}
__name(isWellFormedTrustedIssuer, "isWellFormedTrustedIssuer");
function validateIdJagClaims(input) {
  const { rawClaims, trustedIssuer, expectedAudience, clientId, configuredResource } = input;
  const { now, clockSkewSeconds, maxAssertionLifetimeSeconds } = input;
  const iss = readRequiredString(rawClaims, "iss");
  if (!iss.ok) return iss;
  if (iss.value !== trustedIssuer.issuer) return err({
    reason: "issuer_not_trusted",
    iss: iss.value
  });
  const sub = readRequiredString(rawClaims, "sub");
  if (!sub.ok) return sub;
  const aud = readAudienceClaim(rawClaims);
  if (!aud.ok) return aud;
  for (const claim of ["authorization_details", "cnf"]) if (rawClaims[claim] !== void 0) return err({
    reason: "unsupported_claim",
    claim
  });
  const resource = rawClaims.resource === void 0 ? ok(configuredResource) : readRequiredString(rawClaims, "resource");
  if (!resource.ok) return resource;
  const claimClientId = readRequiredString(rawClaims, "client_id");
  if (!claimClientId.ok) return claimClientId;
  const jti = readRequiredString(rawClaims, "jti");
  if (!jti.ok) return jti;
  const exp = readNumericDateClaim(rawClaims, "exp");
  if (!exp.ok) return exp;
  const iat = readNumericDateClaim(rawClaims, "iat");
  if (!iat.ok) return iat;
  if ((Array.isArray(aud.value) ? aud.value[0] : aud.value) !== expectedAudience) return err({
    reason: "aud_mismatch",
    expected: expectedAudience,
    got: aud.value
  });
  if (claimClientId.value !== clientId) return err({
    reason: "client_id_mismatch",
    expected: clientId,
    got: claimClientId.value
  });
  if (!validateResourceUri(resource.value)) return err({
    reason: "resource_invalid",
    resource: resource.value
  });
  if (!resourceMatches(resource.value, configuredResource)) return err({
    reason: "resource_mismatch",
    expected: configuredResource,
    got: resource.value
  });
  if (exp.value + clockSkewSeconds <= now) return err({
    reason: "expired",
    exp: exp.value,
    now
  });
  if (iat.value > now + clockSkewSeconds) return err({
    reason: "iat_in_future",
    iat: iat.value,
    now,
    skew: clockSkewSeconds
  });
  if (rawClaims.nbf !== void 0) {
    const nbf = readNumericDateClaim(rawClaims, "nbf");
    if (!nbf.ok) return nbf;
    if (nbf.value > now + clockSkewSeconds) return err({
      reason: "nbf_in_future",
      nbf: nbf.value,
      now,
      skew: clockSkewSeconds
    });
  }
  const lifetime = exp.value - iat.value;
  if (lifetime > maxAssertionLifetimeSeconds + clockSkewSeconds) return err({
    reason: "lifetime_too_long",
    lifetime,
    max: maxAssertionLifetimeSeconds
  });
  let scope;
  let assertionScopes = [];
  if (rawClaims.scope !== void 0) {
    const parsed = readRequiredString(rawClaims, "scope");
    if (!parsed.ok) return parsed;
    const tokens = parsed.value.split(" ").filter(Boolean);
    for (const token of tokens) if (!isValidOAuthScopeToken(token)) return err({
      reason: "invalid_claim",
      claim: "scope"
    });
    scope = parsed.value;
    assertionScopes = tokens;
  }
  return ok({
    claims: {
      ...rawClaims,
      iss: iss.value,
      sub: sub.value,
      aud: aud.value,
      resource: resource.value,
      client_id: claimClientId.value,
      jti: jti.value,
      exp: exp.value,
      iat: iat.value,
      scope
    },
    resource: resource.value,
    assertionScopes
  });
}
__name(validateIdJagClaims, "validateIdJagClaims");
function parseEmaScopeParam(scope, assertionScopes) {
  let requested;
  if (scope === void 0) requested = [...assertionScopes];
  else if (typeof scope === "string") {
    const tokens = scope.split(" ").filter(Boolean);
    for (const token of tokens) if (!isValidOAuthScopeToken(token)) return err({ reason: "invalid_scope_param" });
    requested = tokens;
  } else if (Array.isArray(scope) && scope.every((value) => typeof value === "string")) {
    requested = [];
    for (const part of scope) {
      const tokens = part.split(" ").filter(Boolean);
      for (const token of tokens) if (!isValidOAuthScopeToken(token)) return err({ reason: "invalid_scope_param" });
      requested.push(...tokens);
    }
  } else return err({ reason: "invalid_scope_param" });
  if (assertionScopes.length > 0) {
    const allowed = new Set(assertionScopes);
    requested = requested.filter((token) => allowed.has(token));
  }
  return ok(requested);
}
__name(parseEmaScopeParam, "parseEmaScopeParam");
function validateEmaMapperResult(result) {
  if (result === null) return err({ reason: "mapper_denied" });
  if (typeof result !== "object") return err({ reason: "invalid_mapped_user" });
  const r = result;
  if (typeof r.userId !== "string" || r.userId.length === 0 || r.userId.includes(":")) return err({ reason: "invalid_mapped_user" });
  if (!Array.isArray(r.scope) || !r.scope.every((s) => typeof s === "string" && isValidOAuthScopeToken(s))) return err({ reason: "invalid_mapped_scope" });
  if (!("props" in r) || r.props === void 0) return err({ reason: "invalid_mapped_props" });
  if (r.accessTokenTTL !== void 0) {
    if (typeof r.accessTokenTTL !== "number" || !Number.isFinite(r.accessTokenTTL) || r.accessTokenTTL <= 0) return err({ reason: "invalid_mapped_ttl" });
  }
  return ok({
    userId: r.userId,
    scope: r.scope,
    props: r.props,
    metadata: r.metadata,
    accessTokenTTL: r.accessTokenTTL
  });
}
__name(validateEmaMapperResult, "validateEmaMapperResult");
function computeEmaAccessTokenTTL(input) {
  const { configuredDefaultSeconds, assertionExp, mapperTtl, now, minTtlSeconds } = input;
  if (assertionExp - now <= 0) return err({ reason: "assertion_expired_after_processing" });
  const ttl = mapperTtl ?? configuredDefaultSeconds;
  if (ttl < minTtlSeconds) return err({ reason: "invalid_mapped_ttl" });
  return ok(ttl);
}
__name(computeEmaAccessTokenTTL, "computeEmaAccessTokenTTL");
function readRequiredString(claims, claimName) {
  const value = claims[claimName];
  if (typeof value !== "string" || value.length === 0) return err({
    reason: "invalid_claim",
    claim: claimName
  });
  return ok(value);
}
__name(readRequiredString, "readRequiredString");
function readAudienceClaim(claims) {
  const aud = claims.aud;
  if (typeof aud === "string" && aud.length > 0) return ok(aud);
  if (Array.isArray(aud) && aud.length === 1 && typeof aud[0] === "string" && aud[0].length > 0) return ok(aud);
  return err({
    reason: "invalid_claim",
    claim: "aud"
  });
}
__name(readAudienceClaim, "readAudienceClaim");
function readNumericDateClaim(claims, claimName) {
  const value = claims[claimName];
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) return err({
    reason: "invalid_claim",
    claim: claimName
  });
  return ok(value);
}
__name(readNumericDateClaim, "readNumericDateClaim");
var TRANSACTION_TTL_SECONDS = 600;
var DEFAULT_COOKIE_PREFIX = "__Host-oauth-";
var DEFAULT_REMEMBER_SECONDS = 720 * 60 * 60;
var MIN_SECRET_LENGTH = 32;
var MAX_APPROVALS_COOKIE_BYTES = 3800;
function consentCookies(prefix = DEFAULT_COOKIE_PREFIX) {
  if (typeof prefix !== "string" || !prefix.startsWith("__Host-") || !/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(prefix)) throw new TypeError('cookiePrefix must start with "__Host-" and contain only cookie-name characters');
  return {
    consent: `${prefix}consent`,
    upstream: `${prefix}upstream`,
    approvals: `${prefix}approvals`
  };
}
__name(consentCookies, "consentCookies");
function validateRememberConsentOptions(options) {
  if (typeof options !== "object" || options === null) throw new TypeError("remember must be an object with a secret");
  if (typeof options.secret !== "string" || options.secret.length < MIN_SECRET_LENGTH) throw new TypeError(`remember.secret must be a string of at least ${MIN_SECRET_LENGTH} characters`);
  const maxAge = options.maxAgeSeconds;
  if (maxAge !== void 0 && (!Number.isInteger(maxAge) || maxAge <= 0)) throw new TypeError("remember.maxAgeSeconds must be a positive integer");
  if (options.subject !== void 0 && (typeof options.subject !== "string" || options.subject.length === 0)) throw new TypeError("remember.subject must be a non-empty string");
}
__name(validateRememberConsentOptions, "validateRememberConsentOptions");
function describeConsent(client, request, isClientIdMetadataDocument) {
  const redirectHost = new URL(request.redirectUri).hostname || request.redirectUri;
  return {
    clientId: request.clientId,
    clientName: client?.clientName?.trim() ? client.clientName : request.clientId,
    ...isClientIdMetadataDocument ? { clientDomain: new URL(request.clientId).hostname } : {},
    ...client?.clientUri ? { clientUri: client.clientUri } : {},
    ...client?.logoUri ? { logoUri: client.logoUri } : {},
    redirectUri: request.redirectUri,
    redirectHost,
    redirectIsLoopback: isLoopbackHostname(redirectHost),
    scope: [...request.scope]
  };
}
__name(describeConsent, "describeConsent");
async function beginConsent(kv, cookies, request) {
  const { handle, hash } = await createTransaction(kv, {
    kind: "consent",
    request
  });
  return {
    handle,
    headers: new Headers({
      "Set-Cookie": bindingCookie(transactionCookieName(cookies.consent, hash), hash, TRANSACTION_TTL_SECONDS),
      "Cache-Control": "no-store",
      "Content-Security-Policy": "frame-ancestors 'none'",
      "X-Frame-Options": "DENY"
    })
  };
}
__name(beginConsent, "beginConsent");
async function approveConsent(kv, cookies, supportedScopes, request, handle, options = {}) {
  if (options.remember !== void 0) validateRememberConsentOptions(options.remember);
  const transaction = await openTransaction(kv, request, cookies.consent, handle, "consent");
  let approved = transaction.record.request;
  if (options.scope !== void 0) {
    const supported = supportedScopes ? new Set(supportedScopes) : void 0;
    const valid = /* @__PURE__ */ __name((scope) => typeof scope === "string" && isValidOAuthScopeToken(scope) && (!supported || supported.has(scope)), "valid");
    if (!Array.isArray(options.scope) || !options.scope.every(valid)) throw new AuthorizationError("invalid_scope", { description: "Approved scopes must be ones this server supports" });
    approved = {
      ...approved,
      scope: [...new Set(options.scope)]
    };
  }
  await transaction.consume();
  const headers = new Headers({ "Cache-Control": "no-store" });
  headers.append("Set-Cookie", clearCookie(transaction.cookieName));
  if (options.remember) headers.append("Set-Cookie", await rememberApproval(cookies, request, approved, options.remember));
  return {
    request: approved,
    headers
  };
}
__name(approveConsent, "approveConsent");
async function denyConsent(kv, cookies, request, handle, options = {}) {
  const transaction = await openTransaction(kv, request, cookies.consent, handle, "consent");
  await transaction.consume();
  const record = transaction.record;
  const redirectTo = authorizationErrorRedirect(record.request, "access_denied", options.description);
  const headers = new Headers({
    "Cache-Control": "no-store",
    Location: redirectTo
  });
  headers.append("Set-Cookie", clearCookie(transaction.cookieName));
  return {
    request: record.request,
    redirectTo,
    headers
  };
}
__name(denyConsent, "denyConsent");
async function isConsentRemembered(cookies, request, authRequest, remember) {
  validateRememberConsentOptions(remember);
  const approvals = await readApprovals(cookies, request, remember.secret);
  const key = await approvalKey(authRequest, remember.subject);
  const now = Math.floor(Date.now() / 1e3);
  const approval = approvals.find((entry) => entry.k === key && entry.e > now);
  if (!approval) return false;
  const approvedScopes = new Set(approval.s);
  return authRequest.scope.every((scope) => approvedScopes.has(scope));
}
__name(isConsentRemembered, "isConsentRemembered");
async function beginUpstream(kv, cookies, request, options = {}) {
  const { handle, hash } = await createTransaction(kv, {
    kind: "upstream",
    request,
    data: options.data
  });
  const headers = options.headers ?? new Headers();
  headers.append("Set-Cookie", bindingCookie(transactionCookieName(cookies.upstream, hash), hash, TRANSACTION_TTL_SECONDS));
  headers.set("Cache-Control", "no-store");
  return {
    state: handle,
    headers
  };
}
__name(beginUpstream, "beginUpstream");
async function finishUpstream(kv, cookies, request) {
  const state = new URL(request.url).searchParams.get("state");
  if (!state) throw new AuthorizationError("invalid_request", { description: "Missing state parameter" });
  const transaction = await openTransaction(kv, request, cookies.upstream, state, "upstream");
  await transaction.consume();
  const headers = new Headers({ "Cache-Control": "no-store" });
  headers.append("Set-Cookie", clearCookie(transaction.cookieName));
  return {
    request: transaction.record.request,
    data: transaction.record.data,
    headers
  };
}
__name(finishUpstream, "finishUpstream");
async function createTransaction(kv, record) {
  const handle = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const hash = await sha256Hex(handle);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({
    name: "AES-GCM",
    iv
  }, await transactionKey(handle), new TextEncoder().encode(JSON.stringify(record)));
  await kv.put(`transaction:${hash}`, `${base64url(iv)}.${base64url(new Uint8Array(sealed))}`, { expirationTtl: TRANSACTION_TTL_SECONDS });
  return {
    handle,
    hash
  };
}
__name(createTransaction, "createTransaction");
async function openTransaction(kv, request, cookieBase, handle, kind) {
  if (typeof handle !== "string" || handle.length === 0) throw new AuthorizationError("invalid_request", { description: "Missing transaction handle" });
  const hash = await sha256Hex(handle);
  const cookieName = transactionCookieName(cookieBase, hash);
  const bound = readCookie(request, cookieName);
  if (!bound) throw new AuthorizationError("invalid_request", { description: "This authorization was not started in this browser; start again" });
  if (!timingSafeEqual(hash, bound)) throw new AuthorizationError("invalid_request", { description: "This authorization belongs to a different browser session; start again" });
  const key = `transaction:${hash}`;
  const expired = new AuthorizationError("invalid_request", { description: "This authorization expired or was already used; start again" });
  const stored = await kv.get(key);
  if (!stored) throw expired;
  let record;
  try {
    const [iv, sealed] = stored.split(".");
    const plain = await crypto.subtle.decrypt({
      name: "AES-GCM",
      iv: fromBase64url(iv)
    }, await transactionKey(handle), fromBase64url(sealed));
    record = JSON.parse(new TextDecoder().decode(plain));
  } catch {
    throw expired;
  }
  if (record.kind !== kind) throw expired;
  return {
    record,
    cookieName,
    consume: /* @__PURE__ */ __name(() => kv.delete(key), "consume")
  };
}
__name(openTransaction, "openTransaction");
async function transactionKey(handle) {
  const material = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`oauth-transaction-key:${handle}`));
  return crypto.subtle.importKey("raw", material, "AES-GCM", false, ["encrypt", "decrypt"]);
}
__name(transactionKey, "transactionKey");
function transactionCookieName(base, hash) {
  return `${base}-${hash.slice(0, 16)}`;
}
__name(transactionCookieName, "transactionCookieName");
async function rememberApproval(cookies, request, approved, remember) {
  const maxAge = remember.maxAgeSeconds ?? DEFAULT_REMEMBER_SECONDS;
  const now = Math.floor(Date.now() / 1e3);
  const key = await approvalKey(approved, remember.subject);
  const approvals = (await readApprovals(cookies, request, remember.secret)).filter((entry) => entry.e > now && entry.k !== key);
  approvals.push({
    k: key,
    s: approved.scope,
    e: now + maxAge
  });
  let value = await signApprovals(approvals, remember.secret);
  while (value.length > MAX_APPROVALS_COOKIE_BYTES && approvals.length > 1) {
    approvals.shift();
    value = await signApprovals(approvals, remember.secret);
  }
  const cookieMaxAge = Math.max(...approvals.map((entry) => entry.e)) - now;
  return `${cookies.approvals}=${value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${cookieMaxAge}`;
}
__name(rememberApproval, "rememberApproval");
async function readApprovals(cookies, request, secret) {
  const value = readCookie(request, cookies.approvals);
  if (!value) return [];
  const [payload, signature] = value.split(".");
  if (!payload || !signature) return [];
  const key = await hmacKey(secret);
  let valid = false;
  try {
    valid = await crypto.subtle.verify("HMAC", key, fromBase64url(signature), new TextEncoder().encode(payload));
  } catch {
    return [];
  }
  if (!valid) return [];
  try {
    const parsed = JSON.parse(new TextDecoder().decode(fromBase64url(payload)));
    return Array.isArray(parsed) ? parsed.filter(isApproval) : [];
  } catch {
    return [];
  }
}
__name(readApprovals, "readApprovals");
async function signApprovals(approvals, secret) {
  const payload = base64url(new TextEncoder().encode(JSON.stringify(approvals)));
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret), new TextEncoder().encode(payload));
  return `${payload}.${base64url(new Uint8Array(signature))}`;
}
__name(signApprovals, "signApprovals");
function isApproval(value) {
  if (!value || typeof value !== "object") return false;
  const entry = value;
  return typeof entry.k === "string" && typeof entry.e === "number" && Array.isArray(entry.s) && entry.s.every((scope) => typeof scope === "string");
}
__name(isApproval, "isApproval");
async function approvalKey(request, subject) {
  const material = JSON.stringify([
    request.clientId,
    request.redirectUri,
    request.resource ?? null,
    subject ?? null
  ]);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return base64url(new Uint8Array(digest));
}
__name(approvalKey, "approvalKey");
function hmacKey(secret) {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), {
    name: "HMAC",
    hash: "SHA-256"
  }, false, ["sign", "verify"]);
}
__name(hmacKey, "hmacKey");
function bindingCookie(name, value, maxAge) {
  return `${name}=${value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${maxAge}`;
}
__name(bindingCookie, "bindingCookie");
function clearCookie(name) {
  return `${name}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0`;
}
__name(clearCookie, "clearCookie");
function readCookie(request, name) {
  const header = request.headers.get("Cookie");
  if (!header) return void 0;
  for (const part of header.split(";")) {
    const separator = part.indexOf("=");
    if (separator === -1) continue;
    if (part.slice(0, separator).trim() === name) return part.slice(separator + 1).trim();
  }
}
__name(readCookie, "readCookie");
async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
__name(sha256Hex, "sha256Hex");
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}
__name(timingSafeEqual, "timingSafeEqual");
function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
__name(base64url, "base64url");
function fromBase64url(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64 + "=".repeat((4 - base64.length % 4) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
__name(fromBase64url, "fromBase64url");
var PROTECTED_RESOURCE_WELL_KNOWN_PREFIX = "/.well-known/oauth-protected-resource";
var NO_CACHE_HEADERS = {
  "Cache-Control": "no-store",
  Pragma: "no-cache"
};
var BASIC_AUTH_CHALLENGE = 'Basic realm="OAuth"';
if (!(typeof Cloudflare !== "undefined" && Cloudflare.compatibilityFlags?.global_fetch_strictly_public === true)) console.warn(`CIMD (Client ID Metadata Document) is disabled: add '"compatibility_flags": ["global_fetch_strictly_public"]' to your wrangler.jsonc to enable. See: https://developers.cloudflare.com/workers/configuration/compatibility-flags/#global-fetch-strictly-public`);
var HandlerType = /* @__PURE__ */ (function(HandlerType$1) {
  HandlerType$1[HandlerType$1["EXPORTED_HANDLER"] = 0] = "EXPORTED_HANDLER";
  HandlerType$1[HandlerType$1["WORKER_ENTRYPOINT"] = 1] = "WORKER_ENTRYPOINT";
  return HandlerType$1;
})(HandlerType || {});
var GrantType = /* @__PURE__ */ (function(GrantType$1) {
  GrantType$1["AUTHORIZATION_CODE"] = "authorization_code";
  GrantType$1["REFRESH_TOKEN"] = "refresh_token";
  GrantType$1["TOKEN_EXCHANGE"] = "urn:ietf:params:oauth:grant-type:token-exchange";
  GrantType$1["JWT_BEARER"] = "urn:ietf:params:oauth:grant-type:jwt-bearer";
  return GrantType$1;
})({});
var DEFAULT_AUTHORIZE_PATH = "/authorize";
var DEFAULT_TOKEN_PATH = "/oauth/token";
function toPublicClientInfo(client) {
  const { authMethodExplicit: _explicit, registrationExpiresAt: _expiry, tokenEndpointAuthMethods: _methods, clientAssertionKeys: _keys, ...publicClient } = client;
  return publicClient;
}
__name(toPublicClientInfo, "toPublicClientInfo");
var CLIENT_AUTHENTICATION_PARAMETERS = /* @__PURE__ */ new Set([
  "client_id",
  "client_secret",
  "client_assertion",
  "client_assertion_type"
]);
function isClientAuthMethodAllowed(client, presentedMethod, isClientMetadataDocument) {
  if (presentedMethod === client.tokenEndpointAuthMethod) return true;
  if (isClientMetadataDocument && client.tokenEndpointAuthMethods?.includes(presentedMethod)) return true;
  const isSecretMethod = /* @__PURE__ */ __name((method) => method === "client_secret_basic" || method === "client_secret_post", "isSecretMethod");
  return !isClientMetadataDocument && client.authMethodExplicit === void 0 && isSecretMethod(client.tokenEndpointAuthMethod) && isSecretMethod(presentedMethod);
}
__name(isClientAuthMethodAllowed, "isClientAuthMethodAllowed");
var OAuthProvider = class {
  static {
    __name(this, "OAuthProvider");
  }
  #impl;
  /**
  * Creates a new OAuth provider instance
  * @param options - Configuration options for the provider
  */
  constructor(options) {
    this.#impl = new OAuthProviderImpl(options);
  }
  /**
  * Main fetch handler for the Worker
  * Routes requests to the appropriate handler based on the URL
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @param ctx - Cloudflare Worker execution context
  * @returns A Promise resolving to an HTTP Response
  */
  fetch(request, env, ctx) {
    return this.#impl.fetch(request, env, ctx);
  }
  /**
  * Purges expired and orphaned data from the KV namespace.
  * Can be called directly from a scheduled handler without needing a request context.
  *
  * @param env - Cloudflare Worker environment variables (must include OAUTH_KV binding)
  * @param options - Optional configuration for batch size and which purge types to enable
  * @returns Statistics about what was checked and purged
  */
  purgeExpiredData(env, options) {
    return this.#impl.createOAuthHelpers(env).purgeExpiredData(options);
  }
};
var OAuthProviderImpl = class {
  static {
    __name(this, "OAuthProviderImpl");
  }
  /**
  * Creates a new OAuth provider instance
  * @param options - Configuration options for the provider
  */
  constructor(options) {
    this.errorResponses = /* @__PURE__ */ new WeakSet();
    this.typedApiHandlers = [];
    this.typedDefaultHandler = "authorizationServer" in options ? void 0 : this.validateHandler(options.defaultHandler, "defaultHandler");
    const roleBased = "authorizationServer" in options;
    if (!roleBased && "resourceMatchOriginOnly" in options) throw new TypeError("resourceMatchOriginOnly was removed in 1.0. Configure resourceMetadata.resource; audiences are compared exactly against that canonical resource. See the migration guide.");
    let normalizedOptions;
    let configuredResourceServers;
    if (roleBased) {
      const { authorizationServer: authorizationServer$1, ...commonOptions } = options;
      this.validateAuthorizationServerIssuer(authorizationServer$1.issuer);
      this.explicitIssuer = authorizationServer$1.issuer;
      const issuerBase = authorizationServer$1.issuer.replace(/\/+$/, "");
      normalizedOptions = {
        ...commonOptions,
        authorizeEndpoint: authorizationServer$1.authorizeEndpoint ?? `${issuerBase}${DEFAULT_AUTHORIZE_PATH}`,
        tokenEndpoint: authorizationServer$1.tokenEndpoint ?? `${issuerBase}${DEFAULT_TOKEN_PATH}`,
        clientRegistrationEndpoint: authorizationServer$1.clientRegistrationEndpoint
      };
      const declared = authorizationServer$1.resources;
      if (!Array.isArray(declared) || declared.length === 0 || declared.some((value) => typeof value !== "string")) throw new TypeError("resources must list at least one canonical protected resource identifier");
      const duplicate = declared.find((resource, index) => declared.slice(0, index).some((earlier) => isExactResource(earlier, resource)));
      if (duplicate !== void 0) throw new TypeError(`resources must be unique; duplicate ${duplicate}`);
      configuredResourceServers = declared.map((resource) => ({ resourceMetadata: { resource } }));
    } else {
      this.explicitIssuer = void 0;
      normalizedOptions = options;
      configuredResourceServers = [{
        resourceMetadata: withRequiredScopes(options.resourceMetadata, options.requiredScopes),
        resolveExternalToken: options.resolveExternalToken
      }];
    }
    this.options = {
      accessTokenTTL: DEFAULT_ACCESS_TOKEN_TTL,
      refreshTokenTTL: DEFAULT_REFRESH_TOKEN_TTL,
      clientRegistrationTTL: DEFAULT_CLIENT_REGISTRATION_TTL,
      onError: /* @__PURE__ */ __name(({ status, code, description }) => console.warn(`OAuth error response: ${status} ${code} - ${description}`), "onError"),
      ...normalizedOptions
    };
    this.validateEndpoint(this.options.authorizeEndpoint, "authorizeEndpoint");
    this.validateEndpoint(this.options.tokenEndpoint, "tokenEndpoint");
    this.consentCookies = consentCookies(this.options.cookiePrefix);
    if (this.options.clientRegistrationEndpoint) this.validateEndpoint(this.options.clientRegistrationEndpoint, "clientRegistrationEndpoint");
    if (roleBased) this.validateAuthorizationServerRouteIsolation();
    this.resourceServers = configuredResourceServers.map(({ resourceMetadata, resolveExternalToken }) => {
      const metadata = this.snapshotResourceMetadata(resourceMetadata);
      this.validateResourceMetadataOptions(metadata);
      return {
        resourceMetadata: metadata,
        resolveExternalToken
      };
    });
    for (const [index, server] of this.resourceServers.entries()) if (this.resourceServers.slice(0, index).some((other) => isExactResource(other.resourceMetadata.resource, server.resourceMetadata.resource))) throw new TypeError(`resources must be unique; duplicate ${server.resourceMetadata.resource}`);
    if (!roleBased) {
      const legacyOptions = options;
      const hasSingleHandlerConfig = !!(legacyOptions.apiRoute && legacyOptions.apiHandler);
      const hasMultiHandlerConfig = !!legacyOptions.apiHandlers;
      if (hasSingleHandlerConfig && hasMultiHandlerConfig) throw new TypeError("Cannot use both apiRoute/apiHandler and apiHandlers. Use either apiRoute + apiHandler OR apiHandlers, not both.");
      if (!hasSingleHandlerConfig && !hasMultiHandlerConfig) throw new TypeError("Must provide either apiRoute + apiHandler OR apiHandlers. No API route configuration provided.");
      const resourceServer = this.resourceServers[0];
      if (hasSingleHandlerConfig) {
        const handler = this.validateHandler(legacyOptions.apiHandler, "apiHandler");
        (Array.isArray(legacyOptions.apiRoute) ? legacyOptions.apiRoute : [legacyOptions.apiRoute]).forEach((route, index) => {
          this.validateEndpoint(route, Array.isArray(legacyOptions.apiRoute) ? `apiRoute[${index}]` : "apiRoute");
          this.typedApiHandlers.push({
            route,
            handler,
            resourceServer
          });
        });
      } else for (const [route, rawHandler] of Object.entries(legacyOptions.apiHandlers)) {
        this.validateEndpoint(route, `apiHandlers key: ${route}`);
        const handler = this.validateHandler(rawHandler, `apiHandlers[${route}]`);
        this.typedApiHandlers.push({
          route,
          handler,
          resourceServer
        });
      }
      for (const { route } of this.typedApiHandlers) this.assertRouteCoveredByResource(route, resourceServer.resourceMetadata.resource);
    }
    const resources = this.resourceServers.map((server) => server.resourceMetadata.resource);
    const soleResource = resources.length === 1 ? resources[0] : void 0;
    const authorizationServer = roleBased ? options.authorizationServer : void 0;
    this.configuredDefaultAuthorizationResource = authorizationServer?.defaultResource ?? soleResource;
    this.configuredLegacyGrantResource = authorizationServer?.legacyGrantResource ?? soleResource;
    if (roleBased) {
      this.getDefaultAuthorizationResource();
      this.getLegacyGrantResource();
    }
    if (!isValidAccessTokenTTL(this.options.accessTokenTTL)) throw new TypeError(`accessTokenTTL must be an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds (Cloudflare KV's minimum expiration window).`);
    if (this.options.refreshTokenIdleTTL !== void 0 && !isValidAccessTokenTTL(this.options.refreshTokenIdleTTL)) throw new TypeError(`refreshTokenIdleTTL must be an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds (Cloudflare KV's minimum expiration window).`);
    if (this.options.allowPlainPKCE) throw new TypeError("allowPlainPKCE has been removed: MCP and OAuth 2.1 clients use S256 PKCE.");
    if (this.options.allowImplicitFlow) throw new TypeError("allowImplicitFlow has been removed: OAuth 2.1 and MCP use the authorization code flow with PKCE.");
    if (this.options.refreshTokenTTL !== void 0 && !isValidRefreshTokenTTL(this.options.refreshTokenTTL)) throw new TypeError(`refreshTokenTTL must be 0 (no refresh tokens), undefined (no expiry), or an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds (Cloudflare KV's minimum expiration window).`);
    if (this.options.clientRegistrationTTL !== void 0 && !isValidAccessTokenTTL(this.options.clientRegistrationTTL)) throw new TypeError(`clientRegistrationTTL must be undefined (no expiry) or an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds (Cloudflare KV's minimum expiration window).`);
    this.serverCapabilities = buildOAuthServerCapabilities({
      allowTokenExchangeGrant: !!this.options.allowTokenExchangeGrant,
      enterpriseManagedAuthorization: !!this.options.enterpriseManagedAuthorization,
      allowPrivateUseRedirectUris: this.options.allowPrivateUseRedirectUris === true
    });
    validateAuthorizationServerScopes(this.options.scopesSupported);
    this.validateEmaOptions(this.options.enterpriseManagedAuthorization);
    if (this.options.enterpriseManagedAuthorization) {
      this.jwksProvider = createDefaultJwksProvider({ cacheTtlSeconds: this.options.enterpriseManagedAuthorization.jwksCacheTtlSeconds });
      this.jtiStore = createKvJtiStore();
    }
    if (this.options.clientIdMetadataDocumentEnabled) this.clientAssertionVerifier = createClientAssertionVerifier();
  }
  /**
  * Validates that an endpoint is either an absolute path or a full URL
  * @param endpoint - The endpoint to validate
  * @param name - The name of the endpoint property for error messages
  * @throws TypeError if the endpoint is invalid
  */
  validateEndpoint(endpoint, name) {
    if (this.isPath(endpoint)) {
      if (!endpoint.startsWith("/")) throw new TypeError(`${name} path must be an absolute path starting with /`);
      if (this.explicitIssuer && new URL(endpoint, new URL(this.explicitIssuer).origin).hash) throw new TypeError(`${name} must not contain a fragment`);
    } else {
      let parsed;
      try {
        parsed = new URL(endpoint);
      } catch (e) {
        throw new TypeError(`${name} must be either an absolute path starting with / or a valid URL`);
      }
      if (this.explicitIssuer && (!hasAcceptedCanonicalScheme(parsed) || parsed.username || parsed.password || parsed.hash)) throw new TypeError(`${name} must be an absolute HTTPS URL without userinfo or a fragment (http is accepted only on a loopback host)`);
    }
  }
  /** Validate the explicit issuer used to host-gate the role-based AS. */
  validateAuthorizationServerIssuer(issuer) {
    let parsed;
    try {
      parsed = new URL(issuer);
    } catch {
      throw new TypeError("authorizationServer.issuer must be a canonical absolute HTTPS URL");
    }
    if (!validateResourceUri(issuer) || !hasAcceptedCanonicalScheme(parsed) || parsed.username || parsed.password || parsed.search || parsed.hash || foldResourceSchemeAndHost(issuer) !== issuer || parsed.href !== issuer && parsed.origin !== issuer) throw new TypeError("authorizationServer.issuer must be a canonical absolute HTTPS URL (http is accepted only on a loopback host)");
  }
  /**
  * Reject an endpoint another would claim, so it could never be reached. fetch() tries metadata,
  * then token, then registration; the application routes the authorization endpoint. Each check
  * asks the predicate fetch() dispatches on, so it agrees with routing (metadata ignores the
  * query, for one).
  */
  validateAuthorizationServerRouteIsolation() {
    const issuerUrl = new URL(this.explicitIssuer);
    const tokenUrl = new URL(this.getFullEndpointUrl(this.options.tokenEndpoint, issuerUrl));
    if (this.isAuthorizationServerMetadataRequest(tokenUrl)) throw new TypeError("tokenEndpoint must not collide with the authorization server metadata endpoint");
    const authorizeUrl = new URL(this.getFullEndpointUrl(this.options.authorizeEndpoint, issuerUrl));
    if (this.isAuthorizationServerMetadataRequest(authorizeUrl)) throw new TypeError("authorizeEndpoint must not collide with the authorization server metadata endpoint");
    if (this.isTokenEndpoint(authorizeUrl)) throw new TypeError("authorizeEndpoint must not collide with tokenEndpoint");
    if (!this.options.clientRegistrationEndpoint) return;
    if (this.isClientRegistrationEndpoint(authorizeUrl)) throw new TypeError("authorizeEndpoint must not collide with clientRegistrationEndpoint");
    const registrationUrl = new URL(this.getFullEndpointUrl(this.options.clientRegistrationEndpoint, issuerUrl));
    if (this.isTokenEndpoint(registrationUrl)) throw new TypeError("clientRegistrationEndpoint must not collide with tokenEndpoint");
    if (this.isAuthorizationServerMetadataRequest(registrationUrl)) throw new TypeError("clientRegistrationEndpoint must not collide with the authorization server metadata endpoint");
  }
  /**
  * A protected route must be the canonical resource path or a path-boundary descendant of
  * it. Anything else can never validate a token, because every token is bound to the
  * canonical resource, so it would be a permanently 401 zone.
  */
  assertRouteCoveredByResource(route, resource) {
    const resourceUrl = new URL(resource);
    let routePath;
    if (this.isPath(route)) routePath = route.split("?")[0];
    else {
      const routeUrl = new URL(route);
      if (routeUrl.origin !== resourceUrl.origin) throw new TypeError(`API route ${route} is not covered by resourceMetadata.resource ${resource}. An absolute protected route must be on the resource's origin.`);
      for (const [name, value] of resourceUrl.searchParams) {
        const routeValues = routeUrl.searchParams.getAll(name);
        if (routeValues.length > 0 && !routeValues.includes(value)) throw new TypeError(`API route ${route} is not covered by resourceMetadata.resource ${resource}. An absolute protected route must carry the resource's query parameters.`);
      }
      routePath = routeUrl.pathname;
    }
    if (isPathDescendant(routePath, resourceUrl.pathname)) return;
    throw new TypeError(`API route ${route} is not covered by resourceMetadata.resource ${resource}. Protected routes must be the canonical resource path or a descendant of it; use ${resourceUrl.origin} as the resource to cover every path on that origin.`);
  }
  /** Resolve a configured policy value to the registry's canonical spelling. */
  resolveConfiguredResourceDefault(resource, name) {
    if (resource === void 0) return void 0;
    const configured = this.findConfiguredResource(resource);
    if (!configured) throw new TypeError(`${name} must name one of the configured protected resources`);
    return configured;
  }
  getDefaultAuthorizationResource() {
    const sole = this.resourceServers.length === 1 ? this.resourceServers[0].resourceMetadata.resource : void 0;
    return this.resolveConfiguredResourceDefault(this.configuredDefaultAuthorizationResource ?? sole, "defaultResource");
  }
  getLegacyGrantResource() {
    const sole = this.resourceServers.length === 1 ? this.resourceServers[0].resourceMetadata.resource : void 0;
    return this.resolveConfiguredResourceDefault(this.configuredLegacyGrantResource ?? sole, "legacyGrantResource");
  }
  /**
  * The audience a stored access token is treated as bound to.
  *
  * A token issued before resource binding has no stored audience. It keeps
  * working at the server-selected migration resource (the sole resource, or
  * `legacyGrantResource` in a multi-resource deployment) until it expires;
  * refresh binds its grant and returns a bound replacement. The client never
  * chooses this destination. Without a migration resource the token is
  * treated as unbound and rejected.
  *
  * The destination is deployment policy, not an issuance-time claim: changing
  * `legacyGrantResource` re-targets every surviving unbound token and grant.
  * Keep it fixed for the length of the migration window.
  */
  resolveStoredTokenAudience(audience) {
    return audience === void 0 ? this.getLegacyGrantResource() : audience;
  }
  /**
  * Validates that a handler is either an ExportedHandler or a class extending WorkerEntrypoint
  * @param handler - The handler to validate
  * @param name - The name of the handler property for error messages
  * @returns The type of the handler (EXPORTED_HANDLER or WORKER_ENTRYPOINT)
  * @throws TypeError if the handler is invalid
  */
  validateHandler(handler, name) {
    if (typeof handler === "object" && handler !== null && typeof handler.fetch === "function") return {
      type: HandlerType.EXPORTED_HANDLER,
      handler
    };
    if (typeof handler === "function" && handler.prototype instanceof WorkerEntrypoint) return {
      type: HandlerType.WORKER_ENTRYPOINT,
      handler
    };
    throw new TypeError(`${name} must be either an ExportedHandler object with a fetch method or a class extending WorkerEntrypoint`);
  }
  /** Snapshot caller-owned metadata so later mutation cannot change routing or policy. */
  snapshotResourceMetadata(metadata) {
    return {
      ...metadata,
      ...metadata?.authorization_servers ? { authorization_servers: [...metadata.authorization_servers] } : {},
      ...metadata?.scopes_supported ? { scopes_supported: [...metadata.scopes_supported] } : {},
      ...metadata?.bearer_methods_supported ? { bearer_methods_supported: [...metadata.bearer_methods_supported] } : {}
    };
  }
  /** Validate configured RFC 9728 protected resource metadata. */
  validateResourceMetadataOptions(options) {
    if (!options || !validateResourceUri(options.resource) || !hasAcceptedCanonicalScheme(new URL(options.resource))) throw new TypeError("resourceMetadata.resource is required and must be an absolute HTTPS URI without a fragment (http is accepted only on a loopback host)");
    if (foldResourceSchemeAndHost(options.resource) !== options.resource) throw new TypeError("resourceMetadata.resource must use a lowercase scheme and lowercase host");
    const parsedResource = new URL(options.resource);
    if (parsedResource.username || parsedResource.password || parsedResource.href !== options.resource && parsedResource.origin !== options.resource) throw new TypeError("resourceMetadata.resource must use canonical URL serialization without userinfo, a default port, or dot segments");
    if (parsedResource.pathname === PROTECTED_RESOURCE_WELL_KNOWN_PREFIX || parsedResource.pathname.startsWith(`${PROTECTED_RESOURCE_WELL_KNOWN_PREFIX}/`)) throw new TypeError(`resourceMetadata.resource must not be inside the ${PROTECTED_RESOURCE_WELL_KNOWN_PREFIX} namespace`);
    if (options.authorization_servers !== void 0) {
      if (options.authorization_servers.length === 0) throw new TypeError("resourceMetadata.authorization_servers must contain at least one issuer");
      for (const issuer of options.authorization_servers) {
        let parsed;
        try {
          parsed = new URL(issuer);
        } catch {
          throw new TypeError("resourceMetadata.authorization_servers must contain valid HTTPS issuer URLs");
        }
        if (!validateResourceUri(issuer) || !hasAcceptedCanonicalScheme(parsed) || parsed.username || parsed.password || foldResourceSchemeAndHost(issuer) !== issuer || parsed.href !== issuer && parsed.origin !== issuer || issuer.includes("?") || issuer.includes("#")) throw new TypeError("resourceMetadata.authorization_servers must contain valid HTTPS issuer URLs (http is accepted only on a loopback host)");
      }
    }
    if (options.scopes_supported?.some((scope) => !isValidOAuthScopeToken(scope))) throw new TypeError("requiredScopes (or the deprecated resourceMetadata.scopes_supported) must contain valid OAuth scope tokens");
    if (options.bearer_methods_supported?.some((method) => method !== "header")) throw new TypeError("resourceMetadata.bearer_methods_supported only supports 'header'");
  }
  /**
  * Validates MCP Enterprise-Managed Authorization configuration at construction time.
  *
  * Presence of `enterpriseManagedAuthorization` on options enables the feature —
  * there is no separate `enabled` flag (which would silently disable EMA when
  * forgotten). Configuration is checked structurally; runtime concerns
  * (JWKS reachability etc.) are checked when assertions arrive.
  */
  validateEmaOptions(options) {
    if (!options) return;
    if (typeof options.trustedIssuers !== "function") throw new TypeError("enterpriseManagedAuthorization.trustedIssuers must be a resolver function: (input) => EmaTrustedIssuer | null");
    if (typeof options.mapClaims !== "function") throw new TypeError("enterpriseManagedAuthorization.mapClaims must be a function");
    if (options.jwksCacheTtlSeconds !== void 0 && options.jwksCacheTtlSeconds <= 0) throw new TypeError("enterpriseManagedAuthorization.jwksCacheTtlSeconds must be greater than 0");
    if (options.clockSkewSeconds !== void 0 && options.clockSkewSeconds < 0) throw new TypeError("enterpriseManagedAuthorization.clockSkewSeconds must be non-negative");
    if (options.maxAssertionLifetimeSeconds !== void 0 && options.maxAssertionLifetimeSeconds <= 0) throw new TypeError("enterpriseManagedAuthorization.maxAssertionLifetimeSeconds must be greater than 0");
  }
  /**
  * Main fetch handler for the Worker
  * Routes requests to the appropriate handler based on the URL
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @param ctx - Cloudflare Worker execution context
  * @returns A Promise resolving to an HTTP Response
  */
  async fetch(request, env, ctx) {
    return this.fetchForRoles(request, env, ctx, "combined");
  }
  async fetchAuthorizationServer(request, env, ctx) {
    return this.fetchForRoles(request, env, ctx, "authorization-server");
  }
  async fetchForRoles(request, env, ctx, role) {
    const url = new URL(request.url);
    const servesProtectedResources = role === "combined";
    const metadataResourceServer = servesProtectedResources ? this.findResourceServerForMetadataUrl(url) : void 0;
    const apiRoute = servesProtectedResources ? this.findApiRouteForUrl(url) : void 0;
    if (request.method === "OPTIONS") {
      if (apiRoute !== void 0 || this.isAuthorizationServerMetadataRequest(url) || servesProtectedResources && this.isProtectedResourceMetadataPath(url) || this.isTokenEndpoint(url) || this.options.clientRegistrationEndpoint && this.isClientRegistrationEndpoint(url)) return withCorsHeaders(new Response(null, {
        status: 204,
        headers: { "Content-Length": "0" }
      }), request);
    }
    if (this.isAuthorizationServerMetadataRequest(url)) {
      if (request.method !== "GET" && request.method !== "HEAD") return withCorsHeaders(new Response(null, {
        status: 405,
        headers: { Allow: "GET, HEAD, OPTIONS" }
      }), request);
      return withCorsHeaders(withoutBodyForHead(request, await this.handleMetadataDiscovery(url)), request);
    }
    if (servesProtectedResources && this.isProtectedResourceMetadataPath(url)) {
      if (!metadataResourceServer) return withCorsHeaders(new Response(null, { status: 404 }), request);
      if (request.method !== "GET" && request.method !== "HEAD") return withCorsHeaders(new Response(null, {
        status: 405,
        headers: { Allow: "GET, HEAD, OPTIONS" }
      }), request);
      return withCorsHeaders(withoutBodyForHead(request, this.handleProtectedResourceMetadata(url, metadataResourceServer)), request);
    }
    if (this.isTokenEndpoint(url)) {
      const parsed = await this.parseTokenEndpointRequest(request, env);
      if (parsed instanceof Response) return withCorsHeaders(parsed, request);
      let response;
      if (parsed.isRevocationRequest) response = await this.revokeToken(parsed.body, parsed.clientInfo, env);
      else response = await this.handleTokenRequest(parsed.body, parsed.clientInfo, parsed.clientAuthMethod, env, url, request);
      if (response.ok && !this.errorResponses.has(response)) await this.renewClientRegistrationIfDue(env, parsed.clientInfo, Math.floor(Date.now() / 1e3));
      return withCorsHeaders(response, request);
    }
    if (this.options.clientRegistrationEndpoint && this.isClientRegistrationEndpoint(url)) return withCorsHeaders(await this.handleClientRegistration(request, env), request);
    if (apiRoute) return withCorsHeaders(await this.handleApiRequest(request, env, ctx, apiRoute), request);
    const defaultHandler = this.typedDefaultHandler;
    if (!defaultHandler) return new Response(null, { status: 404 });
    if (!env.OAUTH_PROVIDER) env.OAUTH_PROVIDER = this.createOAuthHelpers(env);
    if (defaultHandler.type === HandlerType.EXPORTED_HANDLER) return defaultHandler.handler.fetch(request, env, ctx);
    return new defaultHandler.handler(ctx, env).fetch(request);
  }
  /**
  * Decodes a token and returns token data with decrypted props
  * @param token - The granted token
  * @param env - Cloudflare Worker environment variables
  * @returns Promise resolving to token data with decrypted props, or null if token is invalid
  */
  async unwrapToken(token, env) {
    const parts = token.split(":");
    if (!(parts.length === 3)) return null;
    const [userId, grantId] = parts;
    const id = await generateTokenId(token);
    const tokenData = await env.OAUTH_KV.get(`token:${userId}:${grantId}:${id}`, { type: "json" });
    if (!tokenData) return null;
    const now = Math.floor(Date.now() / 1e3);
    if (tokenData.expiresAt < now) return null;
    const decryptedProps = await decryptProps(await unwrapKeyWithToken(token, tokenData.wrappedEncryptionKey), tokenData.grant.encryptedProps);
    const { grant } = tokenData;
    return {
      id: tokenData.id,
      grantId: tokenData.grantId,
      userId: tokenData.userId,
      createdAt: tokenData.createdAt,
      expiresAt: tokenData.expiresAt,
      audience: tokenData.audience,
      scope: tokenData.scope || grant.scope,
      grant: {
        clientId: grant.clientId,
        scope: grant.scope,
        props: decryptedProps
      }
    };
  }
  async validateAccessToken(token, resource, env) {
    const configuredResource = this.findConfiguredResource(resource);
    if (!configuredResource) throw new TypeError("resource must name one registered protected resource");
    const summary = await this.unwrapToken(token, env);
    if (!summary || !isExactResource(this.resolveStoredTokenAudience(summary.audience), configuredResource)) return null;
    return {
      props: summary.grant.props,
      audience: configuredResource,
      expiresAt: summary.expiresAt,
      scope: summary.scope,
      userId: summary.userId,
      clientId: summary.grant.clientId
    };
  }
  /**
  * Determines if an endpoint configuration is a path or a full URL
  * @param endpoint - The endpoint configuration
  * @returns True if the endpoint is a path (starts with /), false if it's a full URL
  */
  isPath(endpoint) {
    return endpoint.startsWith("/");
  }
  /**
  * Matches a URL against an endpoint pattern that can be a full URL or just a path
  * @param url - The URL to check
  * @param endpoint - The endpoint pattern (full URL or path)
  * @returns True if the URL matches the endpoint pattern
  */
  matchEndpoint(url, endpoint, allowAdditionalQuery = false) {
    if (!this.explicitIssuer) {
      if (this.isPath(endpoint)) return url.pathname === endpoint;
      const legacyEndpoint = new URL(endpoint);
      return url.hostname === legacyEndpoint.hostname && url.pathname === legacyEndpoint.pathname;
    }
    const endpointUrl = new URL(this.getFullEndpointUrl(endpoint, url));
    if (url.origin !== endpointUrl.origin || url.pathname !== endpointUrl.pathname) return false;
    const unmatchedActualQuery = [...url.searchParams.entries()];
    const configuredQueryNames = /* @__PURE__ */ new Set();
    for (const [name, value] of endpointUrl.searchParams) {
      configuredQueryNames.add(name);
      const match = unmatchedActualQuery.findIndex(([actualName, actualValue]) => {
        return actualName === name && actualValue === value;
      });
      if (match === -1) return false;
      unmatchedActualQuery.splice(match, 1);
    }
    if (!allowAdditionalQuery) return unmatchedActualQuery.length === 0;
    return unmatchedActualQuery.every(([name]) => !configuredQueryNames.has(name));
  }
  /**
  * Checks if a URL matches the configured token endpoint
  * @param url - The URL to check
  * @returns True if the URL matches the token endpoint
  */
  isTokenEndpoint(url) {
    return this.matchEndpoint(url, this.options.tokenEndpoint, true);
  }
  isAuthorizationEndpointRequest(url) {
    return this.matchEndpoint(url, this.options.authorizeEndpoint, true);
  }
  /**
  * Checks if a URL matches the configured client registration endpoint
  * @param url - The URL to check
  * @returns True if the URL matches the client registration endpoint
  */
  isClientRegistrationEndpoint(url) {
    if (!this.options.clientRegistrationEndpoint) return false;
    return this.matchEndpoint(url, this.options.clientRegistrationEndpoint, true);
  }
  /**
  * Checks if a URL is a request for OAuth Protected Resource Metadata (RFC 9728).
  * Only the well-known URL constructed from the configured canonical resource
  * may return its document; aliases would violate RFC 9728 §3.3.
  */
  findResourceServerForMetadataUrl(url) {
    return this.resourceServers.find((server) => {
      const expected = new URL(this.getConfiguredResourceMetadataUrl(server.resourceMetadata.resource));
      return url.origin === expected.origin && url.pathname === expected.pathname && requestCarriesResourceQuery(url, expected);
    });
  }
  /** Exact RFC 8414 discovery location for the configured issuer. */
  getAuthorizationServerMetadataUrl(requestUrl) {
    if (!this.explicitIssuer) return `${requestUrl.origin}/.well-known/oauth-authorization-server`;
    const issuer = new URL(this.explicitIssuer);
    const issuerPath = issuer.pathname === "/" ? "" : issuer.pathname.replace(/\/+$/, "");
    return `${issuer.origin}/.well-known/oauth-authorization-server${issuerPath}`;
  }
  isAuthorizationServerMetadataRequest(url) {
    const expected = new URL(this.getAuthorizationServerMetadataUrl(url));
    return url.origin === expected.origin && url.pathname === expected.pathname;
  }
  /** Whether this instance is the role-based authorization server with a fixed issuer. */
  get hasExplicitIssuer() {
    return this.explicitIssuer !== void 0;
  }
  /** Whether a URL is in the RFC 9728 protected-resource metadata namespace. */
  isProtectedResourceMetadataPath(url) {
    return url.pathname === PROTECTED_RESOURCE_WELL_KNOWN_PREFIX || url.pathname.startsWith(PROTECTED_RESOURCE_WELL_KNOWN_PREFIX + "/");
  }
  createInvalidClientResponse(description, basicAuthenticationAttempted, internal, request) {
    return this.createErrorResponse("invalid_client", {
      description,
      statusCode: 401,
      ...basicAuthenticationAttempted ? { headers: { "WWW-Authenticate": BASIC_AUTH_CHALLENGE } } : {}
    }, internal, request);
  }
  /**
  * Parses and validates a token endpoint request (used for both token exchange and revocation)
  * @param request - The HTTP request to parse
  * @returns Promise with parsed body and client info, or error response
  */
  async parseTokenEndpointRequest(request, env) {
    if (request.method !== "POST") return this.createErrorResponse("invalid_request", {
      description: "Method not allowed",
      statusCode: 405,
      headers: { Allow: "POST, OPTIONS" }
    }, {
      category: "token-endpoint-request",
      reason: "method_not_allowed"
    });
    const contentType = request.headers.get("Content-Type") || "";
    let body = {};
    if (contentType.split(";")[0].trim().toLowerCase() !== "application/x-www-form-urlencoded") return this.createErrorResponse("invalid_request", {
      description: "Content-Type must be application/x-www-form-urlencoded",
      statusCode: 400
    }, {
      category: "token-endpoint-request",
      reason: "unsupported_content_type"
    });
    let formData;
    try {
      formData = await request.formData();
    } catch {
      return this.createErrorResponse("invalid_request", {
        description: "Request body must be valid application/x-www-form-urlencoded data",
        statusCode: 400
      }, {
        category: "token-endpoint-request",
        reason: "malformed_request_body"
      });
    }
    const processedKeys = /* @__PURE__ */ new Set();
    for (const key of formData.keys()) {
      if (processedKeys.has(key)) continue;
      processedKeys.add(key);
      const allValues = CLIENT_AUTHENTICATION_PARAMETERS.has(key) ? formData.getAll(key).filter((entry) => entry !== "") : formData.getAll(key);
      if (allValues.length === 0) continue;
      if (key !== "resource" && allValues.length > 1) return this.createErrorResponse("invalid_request", {
        description: `Request parameter "${key}" must not be repeated`,
        statusCode: 400
      }, {
        category: "token-endpoint-request",
        reason: "repeated_parameter",
        detail: { parameter: key }
      });
      body[key] = allValues.length > 1 ? allValues : allValues[0];
    }
    const basicAuthorization = parseBasicAuthorizationHeader(request.headers.get("Authorization"));
    const basicAuthenticationAttempted = basicAuthorization.kind !== "not-basic";
    const sent = /* @__PURE__ */ __name((name) => body[name] !== void 0, "sent");
    const clientAssertionAttempted = sent("client_assertion") || sent("client_assertion_type");
    let clientId = "";
    let clientSecret = "";
    if (basicAuthenticationAttempted) {
      if (sent("client_id") || sent("client_secret") || clientAssertionAttempted) return this.createErrorResponse("invalid_request", {
        description: "Client must not use multiple authentication methods",
        statusCode: 400
      }, {
        category: "client-authentication",
        reason: "multiple_authentication_methods"
      });
      if (basicAuthorization.kind === "malformed") return this.createInvalidClientResponse("Client authentication failed: invalid Basic credentials", basicAuthenticationAttempted, {
        category: "client-authentication",
        reason: "malformed_basic_credentials"
      });
      clientId = basicAuthorization.clientId;
      clientSecret = basicAuthorization.clientSecret;
    } else if (clientAssertionAttempted) {
      if (sent("client_secret")) return this.createErrorResponse("invalid_request", {
        description: "Client must not use multiple authentication methods",
        statusCode: 400
      }, {
        category: "client-authentication",
        reason: "multiple_authentication_methods"
      });
      if (!sent("client_assertion") || !sent("client_assertion_type")) return this.createErrorResponse("invalid_request", {
        description: "client_assertion and client_assertion_type must be sent together",
        statusCode: 400
      }, {
        category: "client-authentication",
        reason: "client_assertion_incomplete"
      });
      clientId = body.client_id || readClientAssertionIssuer(body.client_assertion) || "";
    } else {
      clientId = body.client_id;
      clientSecret = body.client_secret || "";
    }
    if (!clientId) return this.createInvalidClientResponse("Client ID is required", basicAuthenticationAttempted, {
      category: "client-authentication",
      reason: "client_id_missing"
    });
    let clientInfo;
    try {
      clientInfo = await this.getClient(env, clientId);
    } catch (error) {
      if (error instanceof CimdFetchError) return this.createInvalidClientResponse("Client not found", basicAuthenticationAttempted, {
        category: "client-id-metadata-document",
        reason: error.reason,
        detail: {
          metadataUrl: error.metadataUrl,
          message: error.detail
        }
      }, request);
      throw error;
    }
    if (!clientInfo) return this.createInvalidClientResponse("Client not found", basicAuthenticationAttempted, {
      category: "client-authentication",
      reason: "client_not_found"
    });
    const presentedAuthMethod = basicAuthenticationAttempted ? "client_secret_basic" : clientAssertionAttempted ? "private_key_jwt" : sent("client_secret") ? "client_secret_post" : "none";
    const registeredAuthMethod = clientInfo.tokenEndpointAuthMethod;
    if (!isClientAuthMethodAllowed(clientInfo, presentedAuthMethod, !!this.options.clientIdMetadataDocumentEnabled && isClientIdMetadataDocumentUrl(clientInfo.clientId))) return this.createInvalidClientResponse("Client authentication failed", basicAuthenticationAttempted, {
      category: "client-authentication",
      reason: "token_endpoint_auth_method_mismatch",
      detail: {
        clientId: clientInfo.clientId,
        registeredMethod: registeredAuthMethod,
        presentedMethod: presentedAuthMethod
      }
    });
    if (presentedAuthMethod === "private_key_jwt") {
      const failure = await this.verifyClientAssertion(body, clientInfo, env, request);
      if (failure) return failure;
    } else if (presentedAuthMethod !== "none") {
      if (!clientSecret) return this.createInvalidClientResponse("Client authentication failed: missing client_secret", basicAuthenticationAttempted, {
        category: "client-authentication",
        reason: "client_secret_missing"
      });
      if (!clientInfo.clientSecret) return this.createInvalidClientResponse("Client authentication failed: client has no registered secret", basicAuthenticationAttempted, {
        category: "client-authentication",
        reason: "client_secret_not_registered"
      });
      if (await hashSecret(clientSecret) !== clientInfo.clientSecret) return this.createInvalidClientResponse("Client authentication failed: invalid client_secret", basicAuthenticationAttempted, {
        category: "client-authentication",
        reason: "client_secret_mismatch"
      });
    }
    const isRevocationRequest = !body.grant_type && !!body.token;
    return {
      body,
      clientInfo,
      clientAuthMethod: presentedAuthMethod,
      isRevocationRequest
    };
  }
  /**
  * Authenticates a `private_key_jwt` request (RFC 7523 §2.2). The method check has already
  * confirmed that the client registered the method, which only a CIMD client with usable keys can.
  * @returns An `invalid_client` response, or `undefined` once the assertion verified and was consumed
  */
  async verifyClientAssertion(body, clientInfo, env, request) {
    const keys = clientInfo.clientAssertionKeys;
    const verifier = this.clientAssertionVerifier;
    if (!keys || !verifier) throw new Error("private_key_jwt client resolved without keys or a verifier");
    if (body.client_assertion_type !== JWT_BEARER_CLIENT_ASSERTION_TYPE) return this.createInvalidClientResponse("Client authentication failed", false, {
      category: "client-authentication",
      reason: "client_assertion_type_unsupported",
      detail: {
        clientId: clientInfo.clientId,
        clientAssertionType: String(body.client_assertion_type)
      }
    });
    const requestUrl = new URL(request.url);
    const verified = await verifier.verify({
      assertion: body.client_assertion,
      clientId: clientInfo.clientId,
      keys,
      issuer: this.getAuthorizationServerIssuer(requestUrl),
      tokenEndpoint: this.getFullEndpointUrl(this.options.tokenEndpoint, requestUrl),
      env
    });
    if (verified.ok) return void 0;
    return this.createInvalidClientResponse("Client authentication failed", false, {
      category: "client-authentication",
      reason: "client_assertion_invalid",
      detail: {
        clientId: clientInfo.clientId,
        ...verified.error
      }
    }, request);
  }
  /**
  * Checks if a URL matches a specific API route
  * @param url - The URL to check
  * @param route - The API route to check against
  * @returns True if the URL matches the API route
  */
  matchApiRoute(url, route) {
    const pathMatches = /* @__PURE__ */ __name((configuredPath, rootMatchesDescendants) => {
      if (configuredPath === "/") return rootMatchesDescendants || url.pathname === "/";
      const normalized = configuredPath.endsWith("/") ? configuredPath.slice(0, -1) : configuredPath;
      return url.pathname === normalized || url.pathname.startsWith(normalized + "/");
    }, "pathMatches");
    if (this.isPath(route)) return pathMatches(route, false);
    else {
      const apiUrl = new URL(route);
      return url.origin === apiUrl.origin && pathMatches(apiUrl.pathname, true) && requestCarriesResourceQuery(url, apiUrl);
    }
  }
  /**
  * Finds the appropriate API handler for a URL
  * @param url - The URL to find a handler for
  * @returns The TypedHandler for the URL, or undefined if no handler matches
  */
  findApiRouteForUrl(url) {
    return this.typedApiHandlers.filter(({ route }) => this.matchApiRoute(url, route)).sort((left, right) => new URL(right.route, url.origin).pathname.length - new URL(left.route, url.origin).pathname.length)[0];
  }
  /**
  * Gets the full URL for an endpoint, using the provided request URL's
  * origin for endpoints specified as just paths
  * @param endpoint - The endpoint configuration (path or full URL)
  * @param requestUrl - The URL of the incoming request
  * @returns The full URL for the endpoint
  */
  getFullEndpointUrl(endpoint, requestUrl) {
    if (this.isPath(endpoint)) return `${this.explicitIssuer ? new URL(this.explicitIssuer).origin : requestUrl.origin}${endpoint}`;
    else return endpoint;
  }
  /**
  * Gets the authorization server issuer using the same derivation as RFC 8414 metadata.
  */
  getAuthorizationServerIssuer(requestUrl) {
    if (this.explicitIssuer) return this.explicitIssuer;
    const tokenEndpoint = this.getFullEndpointUrl(this.options.tokenEndpoint, requestUrl);
    return new URL(tokenEndpoint).origin;
  }
  /**
  * Handles the OAuth metadata discovery endpoint
  * Implements RFC 8414 for OAuth Server Metadata
  * @param requestUrl - The URL of the incoming request
  * @returns Response with OAuth server metadata
  */
  async handleMetadataDiscovery(requestUrl) {
    const tokenEndpoint = this.getFullEndpointUrl(this.options.tokenEndpoint, requestUrl);
    const authorizeEndpoint = this.getFullEndpointUrl(this.options.authorizeEndpoint, requestUrl);
    let registrationEndpoint = void 0;
    if (this.options.clientRegistrationEndpoint) registrationEndpoint = this.getFullEndpointUrl(this.options.clientRegistrationEndpoint, requestUrl);
    const responseTypesSupported = this.serverCapabilities.responseTypes;
    const grantTypesSupported = this.serverCapabilities.grantTypes;
    const authorizationGrantProfilesSupported = this.options.enterpriseManagedAuthorization ? [EMA_ID_JAG_GRANT_PROFILE] : [];
    const cimdSupported = !!this.options.clientIdMetadataDocumentEnabled && this.hasGlobalFetchStrictlyPublic();
    const metadata = {
      issuer: this.getAuthorizationServerIssuer(requestUrl),
      authorization_endpoint: authorizeEndpoint,
      token_endpoint: tokenEndpoint,
      ...this.resourceServers.length > 0 ? { protected_resources: this.resourceServers.map((server) => server.resourceMetadata.resource) } : {},
      registration_endpoint: registrationEndpoint,
      scopes_supported: this.options.scopesSupported,
      response_types_supported: responseTypesSupported,
      response_modes_supported: ["query"],
      grant_types_supported: grantTypesSupported,
      ...authorizationGrantProfilesSupported.length > 0 ? { authorization_grant_profiles_supported: authorizationGrantProfilesSupported } : {},
      token_endpoint_auth_methods_supported: [...this.serverCapabilities.tokenEndpointAuthMethods, ...cimdSupported ? ["private_key_jwt"] : []],
      ...cimdSupported ? { token_endpoint_auth_signing_alg_values_supported: [...CLIENT_ASSERTION_ALGORITHMS] } : {},
      revocation_endpoint: tokenEndpoint,
      code_challenge_methods_supported: this.serverCapabilities.codeChallengeMethods,
      authorization_response_iss_parameter_supported: true,
      client_id_metadata_document_supported: cimdSupported
    };
    return new Response(JSON.stringify(metadata), { headers: { "Content-Type": "application/json" } });
  }
  /** Scopes that are baseline requirements of the protected resource itself. */
  getProtectedResourceScopes(resourceServer) {
    return this.normalizeProtectedResourceScopes(resourceServer.resourceMetadata.scopes_supported ?? []);
  }
  /** Deduplicate resource-facing scopes and remove authorization-server-only capabilities. */
  normalizeProtectedResourceScopes(scopes) {
    return baselineResourceScopes(scopes);
  }
  /**
  * Handles the OAuth Protected Resource Metadata endpoint
  * Implements RFC 9728 for OAuth Protected Resource Metadata
  * @param requestUrl - The URL of the incoming request
  * @returns Response with protected resource metadata
  */
  handleProtectedResourceMetadata(requestUrl, resourceServer) {
    const rm = resourceServer.resourceMetadata;
    const authorizationServer = this.getAuthorizationServerIssuer(requestUrl);
    const resourceScopes = this.getProtectedResourceScopes(resourceServer);
    const metadata = {
      resource: rm.resource,
      authorization_servers: rm.authorization_servers ?? [authorizationServer],
      ...resourceScopes.length > 0 ? { scopes_supported: resourceScopes } : {},
      bearer_methods_supported: rm.bearer_methods_supported ?? ["header"]
    };
    if (rm.resource_name) metadata.resource_name = rm.resource_name;
    return new Response(JSON.stringify(metadata), { headers: { "Content-Type": "application/json" } });
  }
  /**
  * Handles client authentication and token issuance via the token endpoint
  * Supports authorization_code and refresh_token grant types
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with token data or error
  */
  async handleTokenRequest(body, clientInfo, clientAuthMethod, env, requestUrl, request) {
    try {
      const grantType = body.grant_type;
      if (!(grantType === GrantType.AUTHORIZATION_CODE || grantType === GrantType.REFRESH_TOKEN || grantType === GrantType.TOKEN_EXCHANGE && !!this.options.allowTokenExchangeGrant || grantType === GrantType.JWT_BEARER && !!this.options.enterpriseManagedAuthorization)) return this.createErrorResponse("unsupported_grant_type", { description: "Grant type not supported" }, {
        category: "token-endpoint-request",
        reason: "grant_type_not_supported"
      });
      if (grantType !== GrantType.JWT_BEARER && Array.isArray(clientInfo.grantTypes)) {
        const registered = clientInfo.grantTypes;
        if (!(registered.includes(grantType) || grantType === GrantType.REFRESH_TOKEN && registered.includes(GrantType.AUTHORIZATION_CODE))) return this.createErrorResponse("unauthorized_client", { description: "The client is not registered for this grant type" }, {
          category: "token-endpoint-request",
          reason: "grant_type_not_registered"
        });
      }
      if (grantType !== GrantType.REFRESH_TOKEN) this.validateTokenRequestResourceIndicator(body.resource);
      if (grantType === GrantType.AUTHORIZATION_CODE) return await this.handleAuthorizationCodeGrant(body, clientInfo, env);
      else if (grantType === GrantType.REFRESH_TOKEN) return await this.handleRefreshTokenGrant(body, clientInfo, env);
      else if (grantType === GrantType.TOKEN_EXCHANGE && this.options.allowTokenExchangeGrant) return await this.handleTokenExchangeGrant(body, clientInfo, env);
      else if (grantType === GrantType.JWT_BEARER) return await this.handleJwtBearerGrant(body, clientInfo, clientAuthMethod, env, requestUrl, request);
      throw new Error("Unreachable supported grant type");
    } catch (error) {
      const response = this.createOAuthErrorResponse(error);
      if (response) return response;
      throw error;
    }
  }
  /**
  * Build a structured OAuth token-endpoint response from an OAuth error.
  *
  * The supported form is throwing this package's exported `OAuthError` from
  * token issuance or `tokenExchangeCallback`. Anything else is re-thrown so
  * unexpected failures still surface as 500s.
  */
  /**
  * Run `tokenExchangeCallback`. An `invalid_grant` it throws means the grant can never work again
  * (RFC 6749 §5.2: invalid, expired, or revoked; transient failures are `temporarily_unavailable`),
  * so the grant it ran for is revoked, with its tokens, before the error answers. A failed
  * revocation is logged and the callback's error still answers the request.
  */
  async callTokenExchangeCallback(options, env) {
    try {
      return await Promise.resolve(this.options.tokenExchangeCallback({
        ...options,
        env
      }));
    } catch (error) {
      if (error instanceof OAuthError && error.code === "invalid_grant") try {
        await this.createOAuthHelpers(env).revokeGrant(options.grantId, options.userId);
      } catch (revokeError) {
        console.warn(`Failed to revoke grant ${options.grantId} after tokenExchangeCallback answered invalid_grant:`, revokeError);
      }
      throw error;
    }
  }
  createOAuthErrorResponse(error) {
    if (!(error instanceof OAuthError)) return void 0;
    return this.createErrorResponse(error.code, error.options, error.options.internal ?? {
      category: "token-exchange-callback",
      reason: "callback_error",
      detail: error
    });
  }
  /**
  * Build a structured protected-resource response from an external-token error.
  *
  * Only this package's exported `ExternalTokenError` is converted. Standard
  * bearer failures receive an RFC 6750 / RFC 9728 challenge unless the caller
  * supplied one. Other errors retain the pre-existing behavior and are re-thrown.
  */
  createExternalTokenErrorResponse(error, resourceMetadataUrl, resourceServer) {
    if (!(error instanceof ExternalTokenError)) return void 0;
    const headers = error.headers ?? {};
    const hasChallenge = Object.keys(headers).some((name) => name.toLowerCase() === "www-authenticate");
    const isBearerError = error.code === "invalid_token" && error.statusCode === 401 || error.code === "insufficient_scope" && error.statusCode === 403;
    let challengeHeaders;
    if (isBearerError && !hasChallenge) {
      const requiredScopes = [...new Set(error.requiredScopes ?? [])];
      if (requiredScopes.some((scope) => !isValidOAuthScopeToken(scope))) throw new TypeError("ExternalTokenError requiredScopes must contain valid OAuth scope tokens");
      challengeHeaders = {
        ...headers,
        "WWW-Authenticate": this.buildWwwAuthenticateHeader(resourceMetadataUrl, error.code, void 0, requiredScopes, resourceServer)
      };
    }
    return this.createErrorResponse(error.code, {
      description: error.description,
      statusCode: error.statusCode,
      headers: challengeHeaders ?? headers
    }, {
      category: "protected-resource",
      reason: "resolver_rejected",
      detail: error
    });
  }
  /**
  * Handles the authorization code grant type
  * Exchanges an authorization code for access and refresh tokens
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with token data or error
  */
  async handleAuthorizationCodeGrant(body, clientInfo, env) {
    const code = body.code;
    const redirectUri = body.redirect_uri;
    const codeVerifier = body.code_verifier;
    if (!code) return this.createErrorResponse("invalid_request", { description: "Authorization code is required" }, {
      category: "authorization-code-grant",
      reason: "code_missing"
    });
    const codeParts = code.split(":");
    if (codeParts.length !== 3) return this.createErrorResponse("invalid_grant", { description: "Invalid authorization code format" }, {
      category: "authorization-code-grant",
      reason: "code_malformed"
    });
    const [userId, grantId, _] = codeParts;
    const grantKey = `grant:${userId}:${grantId}`;
    const grantData = await env.OAUTH_KV.get(grantKey, { type: "json" });
    if (!grantData) return this.createErrorResponse("invalid_grant", { description: "Grant not found or authorization code expired" }, {
      category: "authorization-code-grant",
      reason: "grant_not_found"
    });
    const codeHash = await hashSecret(code);
    if (!grantData.authCodeId || codeHash !== grantData.authCodeId) return this.createErrorResponse("invalid_grant", { description: "Invalid authorization code" }, {
      category: "authorization-code-grant",
      reason: "code_mismatch"
    });
    if (grantData.clientId !== clientInfo.clientId) return this.createErrorResponse("invalid_grant", { description: "Client ID mismatch" }, {
      category: "authorization-code-grant",
      reason: "client_mismatch"
    });
    if (!grantData.authCodeWrappedKey) {
      try {
        await this.createOAuthHelpers(env).revokeGrant(grantId, userId);
      } catch {
      }
      return this.createErrorResponse("invalid_grant", { description: "Authorization code already used" }, {
        category: "authorization-code-grant",
        reason: "code_replayed"
      });
    }
    try {
      if (grantData.codeChallenge) validatePkceCodeChallengeMethod(this.serverCapabilities, grantData.codeChallengeMethod);
      else normalizePkceCodeChallengeMethod(grantData.codeChallengeMethod);
    } catch (error) {
      return this.createErrorResponse("invalid_grant", { description: error instanceof Error ? error.message : "Invalid PKCE code_challenge_method" }, {
        category: "authorization-code-grant",
        reason: "pkce_method_invalid",
        detail: error
      });
    }
    const isPkceEnabled = !!grantData.codeChallenge;
    if (!redirectUri && !isPkceEnabled) return this.createErrorResponse("invalid_request", { description: "redirect_uri is required when not using PKCE" }, {
      category: "authorization-code-grant",
      reason: "redirect_uri_missing"
    });
    if (redirectUri && !isValidRedirectUri(redirectUri, clientInfo.redirectUris)) return this.createErrorResponse("invalid_grant", { description: "Invalid redirect URI" }, {
      category: "authorization-code-grant",
      reason: "redirect_uri_invalid"
    });
    if (redirectUri && grantData.redirectUri !== void 0 && redirectUri !== grantData.redirectUri) return this.createErrorResponse("invalid_grant", { description: "redirect_uri does not match the authorization request" }, {
      category: "authorization-code-grant",
      reason: "redirect_uri_mismatch"
    });
    if (!isPkceEnabled && codeVerifier) return this.createErrorResponse("invalid_request", { description: "code_verifier provided for a flow that did not use PKCE" }, {
      category: "authorization-code-grant",
      reason: "unexpected_code_verifier"
    });
    if (isPkceEnabled) {
      if (!codeVerifier) return this.createErrorResponse("invalid_request", { description: "code_verifier is required for PKCE" }, {
        category: "authorization-code-grant",
        reason: "code_verifier_missing"
      });
      const hashBuffer = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(codeVerifier));
      if (base64UrlEncode(String.fromCharCode(...new Uint8Array(hashBuffer))) !== grantData.codeChallenge) return this.createErrorResponse("invalid_grant", { description: "Invalid PKCE code_verifier" }, {
        category: "authorization-code-grant",
        reason: "code_verifier_mismatch"
      });
    }
    const resourceResolution = this.resolveTokenResource(body.resource, grantData);
    const audience = resourceResolution.audience;
    let accessTokenTTL = this.options.accessTokenTTL;
    let refreshTokenTTL = this.options.refreshTokenTTL;
    const encryptionKey = await unwrapKeyWithToken(code, grantData.authCodeWrappedKey);
    let grantEncryptionKey = encryptionKey;
    let accessTokenEncryptionKey = encryptionKey;
    let encryptedAccessTokenProps = grantData.encryptedProps;
    let tokenScopes = this.downscope(body.scope, grantData.scope);
    if (grantsNoneOfTheRequestedScopes(body.scope, tokenScopes)) return this.createErrorResponse("invalid_scope", { description: "None of the requested scopes were granted" }, {
      category: "authorization-code-grant",
      reason: "scope_not_granted"
    });
    if (this.options.tokenExchangeCallback) {
      const decryptedProps = await decryptProps(encryptionKey, grantData.encryptedProps);
      let grantProps = decryptedProps;
      let accessTokenProps = decryptedProps;
      const callbackOptions = {
        grantType: GrantType.AUTHORIZATION_CODE,
        clientId: clientInfo.clientId,
        subjectClientId: grantData.clientId,
        userId,
        grantId,
        scope: grantData.scope,
        requestedScope: tokenScopes,
        resource: audience,
        props: decryptedProps
      };
      const callbackResult = await this.callTokenExchangeCallback(callbackOptions, env);
      if (callbackResult) {
        if (callbackResult.newProps) {
          grantProps = callbackResult.newProps;
          if (!callbackResult.accessTokenProps) accessTokenProps = callbackResult.newProps;
        }
        if (callbackResult.accessTokenProps) accessTokenProps = callbackResult.accessTokenProps;
        if (callbackResult.accessTokenTTL !== void 0) accessTokenTTL = callbackResult.accessTokenTTL;
        if (callbackResult.refreshTokenTTL !== void 0) {
          if (!isValidRefreshTokenTTL(callbackResult.refreshTokenTTL)) return this.createErrorResponse("invalid_request", { description: `refreshTokenTTL must be 0 (no refresh token) or an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds` }, {
            category: "authorization-code-grant",
            reason: "refresh_token_ttl_invalid"
          });
          refreshTokenTTL = callbackResult.refreshTokenTTL;
        }
        if (callbackResult.accessTokenScope) tokenScopes = this.downscope(callbackResult.accessTokenScope, grantData.scope);
      }
      const grantResult = await encryptProps(grantProps);
      grantData.encryptedProps = grantResult.encryptedData;
      grantEncryptionKey = grantResult.key;
      if (accessTokenProps !== grantProps) {
        const tokenResult = await encryptProps(accessTokenProps);
        encryptedAccessTokenProps = tokenResult.encryptedData;
        accessTokenEncryptionKey = tokenResult.key;
      } else {
        encryptedAccessTokenProps = grantData.encryptedProps;
        accessTokenEncryptionKey = grantEncryptionKey;
      }
    }
    if (!isValidAccessTokenTTL(accessTokenTTL)) return this.createErrorResponse("invalid_request", { description: "Requested token lifetime must be at least 60 seconds" }, {
      category: "authorization-code-grant",
      reason: "requested_ttl_too_short"
    });
    const now = Math.floor(Date.now() / 1e3);
    const useRefreshToken = refreshTokenTTL !== 0;
    delete grantData.codeChallenge;
    delete grantData.codeChallengeMethod;
    delete grantData.authCodeWrappedKey;
    let refreshToken;
    if (useRefreshToken) {
      refreshToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
      const refreshTokenId = await generateTokenId(refreshToken);
      const refreshTokenWrappedKey = await wrapKeyWithToken(refreshToken, grantEncryptionKey);
      const expiresAt = refreshTokenTTL !== void 0 ? now + refreshTokenTTL : void 0;
      grantData.refreshTokenId = refreshTokenId;
      grantData.refreshTokenWrappedKey = refreshTokenWrappedKey;
      grantData.previousRefreshTokenId = void 0;
      grantData.previousRefreshTokenWrappedKey = void 0;
      grantData.expiresAt = expiresAt;
    } else grantData.expiresAt = now + accessTokenTTL;
    if (resourceResolution.grantResourceBackfill) grantData.resource = resourceResolution.grantResourceBackfill;
    await this.saveGrantWithTTL(env, grantKey, grantData, now);
    const tokenResponse = {
      access_token: await this.createAccessToken({
        userId,
        grantId,
        clientId: grantData.clientId,
        scope: tokenScopes,
        encryptedProps: encryptedAccessTokenProps,
        encryptionKey: accessTokenEncryptionKey,
        expiresIn: accessTokenTTL,
        audience,
        env
      }),
      token_type: "bearer",
      expires_in: accessTokenTTL,
      scope: tokenScopes.join(" "),
      resource: audience
    };
    if (refreshToken) tokenResponse.refresh_token = refreshToken;
    return new Response(JSON.stringify(tokenResponse), { headers: {
      "Content-Type": "application/json",
      ...NO_CACHE_HEADERS
    } });
  }
  /**
  * Handles the refresh token grant type
  * Issues a new access token using a refresh token
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with token data or error
  */
  async handleRefreshTokenGrant(body, clientInfo, env) {
    const refreshToken = body.refresh_token;
    if (!refreshToken) return this.createErrorResponse("invalid_request", { description: "Refresh token is required" }, {
      category: "refresh-token-grant",
      reason: "refresh_token_missing"
    });
    const tokenParts = refreshToken.split(":");
    if (tokenParts.length !== 3) return this.createErrorResponse("invalid_grant", { description: "Invalid token format" }, {
      category: "refresh-token-grant",
      reason: "refresh_token_malformed"
    });
    const [userId, grantId, _] = tokenParts;
    const providedTokenHash = await generateTokenId(refreshToken);
    const grantKey = `grant:${userId}:${grantId}`;
    const grantData = await env.OAUTH_KV.get(grantKey, { type: "json" });
    if (!grantData) return this.createErrorResponse("invalid_grant", { description: "Grant not found" }, {
      category: "refresh-token-grant",
      reason: "grant_not_found"
    });
    const isCurrentToken = grantData.refreshTokenId === providedTokenHash;
    const isPreviousToken = grantData.previousRefreshTokenId === providedTokenHash;
    if (!isCurrentToken && !isPreviousToken) return this.createErrorResponse("invalid_grant", { description: "Invalid refresh token" }, {
      category: "refresh-token-grant",
      reason: "refresh_token_mismatch"
    });
    if (grantData.clientId !== clientInfo.clientId) return this.createErrorResponse("invalid_grant", { description: "Client ID mismatch" }, {
      category: "refresh-token-grant",
      reason: "client_mismatch"
    });
    if (grantData.expiresAt !== void 0) {
      const now$1 = Math.floor(Date.now() / 1e3);
      if (grantData.expiresAt - now$1 < KV_MIN_EXPIRATION_TTL_SECONDS) return this.createErrorResponse("invalid_grant", { description: "Refresh token has expired" }, {
        category: "refresh-token-grant",
        reason: "refresh_token_expired"
      });
    }
    const resourceResolution = this.resolveTokenResource(body.resource, grantData);
    const audience = resourceResolution.audience;
    const newAccessToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
    const accessTokenId = await generateTokenId(newAccessToken);
    let accessTokenTTL = this.options.accessTokenTTL;
    let refreshTokenIdleTTL = this.options.refreshTokenIdleTTL;
    let wrappedKeyToUse;
    if (isCurrentToken) wrappedKeyToUse = grantData.refreshTokenWrappedKey;
    else wrappedKeyToUse = grantData.previousRefreshTokenWrappedKey;
    const encryptionKey = await unwrapKeyWithToken(refreshToken, wrappedKeyToUse);
    let grantEncryptionKey = encryptionKey;
    let accessTokenEncryptionKey = encryptionKey;
    let encryptedAccessTokenProps = grantData.encryptedProps;
    let tokenScopes = this.downscope(body.scope, grantData.scope);
    if (grantsNoneOfTheRequestedScopes(body.scope, tokenScopes)) return this.createErrorResponse("invalid_scope", { description: "None of the requested scopes were granted" }, {
      category: "refresh-token-grant",
      reason: "scope_not_granted"
    });
    let grantPropsChanged = false;
    if (this.options.tokenExchangeCallback) {
      const decryptedProps = await decryptProps(encryptionKey, grantData.encryptedProps);
      let grantProps = decryptedProps;
      let accessTokenProps = decryptedProps;
      const callbackOptions = {
        grantType: GrantType.REFRESH_TOKEN,
        clientId: clientInfo.clientId,
        subjectClientId: grantData.clientId,
        userId,
        grantId,
        scope: grantData.scope,
        requestedScope: tokenScopes,
        resource: audience,
        props: decryptedProps
      };
      const callbackResult = await this.callTokenExchangeCallback(callbackOptions, env);
      if (callbackResult) {
        if (callbackResult.newProps) {
          grantProps = callbackResult.newProps;
          grantPropsChanged = true;
          if (!callbackResult.accessTokenProps) accessTokenProps = callbackResult.newProps;
        }
        if (callbackResult.accessTokenProps) accessTokenProps = callbackResult.accessTokenProps;
        if (callbackResult.accessTokenTTL !== void 0) accessTokenTTL = callbackResult.accessTokenTTL;
        if (callbackResult.refreshTokenIdleTTL !== void 0) {
          if (!isValidAccessTokenTTL(callbackResult.refreshTokenIdleTTL)) return this.createErrorResponse("invalid_request", { description: `refreshTokenIdleTTL must be an integer of at least ${KV_MIN_EXPIRATION_TTL_SECONDS} seconds` }, {
            category: "refresh-token-grant",
            reason: "refresh_token_idle_ttl_invalid"
          });
          refreshTokenIdleTTL = callbackResult.refreshTokenIdleTTL;
        }
        if (callbackResult.accessTokenScope) tokenScopes = this.downscope(callbackResult.accessTokenScope, grantData.scope);
      }
      if (grantPropsChanged) {
        const grantResult = await encryptProps(grantProps);
        grantData.encryptedProps = grantResult.encryptedData;
        if (grantResult.key !== encryptionKey) {
          grantEncryptionKey = grantResult.key;
          wrappedKeyToUse = await wrapKeyWithToken(refreshToken, grantEncryptionKey);
        } else grantEncryptionKey = grantResult.key;
      }
      if (accessTokenProps !== grantProps) {
        const tokenResult = await encryptProps(accessTokenProps);
        encryptedAccessTokenProps = tokenResult.encryptedData;
        accessTokenEncryptionKey = tokenResult.key;
      } else {
        encryptedAccessTokenProps = grantData.encryptedProps;
        accessTokenEncryptionKey = grantEncryptionKey;
      }
    }
    const now = Math.floor(Date.now() / 1e3);
    if (grantData.expiresAt !== void 0 && grantData.expiresAt - now < KV_MIN_EXPIRATION_TTL_SECONDS) return this.createErrorResponse("invalid_grant", { description: "Refresh token has expired" }, {
      category: "refresh-token-grant",
      reason: "refresh_token_expired"
    });
    if (refreshTokenIdleTTL !== void 0) grantData.expiresAt = now + refreshTokenIdleTTL;
    if (grantData.expiresAt !== void 0) {
      const remainingRefreshTokenLifetime = grantData.expiresAt - now;
      if (remainingRefreshTokenLifetime > 0) accessTokenTTL = Math.min(accessTokenTTL, remainingRefreshTokenLifetime);
    }
    if (!isValidAccessTokenTTL(accessTokenTTL)) return this.createErrorResponse("invalid_request", { description: "Requested token lifetime must be at least 60 seconds" }, {
      category: "refresh-token-grant",
      reason: "requested_ttl_too_short"
    });
    const accessTokenExpiresAt = now + accessTokenTTL;
    const accessTokenWrappedKey = await wrapKeyWithToken(newAccessToken, accessTokenEncryptionKey);
    const newRefreshToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
    const newRefreshTokenId = await generateTokenId(newRefreshToken);
    const newRefreshTokenWrappedKey = await wrapKeyWithToken(newRefreshToken, grantEncryptionKey);
    grantData.previousRefreshTokenId = providedTokenHash;
    grantData.previousRefreshTokenWrappedKey = wrappedKeyToUse;
    grantData.refreshTokenId = newRefreshTokenId;
    grantData.refreshTokenWrappedKey = newRefreshTokenWrappedKey;
    if (resourceResolution.grantResourceBackfill) grantData.resource = resourceResolution.grantResourceBackfill;
    await this.saveGrantWithTTL(env, grantKey, grantData, now);
    const accessTokenData = {
      id: accessTokenId,
      grantId,
      userId,
      createdAt: now,
      expiresAt: accessTokenExpiresAt,
      audience,
      scope: tokenScopes,
      wrappedEncryptionKey: accessTokenWrappedKey,
      grant: {
        clientId: grantData.clientId,
        scope: grantData.scope,
        encryptedProps: encryptedAccessTokenProps
      }
    };
    try {
      await env.OAUTH_KV.put(`token:${userId}:${grantId}:${accessTokenId}`, JSON.stringify(accessTokenData), { expirationTtl: accessTokenTTL });
    } catch (error) {
      this.throwRetryableTokenStorageErrorIfKvRateLimited(error);
      throw error;
    }
    const tokenResponse = {
      access_token: newAccessToken,
      token_type: "bearer",
      expires_in: accessTokenTTL,
      refresh_token: newRefreshToken,
      scope: tokenScopes.join(" "),
      resource: audience
    };
    return new Response(JSON.stringify(tokenResponse), { headers: {
      "Content-Type": "application/json",
      ...NO_CACHE_HEADERS
    } });
  }
  /**
  * Core token exchange logic (RFC 8693)
  * Performs the actual token exchange operation
  * This method is not private because `OAuthHelpers` needs to call it. Note that since
  * `OAuthProviderImpl` is not exposed outside this module, this is still effectively
  * module-private.
  * @param subjectToken - The subject token to exchange
  * @param requestedScopes - Optional requested scopes, limited to the subject token's scopes
  * @param requestedResource - Optional resource/audience; when present, it must match the configured canonical resource
  * @param expiresIn - Optional TTL override in seconds
  * @param clientInfo - The client making the exchange request
  * @param env - Cloudflare Worker environment variables
  * @returns Promise resolving to token response
  * @throws OAuthError with OAuth error code and description
  */
  async exchangeToken(subjectToken, requestedScopes, requestedResource, expiresIn, clientInfo, env) {
    const tokenSummary = await this.unwrapToken(subjectToken, env);
    if (!tokenSummary) throw new OAuthError("invalid_request", {
      description: "Invalid or expired subject token",
      internal: {
        category: "token-exchange-grant",
        reason: "subject_token_invalid"
      }
    });
    const grantKey = `grant:${tokenSummary.userId}:${tokenSummary.grantId}`;
    const grantData = await env.OAUTH_KV.get(grantKey, { type: "json" });
    if (!grantData) throw new OAuthError("invalid_request", {
      description: "Grant not found",
      internal: {
        category: "token-exchange-grant",
        reason: "grant_not_found"
      }
    });
    const crossClientExchange = grantData.clientId !== clientInfo.clientId;
    const crossClientRejection = /* @__PURE__ */ __name(() => new OAuthError("invalid_request", {
      description: "The subject token was issued to a different client",
      internal: {
        category: "token-exchange-grant",
        reason: "cross_client_subject_token"
      }
    }), "crossClientRejection");
    if (crossClientExchange && !this.options.tokenExchangeCallback) throw crossClientRejection();
    let tokenScopes = this.downscope(requestedScopes, tokenSummary.scope);
    if (grantsNoneOfTheRequestedScopes(requestedScopes, tokenScopes)) throw new OAuthError("invalid_scope", {
      description: "None of the requested scopes were granted",
      internal: {
        category: "token-exchange-grant",
        reason: "scope_not_granted"
      }
    });
    const newAudience = this.resolveTokenExchangeResource(requestedResource, tokenSummary.audience);
    const now = Math.floor(Date.now() / 1e3);
    const subjectTokenRemainingLifetime = tokenSummary.expiresAt - now;
    if (subjectTokenRemainingLifetime < KV_MIN_EXPIRATION_TTL_SECONDS) throw new OAuthError("invalid_request", {
      description: "Subject token is too close to expiry to exchange",
      internal: {
        category: "token-exchange-grant",
        reason: "subject_token_near_expiry"
      }
    });
    let accessTokenTTL = this.options.accessTokenTTL ?? DEFAULT_ACCESS_TOKEN_TTL;
    if (expiresIn !== void 0) {
      if (expiresIn <= 0) throw new OAuthError("invalid_request", {
        description: "Invalid expires_in parameter",
        internal: {
          category: "token-exchange-grant",
          reason: "expires_in_invalid"
        }
      });
      accessTokenTTL = Math.min(expiresIn, subjectTokenRemainingLifetime);
    } else accessTokenTTL = Math.min(accessTokenTTL, subjectTokenRemainingLifetime);
    const subjectTokenData = await env.OAUTH_KV.get(`token:${tokenSummary.userId}:${tokenSummary.grantId}:${tokenSummary.id}`, { type: "json" });
    if (!subjectTokenData) throw new OAuthError("invalid_request", {
      description: "Subject token data not found",
      internal: {
        category: "token-exchange-grant",
        reason: "subject_token_data_missing"
      }
    });
    const encryptionKey = await unwrapKeyWithToken(subjectToken, subjectTokenData.wrappedEncryptionKey);
    let accessTokenEncryptionKey = encryptionKey;
    let encryptedAccessTokenProps = subjectTokenData.grant.encryptedProps;
    if (this.options.tokenExchangeCallback) {
      const decryptedProps = await decryptProps(encryptionKey, subjectTokenData.grant.encryptedProps);
      const callbackOptions = {
        grantType: GrantType.TOKEN_EXCHANGE,
        clientId: clientInfo.clientId,
        subjectClientId: grantData.clientId,
        userId: tokenSummary.userId,
        grantId: tokenSummary.grantId,
        scope: tokenSummary.grant.scope,
        requestedScope: tokenScopes,
        resource: newAudience,
        props: decryptedProps
      };
      const callbackResult = await this.callTokenExchangeCallback(callbackOptions, env);
      if (crossClientExchange && callbackResult?.allowCrossClientExchange !== true) throw crossClientRejection();
      if (callbackResult) {
        let accessTokenProps = decryptedProps;
        if (callbackResult.newProps) {
          if (!callbackResult.accessTokenProps) accessTokenProps = callbackResult.newProps;
        }
        if (callbackResult.accessTokenProps) accessTokenProps = callbackResult.accessTokenProps;
        if (callbackResult.accessTokenTTL !== void 0) accessTokenTTL = Math.min(callbackResult.accessTokenTTL, subjectTokenRemainingLifetime);
        if (accessTokenProps !== decryptedProps) {
          const tokenResult = await encryptProps(accessTokenProps);
          encryptedAccessTokenProps = tokenResult.encryptedData;
          accessTokenEncryptionKey = tokenResult.key;
        }
        if (callbackResult.accessTokenScope) tokenScopes = this.downscope(callbackResult.accessTokenScope, tokenSummary.scope);
      }
    }
    if (!isValidAccessTokenTTL(accessTokenTTL)) throw new OAuthError("invalid_request", {
      description: "Requested token lifetime must be at least 60 seconds",
      internal: {
        category: "token-exchange-grant",
        reason: "requested_ttl_too_short"
      }
    });
    return {
      access_token: await this.createAccessToken({
        userId: tokenSummary.userId,
        grantId: tokenSummary.grantId,
        clientId: clientInfo.clientId,
        scope: tokenScopes,
        encryptedProps: encryptedAccessTokenProps,
        encryptionKey: accessTokenEncryptionKey,
        expiresIn: accessTokenTTL,
        audience: newAudience,
        env
      }),
      issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
      token_type: "bearer",
      expires_in: accessTokenTTL,
      scope: tokenScopes.join(" "),
      resource: newAudience
    };
  }
  /**
  * Handles OAuth 2.0 token exchange requests (RFC 8693)
  * Exchanges an existing access token for a new one with modified characteristics
  * @param body - The parsed request body
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response with new token data or error
  */
  async handleTokenExchangeGrant(body, clientInfo, env) {
    const subjectToken = body.subject_token;
    const subjectTokenType = body.subject_token_type;
    const requestedTokenType = body.requested_token_type || "urn:ietf:params:oauth:token-type:access_token";
    const requestedScope = body.scope;
    const requestedResource = body.resource;
    if (!subjectToken) return this.createErrorResponse("invalid_request", { description: "subject_token is required" }, {
      category: "token-exchange-grant",
      reason: "subject_token_missing"
    });
    if (!subjectTokenType) return this.createErrorResponse("invalid_request", { description: "subject_token_type is required" }, {
      category: "token-exchange-grant",
      reason: "subject_token_type_missing"
    });
    if (subjectTokenType !== "urn:ietf:params:oauth:token-type:access_token") return this.createErrorResponse("invalid_request", { description: "Only access_token subject_token_type is supported" }, {
      category: "token-exchange-grant",
      reason: "subject_token_type_unsupported"
    });
    if (requestedTokenType !== "urn:ietf:params:oauth:token-type:access_token") return this.createErrorResponse("invalid_request", { description: "Only access_token requested_token_type is supported" }, {
      category: "token-exchange-grant",
      reason: "requested_token_type_unsupported"
    });
    let requestedScopes;
    if (requestedScope) if (typeof requestedScope === "string") requestedScopes = requestedScope.split(" ").filter(Boolean);
    else if (Array.isArray(requestedScope)) requestedScopes = requestedScope;
    else return this.createErrorResponse("invalid_request", { description: "Invalid scope parameter format" }, {
      category: "token-exchange-grant",
      reason: "scope_malformed"
    });
    let expiresIn;
    if (body.expires_in !== void 0) {
      const requestedTTL = parseInt(body.expires_in, 10);
      if (isNaN(requestedTTL) || requestedTTL <= 0) return this.createErrorResponse("invalid_request", { description: "Invalid expires_in parameter" }, {
        category: "token-exchange-grant",
        reason: "expires_in_invalid"
      });
      expiresIn = requestedTTL;
    }
    try {
      const tokenResponse = await this.exchangeToken(subjectToken, requestedScopes, requestedResource, expiresIn, clientInfo, env);
      return new Response(JSON.stringify(tokenResponse), { headers: {
        "Content-Type": "application/json",
        ...NO_CACHE_HEADERS
      } });
    } catch (error) {
      const response = this.createOAuthErrorResponse(error);
      if (response) return response;
      throw error;
    }
  }
  /**
  * Handles the MCP Enterprise-Managed Authorization JWT-bearer grant.
  *
  * Acts as a thin shell around `runEmaPipeline`: gate non-EMA traffic, run
  * the pipeline, translate the typed `EmaValidationError` Result back to a
  * standard OAuth wire response. All validation logic lives in pure
  * functions in `src/ema/`.
  */
  async handleJwtBearerGrant(body, clientInfo, clientAuthMethod, env, requestUrl, request) {
    const enterpriseOptions = this.options.enterpriseManagedAuthorization;
    if (!enterpriseOptions) return this.createErrorResponse("unsupported_grant_type", { description: "Grant type not supported" }, {
      category: "enterprise-managed-authorization",
      reason: "grant_disabled"
    });
    if (clientAuthMethod === "none" && !enterpriseOptions.allowPublicClients) return this.createErrorResponse("invalid_client", {
      description: "Enterprise-managed authorization requires client authentication",
      statusCode: 401
    }, {
      category: "enterprise-managed-authorization",
      reason: "client_authentication_required"
    });
    const result = await this.runEmaPipeline({
      body,
      clientInfo,
      env,
      requestUrl,
      request,
      enterpriseOptions
    });
    if (!result.ok) {
      const wire = emaErrorToWire(result.error);
      return this.createErrorResponse(wire.code, { description: wire.message }, {
        category: "enterprise-managed-authorization",
        reason: result.error.reason,
        detail: result.error
      });
    }
    return new Response(JSON.stringify(result.value), { headers: {
      "Content-Type": "application/json",
      ...NO_CACHE_HEADERS
    } });
  }
  /**
  * Runs the full EMA token-request pipeline as a chain of pure validators
  * and adapter calls. Each step short-circuits on the first failure.
  *
  * Sequence:
  *   parse → validate header → trust issuer → fetch JWKS → select key →
  *   verify signature → validate claims → record jti → parse scope →
  *   run mapper → validate mapper result → compute TTL → mint token.
  */
  async runEmaPipeline(args) {
    const { body, clientInfo, env, requestUrl, request, enterpriseOptions } = args;
    const { jwksProvider, jtiStore } = this;
    const configuredResource = this.resolveNewTokenResource(body.resource);
    if (!jwksProvider || !jtiStore) throw new Error("EMA pipeline invoked without configured adapters");
    const now = Math.floor(Date.now() / 1e3);
    const parsed = parseIdJag(body.assertion, EMA_MAX_JWT_BYTES);
    if (!parsed.ok) return parsed;
    const header = validateIdJagHeader(parsed.value.header, EMA_ID_JAG_JWT_TYPE, EMA_SUPPORTED_JWT_ALGORITHMS);
    if (!header.ok) return header;
    const alg = header.value.alg;
    const trustedIssuer = await resolveTrustedIssuer({
      iss: parsed.value.rawClaims.iss,
      alg,
      resolver: enterpriseOptions.trustedIssuers,
      env,
      request,
      clientInfo
    });
    if (!trustedIssuer.ok) return trustedIssuer;
    const verified = await this.verifyAssertionSignature({
      parsed: parsed.value,
      header: header.value,
      trustedIssuer: trustedIssuer.value,
      jwksProvider,
      now
    });
    if (!verified.ok) return verified;
    const claims = validateIdJagClaims({
      rawClaims: parsed.value.rawClaims,
      trustedIssuer: trustedIssuer.value,
      expectedAudience: trustedIssuer.value.audience ?? this.getAuthorizationServerIssuer(requestUrl),
      clientId: clientInfo.clientId,
      configuredResource,
      now,
      clockSkewSeconds: enterpriseOptions.clockSkewSeconds ?? EMA_DEFAULT_CLOCK_SKEW_SECONDS,
      maxAssertionLifetimeSeconds: enterpriseOptions.maxAssertionLifetimeSeconds ?? EMA_DEFAULT_MAX_ASSERTION_LIFETIME_SECONDS
    });
    if (!claims.ok) return claims;
    const markNow = Math.floor(Date.now() / 1e3);
    const replay = await jtiStore.markUsed({
      issuer: claims.value.claims.iss,
      jti: claims.value.claims.jti,
      exp: claims.value.claims.exp,
      now: markNow,
      env
    });
    if (!replay.ok) return replay;
    const requestedScope = parseEmaScopeParam(body.scope, claims.value.assertionScopes);
    if (!requestedScope.ok) return requestedScope;
    let mapperOutput;
    try {
      mapperOutput = await enterpriseOptions.mapClaims({
        claims: claims.value.claims,
        clientInfo,
        resource: configuredResource,
        requestedScope: requestedScope.value,
        request: args.request,
        env
      });
    } catch {
      return err({ reason: "mapper_threw" });
    }
    const mapped = validateEmaMapperResult(mapperOutput);
    if (!mapped.ok) return mapped;
    const issueNow = Math.floor(Date.now() / 1e3);
    const ttl = computeEmaAccessTokenTTL({
      configuredDefaultSeconds: this.options.accessTokenTTL ?? DEFAULT_ACCESS_TOKEN_TTL,
      assertionExp: claims.value.claims.exp,
      mapperTtl: mapped.value.accessTokenTTL,
      now: issueNow,
      minTtlSeconds: KV_MIN_EXPIRATION_TTL_SECONDS
    });
    if (!ttl.ok) return ttl;
    return ok(await this.issueEmaAccessToken({
      clientId: clientInfo.clientId,
      userId: mapped.value.userId,
      mapperScope: mapped.value.scope,
      mapperProps: mapped.value.props,
      mapperMetadata: mapped.value.metadata,
      assertionScopes: claims.value.assertionScopes,
      resource: configuredResource,
      accessTokenTTLSeconds: ttl.value,
      env,
      now: issueNow
    }));
  }
  /**
  * Verifies the ID-JAG signature against the trusted issuer's JWKS,
  * force-refreshing once on a `kid` miss to accommodate IdP key rotation.
  * Uses the in-memory cached JWKS fetcher with anti-DoS cool-down.
  */
  async verifyAssertionSignature(args) {
    const alg = args.header.alg;
    const { jwksProvider } = args;
    const initialJwks = await jwksProvider.fetch(args.trustedIssuer, {
      forceRefresh: false,
      now: args.now
    });
    if (!initialJwks.ok) return initialJwks;
    let jwk = selectJwk(initialJwks.value, alg, args.header.kid);
    if (!jwk.ok && args.header.kid) {
      const refreshed = await jwksProvider.fetch(args.trustedIssuer, {
        forceRefresh: true,
        now: args.now
      });
      if (!refreshed.ok) return refreshed;
      jwk = selectJwk(refreshed.value, alg, args.header.kid);
    }
    if (!jwk.ok) return jwk;
    if (!await verifyIdJagSignature({
      alg,
      jwk: jwk.value,
      signingInput: args.parsed.signingInput,
      signature: args.parsed.signature
    })) return err({ reason: "signature_failed" });
    return ok(void 0);
  }
  /**
  * Mints the access token for an authorized EMA request.
  *
  * Uses the same grant + access-token machinery as the authorization-code
  * grant: encrypt the props, persist the grant under `grant:userId:grantId`,
  * and create an opaque access token bound to the resource as audience.
  */
  async issueEmaAccessToken(args) {
    const tokenScopes = args.assertionScopes.length > 0 ? this.downscope(args.mapperScope, args.assertionScopes) : args.mapperScope;
    const grantId = generateRandomString(16);
    const { encryptedData, key: encryptionKey } = await encryptProps(args.mapperProps);
    const grant = {
      id: grantId,
      clientId: args.clientId,
      userId: args.userId,
      scope: tokenScopes,
      metadata: args.mapperMetadata ?? null,
      encryptedProps: encryptedData,
      createdAt: args.now,
      expiresAt: args.now + args.accessTokenTTLSeconds,
      resource: args.resource
    };
    await this.saveGrantWithTTL(args.env, `grant:${args.userId}:${grantId}`, grant, args.now);
    return {
      access_token: await this.createAccessToken({
        userId: args.userId,
        grantId,
        clientId: args.clientId,
        scope: tokenScopes,
        encryptedProps: encryptedData,
        encryptionKey,
        expiresIn: args.accessTokenTTLSeconds,
        audience: args.resource,
        env: args.env
      }),
      token_type: "bearer",
      expires_in: args.accessTokenTTLSeconds,
      scope: tokenScopes.join(" "),
      resource: args.resource
    };
  }
  /**
  * Handles an RFC 7009 revocation request from an authenticated client.
  * - Access tokens: Revokes only the specific token
  * - Refresh tokens: Revokes the entire grant (access + refresh tokens)
  * Per RFC 7009 §2.1, the server MUST verify the token was issued to the client making the request.
  * @param body - The parsed request body containing token parameter
  * @param clientInfo - The authenticated client information
  * @param env - Cloudflare Worker environment variables
  * @returns Response confirming revocation or error
  */
  async revokeToken(body, clientInfo, env) {
    const token = body.token;
    const tokenTypeHint = body.token_type_hint;
    if (!token) return this.createErrorResponse("invalid_request", { description: "Token parameter is required" }, {
      category: "token-revocation",
      reason: "token_missing"
    });
    const tokenParts = token.split(":");
    if (tokenParts.length !== 3) return new Response("", { status: 200 });
    const [userId, grantId, _] = tokenParts;
    const tokenId = await generateTokenId(token);
    if (tokenTypeHint === "refresh_token") {
      if (await this.revokeRefreshIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
      if (await this.revokeAccessIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
    } else {
      if (await this.revokeAccessIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
      if (await this.revokeRefreshIfOwned(tokenId, userId, grantId, clientInfo, env)) return new Response("", { status: 200 });
    }
    return new Response("", { status: 200 });
  }
  /** Revoke an access token if it exists and belongs to the requesting client. */
  async revokeAccessIfOwned(tokenId, userId, grantId, clientInfo, env) {
    const tokenData = await env.OAUTH_KV.get(`token:${userId}:${grantId}:${tokenId}`, { type: "json" });
    if (!tokenData) return false;
    const tokenClientId = tokenData.grant?.clientId;
    if (tokenClientId !== void 0) {
      if (tokenClientId !== clientInfo.clientId) return false;
    } else if ((await env.OAUTH_KV.get(`grant:${userId}:${grantId}`, { type: "json" }))?.clientId !== clientInfo.clientId) return false;
    await this.revokeSpecificAccessToken(tokenId, userId, grantId, env);
    return true;
  }
  /** Revoke a refresh token (and its grant) if it exists and belongs to the requesting client. */
  async revokeRefreshIfOwned(tokenId, userId, grantId, clientInfo, env) {
    const grantData = await env.OAUTH_KV.get(`grant:${userId}:${grantId}`, { type: "json" });
    if (!grantData) return false;
    if (!(grantData.refreshTokenId === tokenId || grantData.previousRefreshTokenId === tokenId)) return false;
    if (grantData.clientId !== clientInfo.clientId) return false;
    await this.createOAuthHelpers(env).revokeGrant(grantId, userId);
    return true;
  }
  /**
  * Revokes a specific access token without affecting the refresh token
  * @param tokenId - The hashed token ID
  * @param userId - The user ID extracted from the token
  * @param grantId - The grant ID extracted from the token
  * @param env - Cloudflare Worker environment variables
  */
  async revokeSpecificAccessToken(tokenId, userId, grantId, env) {
    const tokenKey = `token:${userId}:${grantId}:${tokenId}`;
    await env.OAUTH_KV.delete(tokenKey);
  }
  /**
  * Handles the dynamic client registration endpoint (RFC 7591)
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @returns Response with client registration data or error
  */
  async handleClientRegistration(request, env) {
    if (!this.options.clientRegistrationEndpoint) return this.createErrorResponse("not_implemented", {
      description: "Client registration is not enabled",
      statusCode: 501
    }, {
      category: "client-registration",
      reason: "registration_disabled"
    });
    if (request.method !== "POST") return this.createErrorResponse("invalid_request", {
      description: "Method not allowed",
      statusCode: 405,
      headers: { Allow: "POST, OPTIONS" }
    }, {
      category: "client-registration",
      reason: "method_not_allowed"
    });
    if (parseInt(request.headers.get("Content-Length") || "0", 10) > 1048576) return this.createErrorResponse("invalid_request", {
      description: "Request payload too large, must be under 1 MiB",
      statusCode: 413
    }, {
      category: "client-registration",
      reason: "declared_payload_too_large"
    });
    const callbackRequest = request.clone();
    let parsedJson;
    try {
      const text = await readTextWithLimit(request, 1048576);
      if (text === void 0) {
        callbackRequest.body?.cancel().catch(() => void 0);
        return this.createErrorResponse("invalid_request", {
          description: "Request payload too large, must be under 1 MiB",
          statusCode: 413
        }, {
          category: "client-registration",
          reason: "payload_too_large"
        });
      }
      parsedJson = JSON.parse(text);
    } catch {
      return this.createErrorResponse("invalid_request", {
        description: "Invalid JSON payload",
        statusCode: 400
      }, {
        category: "client-registration",
        reason: "json_malformed"
      });
    }
    let clientMetadata;
    let metadata;
    try {
      clientMetadata = requireJsonObject(parsedJson);
      const capabilities = this.options.disallowPublicClientRegistration ? {
        ...this.serverCapabilities,
        tokenEndpointAuthMethods: this.serverCapabilities.tokenEndpointAuthMethods.filter((method) => method !== "none")
      } : this.serverCapabilities;
      metadata = resolveDynamicClientRegistrationMetadata(clientMetadata, capabilities);
    } catch (error) {
      if (this.options.disallowPublicClientRegistration && wouldRegisterPublicClient(clientMetadata, this.serverCapabilities)) return this.createErrorResponse("invalid_client_metadata", { description: "Public client registration is not allowed" }, {
        category: "client-registration",
        reason: "public_client_forbidden"
      });
      return this.createErrorResponse("invalid_client_metadata", { description: error instanceof Error ? error.message : "Invalid client metadata" }, {
        category: "client-registration",
        reason: "metadata_invalid",
        detail: error
      });
    }
    const authMethod = metadata.tokenEndpointAuthMethod;
    const isPublicClient = authMethod === "none";
    const clientId = generateRandomString(16);
    let clientSecret;
    let hashedSecret;
    if (!isPublicClient) {
      clientSecret = generateRandomString(32);
      hashedSecret = await hashSecret(clientSecret);
    }
    const clientInfo = {
      clientId,
      redirectUris: metadata.redirectUris,
      clientName: metadata.clientName,
      logoUri: metadata.logoUri,
      clientUri: metadata.clientUri,
      policyUri: metadata.policyUri,
      tosUri: metadata.tosUri,
      jwksUri: metadata.jwksUri,
      i18n: metadata.i18n,
      contacts: metadata.contacts,
      grantTypes: metadata.grantTypes,
      responseTypes: metadata.responseTypes,
      registrationDate: Math.floor(Date.now() / 1e3),
      tokenEndpointAuthMethod: authMethod,
      ...metadata.authMethodExplicit ? { authMethodExplicit: true } : {},
      ...!isPublicClient && hashedSecret ? { clientSecret: hashedSecret } : {}
    };
    if (this.options.clientRegistrationCallback) {
      let callbackResult;
      try {
        callbackResult = await Promise.resolve(this.options.clientRegistrationCallback({
          clientMetadata,
          request: callbackRequest
        }));
      } catch (error) {
        return this.createErrorResponse("server_error", {
          description: "Client registration callback failed",
          statusCode: 500
        }, {
          category: "client-registration",
          reason: "callback_failed",
          detail: error
        });
      }
      if (callbackResult !== void 0) return this.createErrorResponse(callbackResult.code || "invalid_client_metadata", {
        description: callbackResult.description || "Client registration denied",
        statusCode: callbackResult.status ?? 400
      }, {
        category: "client-registration",
        reason: "callback_denied",
        detail: callbackResult
      });
    }
    await this.putRegisteredClient(env, clientInfo, clientInfo.registrationDate);
    const response = {
      client_id: clientInfo.clientId,
      redirect_uris: clientInfo.redirectUris,
      client_name: clientInfo.clientName,
      logo_uri: clientInfo.logoUri,
      client_uri: clientInfo.clientUri,
      policy_uri: clientInfo.policyUri,
      tos_uri: clientInfo.tosUri,
      jwks_uri: clientInfo.jwksUri,
      contacts: clientInfo.contacts,
      grant_types: clientInfo.grantTypes,
      response_types: clientInfo.responseTypes,
      token_endpoint_auth_method: clientInfo.tokenEndpointAuthMethod,
      client_id_issued_at: clientInfo.registrationDate
    };
    if (clientInfo.i18n) {
      for (const [key, value] of Object.entries(clientInfo.i18n)) if (!(key in response)) response[key] = value;
    }
    if (clientSecret) {
      response.client_secret = clientSecret;
      response.client_secret_expires_at = this.options.clientRegistrationTTL !== void 0 && clientInfo.registrationDate ? clientInfo.registrationDate + this.options.clientRegistrationTTL : 0;
      response.client_secret_issued_at = clientInfo.registrationDate;
    }
    return new Response(JSON.stringify(response), {
      status: 201,
      headers: {
        "Content-Type": "application/json",
        ...NO_CACHE_HEADERS
      }
    });
  }
  /**
  * Handles API requests by validating the access token and calling the API handler
  * @param request - The HTTP request
  * @param env - Cloudflare Worker environment variables
  * @param ctx - Cloudflare Worker execution context
  * @returns Response from the API handler or error
  */
  async handleApiRequest(request, env, ctx, apiRoute) {
    const url = new URL(request.url);
    const { resourceServer } = apiRoute;
    const configuredResource = resourceServer.resourceMetadata.resource;
    const externalTokenResolver = resourceServer.resolveExternalToken;
    const resourceMetadataUrl = this.getResourceMetadataUrlForRequest(url, resourceServer);
    const challenge = /* @__PURE__ */ __name((error, description, scopes = []) => this.buildWwwAuthenticateHeader(resourceMetadataUrl, error, description, scopes, resourceServer), "challenge");
    const authHeader = request.headers.get("Authorization");
    const bearerMatch = authHeader ? /^Bearer[\t ]+([^\s,]+)$/i.exec(authHeader) : null;
    if (!bearerMatch) return new Response(null, {
      status: 401,
      headers: {
        ...NO_CACHE_HEADERS,
        "WWW-Authenticate": challenge()
      }
    });
    const accessToken = bearerMatch[1];
    const parts = accessToken.split(":");
    const isPossiblyInternalFormat = parts.length === 3;
    let tokenData = null;
    let userId = "";
    let grantId = "";
    if (isPossiblyInternalFormat) {
      [userId, grantId] = parts;
      const id = await generateTokenId(accessToken);
      tokenData = await env.OAUTH_KV.get(`token:${userId}:${grantId}:${id}`, { type: "json" });
    }
    if (!tokenData && (!externalTokenResolver || isIssuedTokenFormat(accessToken))) return this.createErrorResponse("invalid_token", {
      description: "Invalid access token",
      statusCode: 401,
      headers: { "WWW-Authenticate": challenge("invalid_token") }
    }, {
      category: "protected-resource",
      reason: "token_not_found"
    });
    if (tokenData) {
      const tokenAudience = this.resolveStoredTokenAudience(tokenData.audience);
      if (!isExactResource(tokenAudience, configuredResource)) return this.createErrorResponse("invalid_token", {
        description: "Access token is not bound to the configured resource",
        statusCode: 401,
        headers: { "WWW-Authenticate": challenge("invalid_token") }
      }, {
        category: "protected-resource",
        reason: "token_audience_unbound"
      });
      const now = Math.floor(Date.now() / 1e3);
      if (tokenData.expiresAt < now) return this.createErrorResponse("invalid_token", {
        description: "Access token expired",
        statusCode: 401,
        headers: { "WWW-Authenticate": challenge("invalid_token") }
      }, {
        category: "protected-resource",
        reason: "token_expired"
      });
      if (tokenAudience) {
        const requestUrl = new URL(request.url);
        const resourceServer$1 = `${requestUrl.protocol}//${requestUrl.host}${requestUrl.pathname}${requestUrl.search}`;
        if (!(Array.isArray(tokenAudience) ? tokenAudience : [tokenAudience]).some((aud) => audienceMatches(resourceServer$1, aud))) return this.createErrorResponse("invalid_token", {
          description: "Token audience does not match resource server",
          statusCode: 401,
          headers: { "WWW-Authenticate": challenge("invalid_token", "Invalid audience") }
        }, {
          category: "protected-resource",
          reason: "audience_mismatch"
        });
      }
      ctx.props = await decryptProps(await unwrapKeyWithToken(accessToken, tokenData.wrappedEncryptionKey), tokenData.grant.encryptedProps);
      ctx.auth = {
        token: accessToken,
        audience: configuredResource,
        expiresAt: tokenData.expiresAt,
        scope: [...tokenData.scope || tokenData.grant.scope],
        userId: tokenData.userId,
        clientId: tokenData.grant.clientId
      };
    } else if (externalTokenResolver) {
      let ext;
      try {
        ext = await externalTokenResolver({
          token: accessToken,
          request,
          env
        });
      } catch (error) {
        const response = this.createExternalTokenErrorResponse(error, resourceMetadataUrl, resourceServer);
        if (response) return response;
        throw error;
      }
      if (!ext) return this.createErrorResponse("invalid_token", {
        description: "Invalid access token",
        statusCode: 401,
        headers: { "WWW-Authenticate": challenge("invalid_token") }
      }, {
        category: "protected-resource",
        reason: "external_token_rejected"
      });
      if (typeof ext.audience !== "string" || !isExactResource(ext.audience, configuredResource)) return this.createErrorResponse("invalid_token", {
        description: "External access token is not bound to the configured resource",
        statusCode: 401,
        headers: { "WWW-Authenticate": challenge("invalid_token") }
      }, {
        category: "protected-resource",
        reason: "external_audience_unbound"
      });
      if (ext.audience) {
        const requestUrl = new URL(request.url);
        const resourceServer$1 = `${requestUrl.protocol}//${requestUrl.host}${requestUrl.pathname}${requestUrl.search}`;
        if (!(Array.isArray(ext.audience) ? ext.audience : [ext.audience]).some((aud) => audienceMatches(resourceServer$1, aud))) return this.createErrorResponse("invalid_token", {
          description: "Token audience does not match resource server",
          statusCode: 401,
          headers: { "WWW-Authenticate": challenge("invalid_token", "Invalid audience") }
        }, {
          category: "protected-resource",
          reason: "external_audience_mismatch"
        });
      }
      ctx.props = ext.props;
      ctx.auth = {
        token: accessToken,
        audience: configuredResource,
        scope: []
      };
    }
    if (!env.OAUTH_PROVIDER) env.OAUTH_PROVIDER = this.createOAuthHelpers(env);
    const apiHandler = apiRoute.handler;
    if (apiHandler.type === HandlerType.EXPORTED_HANDLER) return apiHandler.handler.fetch(request, env, ctx);
    else return new apiHandler.handler(ctx, env).fetch(request);
  }
  /**
  * Creates the helper methods object for OAuth operations
  * This is passed to the handler functions to allow them to interact with the OAuth system
  * @param env - Cloudflare Worker environment variables
  * @returns An instance of OAuthHelpers
  */
  createOAuthHelpers(env) {
    return new OAuthHelpersImpl(env, this);
  }
  /**
  * Saves a grant to KV with appropriate TTL based on expiration
  * @param env - The environment bindings
  * @param grantKey - The KV key for the grant
  * @param grantData - The grant data to save
  * @param now - Current timestamp in seconds
  */
  async saveGrantWithTTL(env, grantKey, grantData, now) {
    const minExpiration = now + KV_MIN_EXPIRATION_TTL_SECONDS + KV_EXPIRATION_CLAMP_MARGIN_SECONDS;
    const kvOptions = grantData.expiresAt !== void 0 ? { expiration: Math.max(grantData.expiresAt, minExpiration) } : {};
    try {
      await env.OAUTH_KV.put(grantKey, JSON.stringify(grantData), grantPutOptions(grantData, kvOptions));
    } catch (error) {
      this.throwRetryableTokenStorageErrorIfKvRateLimited(error);
      throw error;
    }
  }
  throwRetryableTokenStorageErrorIfKvRateLimited(error) {
    if (!this.isKvRateLimitError(error)) return;
    throw new OAuthError("temporarily_unavailable", {
      description: "Token issuance is temporarily unavailable; retry shortly",
      statusCode: 429,
      headers: { "Retry-After": "30" },
      internal: {
        category: "token-issuance",
        reason: "kv_rate_limited",
        detail: error
      }
    });
  }
  isKvRateLimitError(error) {
    if (!(error instanceof Error)) return false;
    return /KV .*failed: 429 Too Many Requests/i.test(error.message) || /429 Too Many Requests/i.test(error.message);
  }
  /**
  * Fetches client information from KV storage or via CIMD (Client ID Metadata Document)
  * This method is not private because `OAuthHelpers` needs to call it. Note that since
  * `OAuthProviderImpl` is not exposed outside this module, this is still effectively
  * module-private.
  *
  * Supports CIMD: If clientId is an HTTPS URL with a non-root path, the metadata
  * document will be fetched from that URL instead of looking up in KV storage.
  *
  * @param env - Cloudflare Worker environment variables
  * @param clientId - The client ID to look up (can be a regular ID or an HTTPS URL for CIMD)
  * @returns The client information, or null if the client does not exist. Null means
  * definitive absence; failures to determine the answer throw instead (KV errors
  * propagate, and a CIMD metadata fetch failure throws `CimdFetchError`), so an
  * upstream outage is distinguishable from an unregistered client.
  */
  /**
  * Write a client record that is subject to `clientRegistrationTTL`. The record carries
  * the expiry it was written with, so a later token request can tell a registration the
  * provider may renew from a permanent one without listing KV. With the TTL unset the
  * record is written to last, and any stamp from an earlier configuration is dropped.
  */
  async putRegisteredClient(env, client, now) {
    const ttl = this.options.clientRegistrationTTL;
    const { registrationExpiresAt: _previous, ...record } = client;
    if (ttl === void 0) {
      await env.OAUTH_KV.put(`client:${client.clientId}`, JSON.stringify(record));
      return;
    }
    await env.OAUTH_KV.put(`client:${client.clientId}`, JSON.stringify({
      ...record,
      registrationExpiresAt: now + ttl
    }), { expirationTtl: ttl });
  }
  /**
  * Renew a dynamically registered client whose registration has passed half of
  * `clientRegistrationTTL`, so a client still exchanging tokens does not vanish from
  * under its live grants. Without this, a grant that outlives its registration fails
  * every refresh with `invalid_client` although nothing was revoked. Only records
  * stamped with `registrationExpiresAt` qualify: CIMD clients are never stored,
  * `createClient()` records never expire, and a record from before the stamp existed
  * cannot be told from a permanent one, so it keeps its original schedule and
  * re-registers once. The half-life rule bounds this to one write per client per half
  * TTL. Best effort: the token response it follows has already been produced.
  *
  * KV has no compare-and-set, so a `deleteClient()` that lands between the read below and
  * the write is undone by it, as it would be by a concurrent `updateClient()`. The window
  * is one KV round trip, once per client per half TTL; closing it needs the serialised
  * storage of #237.
  */
  async renewClientRegistrationIfDue(env, client, now) {
    const ttl = this.options.clientRegistrationTTL;
    if (ttl === void 0 || client.registrationExpiresAt === void 0) return;
    if (client.registrationExpiresAt - now > ttl / 2) return;
    try {
      const current = await env.OAUTH_KV.get(`client:${client.clientId}`, { type: "json" });
      if (current) await this.putRegisteredClient(env, current, now);
    } catch (error) {
      console.warn(`Failed to renew client registration ${client.clientId}:`, error);
    }
  }
  async getClient(env, clientId) {
    if (isClientIdMetadataDocumentUrl(clientId)) {
      if (!this.options.clientIdMetadataDocumentEnabled) {
        const clientKey$1 = `client:${clientId}`;
        return env.OAUTH_KV.get(clientKey$1, { type: "json" });
      }
      if (!this.hasGlobalFetchStrictlyPublic()) throw new Error(`CIMD is enabled but 'global_fetch_strictly_public' compatibility flag is not set.`);
      try {
        return await fetchClientIdMetadataDocument(clientId, this.serverCapabilities);
      } catch (error) {
        console.warn(`CIMD fetch failed for ${clientId}:`, error instanceof Error ? error.message : error);
        throw new CimdFetchError(clientId, error);
      }
    }
    const clientKey = `client:${clientId}`;
    return env.OAUTH_KV.get(clientKey, { type: "json" });
  }
  /** Resolve a value to the registry's canonical spelling, requiring one value. */
  /**
  * Resolve a stored grant or token resource. A 0.x record may hold an array; it resolves
  * when exactly one configured resource appears in it, so multi-audience grants for two
  * resources this server still hosts are ambiguous and fail closed.
  */
  findStoredConfiguredResource(value) {
    if (!Array.isArray(value)) return this.findConfiguredResource(value);
    const matches = /* @__PURE__ */ new Set();
    for (const entry of value) {
      const configured = this.findConfiguredResource(entry);
      if (configured) matches.add(configured);
    }
    return matches.size === 1 ? [...matches][0] : void 0;
  }
  findConfiguredResource(value) {
    const distinct = Array.isArray(value) ? [...new Set(value)] : [value];
    const singular = distinct.length === 1 ? distinct[0] : void 0;
    if (typeof singular !== "string" || !validateResourceUri(singular)) return void 0;
    return this.resourceServers.map((server) => server.resourceMetadata.resource).find((configured) => isExactResource(singular, configured));
  }
  /**
  * Resolve a client-supplied RFC 8707 resource indicator to a configured resource.
  *
  * An exact match wins. Otherwise a request may name the URL it uses at the resource
  * when that URL differs from a configured resource only by query parameters the
  * configured resource does not constrain, such as `https://mcp.example.com/mcp?mode=x`
  * for `https://mcp.example.com/mcp`. The resource server already treats that URL as
  * covered by the resource (its 401 points at the resource's metadata, and the
  * resource's tokens are accepted there), and RFC 8707 §2.2 lets the authorization
  * server map a requested value to a more general resource. The audience stays the
  * configured resource, so the token is no broader. See {@link findCoveringResource}.
  * Only client requests use this; stored audiences and configuration stay exact.
  */
  findRequestedResource(value) {
    const exact = this.findConfiguredResource(value);
    if (exact) return exact;
    const distinct = Array.isArray(value) ? [...new Set(value)] : [value];
    const singular = distinct.length === 1 ? distinct[0] : void 0;
    if (typeof singular !== "string" || !validateResourceUri(singular)) return void 0;
    return findCoveringResource(singular, this.resourceServers.map((server) => server.resourceMetadata.resource));
  }
  /** Select the audience for a new interactive authorization. */
  resolveAuthorizationRequestResource(requestedResource) {
    if (requestedResource === void 0) {
      const defaultResource = this.getDefaultAuthorizationResource();
      if (defaultResource) return defaultResource;
      throw new AuthorizationError("invalid_target", { description: "The resource parameter is required when the authorization server has multiple resources" });
    }
    const configured = this.findRequestedResource(requestedResource);
    if (!configured) throw new AuthorizationError("invalid_target", { description: "The resource parameter must name exactly one configured protected resource" });
    return configured;
  }
  /** Whether an existing grant belongs to the replacement bucket for a resource. */
  shouldReplaceGrantForResource(grantResource, resource) {
    if (grantResource === void 0) return this.getLegacyGrantResource() === resource;
    return isExactResource(grantResource, resource);
  }
  /** Select the audience for a new non-interactive grant such as EMA. */
  resolveNewTokenResource(requestedResource) {
    try {
      return this.resolveAuthorizationRequestResource(requestedResource);
    } catch (error) {
      if (error instanceof AuthorizationError) throw new OAuthError("invalid_target", {
        description: error.description,
        internal: {
          category: "resource-indicator",
          reason: "resource_invalid",
          detail: error
        }
      });
      throw error;
    }
  }
  /** Validate explicit resource syntax and configured-resource policy. */
  validateTokenRequestResourceIndicator(requestedResource) {
    if (requestedResource === void 0) return;
    if (!this.findRequestedResource(requestedResource)) throw new OAuthError("invalid_target", {
      description: "The resource parameter must name exactly one configured protected resource",
      internal: {
        category: "resource-indicator",
        reason: "resource_not_configured"
      }
    });
  }
  /** Resolve token exchange strictly within the subject token's audience ceiling. */
  resolveTokenExchangeResource(requestedResource, subjectResource) {
    const subjectAudience = this.findStoredConfiguredResource(this.resolveStoredTokenAudience(subjectResource));
    if (!subjectAudience) throw new OAuthError("invalid_target", {
      description: "Subject token is not bound to a configured resource",
      internal: {
        category: "resource-indicator",
        reason: "subject_token_audience_unbound"
      }
    });
    const resourceWasProvided = requestedResource !== void 0;
    const requestedAudience = resourceWasProvided ? this.findRequestedResource(requestedResource) : void 0;
    if (resourceWasProvided && (!requestedAudience || requestedAudience !== subjectAudience)) throw new OAuthError("invalid_target", {
      description: "The requested resource must exactly match the subject token audience",
      internal: {
        category: "resource-indicator",
        reason: "resource_subject_token_mismatch"
      }
    });
    return subjectAudience;
  }
  /**
  * Resolves an access-token audience from a token request and its authorization grant.
  * The configured canonical resource is inherited when omitted and cannot be overridden.
  *
  * The grant is checked before the request. A grant bound to a resource the server no longer
  * hosts fails with `invalid_grant` even when the request names that resource, as a client
  * repeating its grant's resource on refresh does: the grant is the defect, and `invalid_grant`
  * makes conformant clients discard their tokens and re-authorize, where `invalid_target`
  * would make them fail.
  */
  resolveTokenResource(requestedResource, grant) {
    const grantedResource = grant.resource;
    const resourceWasProvided = requestedResource !== void 0;
    const canonicalRequestedResource = resourceWasProvided ? this.findRequestedResource(requestedResource) : void 0;
    const binding = this.resolveGrantBinding(grantedResource);
    if (resourceWasProvided && !canonicalRequestedResource) throw new OAuthError("invalid_target", {
      description: "The resource parameter must name exactly one configured protected resource",
      internal: {
        category: "resource-indicator",
        reason: "resource_not_configured"
      }
    });
    if (resourceWasProvided && canonicalRequestedResource !== binding.resource) throw binding.legacy ? new OAuthError("invalid_target", {
      description: "The requested resource does not match the server legacy-grant migration policy",
      internal: {
        category: "resource-indicator",
        reason: "legacy_grant_resource_mismatch"
      }
    }) : new OAuthError("invalid_target", {
      description: "The requested resource does not match the authorization grant",
      internal: {
        category: "resource-indicator",
        reason: "resource_grant_mismatch"
      }
    });
    return {
      audience: binding.resource,
      ...grantedResource === binding.resource ? {} : { grantResourceBackfill: binding.resource }
    };
  }
  /**
  * The configured resource a stored grant belongs to: the one it is bound to, or for a grant
  * stored with no resource, the legacy-grant migration resource. Throws `invalid_grant` when
  * there is none, since only re-authorization can repair the grant.
  */
  resolveGrantBinding(grantedResource) {
    if (grantedResource !== void 0) {
      const resource$1 = this.findStoredConfiguredResource(grantedResource);
      if (!resource$1) throw new OAuthError("invalid_grant", {
        description: "The authorization grant is bound to a resource this server no longer serves. Authorize again.",
        internal: {
          category: "resource-indicator",
          reason: "grant_audience_unbound"
        }
      });
      return {
        resource: resource$1,
        legacy: false
      };
    }
    const resource = this.getLegacyGrantResource();
    if (!resource) throw new OAuthError("invalid_grant", {
      description: "This legacy authorization grant has no resource binding and must be reauthorized",
      internal: {
        category: "resource-indicator",
        reason: "legacy_grant_unbound"
      }
    });
    return {
      resource,
      legacy: true
    };
  }
  /**
  * Creates and stores an access token
  * @param params - Options for creating the access token
  * @returns The access token string
  */
  async createAccessToken(params) {
    const { userId, grantId, clientId, scope, encryptedProps, encryptionKey, expiresIn, audience, env } = params;
    if (!isValidAccessTokenTTL(expiresIn)) throw new OAuthError("invalid_request", {
      description: "Requested token lifetime must be at least 60 seconds",
      internal: {
        category: "token-issuance",
        reason: "requested_ttl_too_short"
      }
    });
    const accessToken = `${userId}:${grantId}:${generateRandomString(TOKEN_LENGTH)}`;
    const now = Math.floor(Date.now() / 1e3);
    const accessTokenId = await generateTokenId(accessToken);
    const accessTokenData = {
      id: accessTokenId,
      grantId,
      userId,
      createdAt: now,
      expiresAt: now + expiresIn,
      audience,
      scope,
      wrappedEncryptionKey: await wrapKeyWithToken(accessToken, encryptionKey),
      grant: {
        clientId,
        scope,
        encryptedProps
      }
    };
    try {
      await env.OAUTH_KV.put(`token:${userId}:${grantId}:${accessTokenId}`, JSON.stringify(accessTokenData), { expirationTtl: expiresIn });
    } catch (error) {
      this.throwRetryableTokenStorageErrorIfKvRateLimited(error);
      throw error;
    }
    return accessToken;
  }
  /**
  * Restricts requested scopes to the scopes available for the current flow.
  * If no scope is requested, all available scopes are returned.
  * @param requestedScope - The scope parameter from the request (string or array)
  * @param allowedScopes - The maximum scopes available for the current flow
  * @returns The requested scopes that are included in the allowed scopes
  */
  downscope(requestedScope, allowedScopes) {
    if (!requestedScope) return allowedScopes;
    return (typeof requestedScope === "string" ? requestedScope.split(" ").filter(Boolean) : requestedScope).filter((scope) => allowedScopes.includes(scope));
  }
  /**
  * Checks if the global_fetch_strictly_public compatibility flag is enabled.
  * This flag is required for CIMD to prevent SSRF attacks.
  * See: https://developers.cloudflare.com/workers/configuration/compatibility-flags/#global-fetch-strictly-public
  */
  hasGlobalFetchStrictlyPublic() {
    return !!(typeof Cloudflare !== "undefined" && Cloudflare.compatibilityFlags ? Cloudflare.compatibilityFlags : null)?.global_fetch_strictly_public;
  }
  /**
  * Builds a WWW-Authenticate header value with resource_metadata per RFC 9728 §5.1
  */
  buildWwwAuthenticateHeader(resourceMetadataUrl, error, errorDescription, requiredScopes = [], resourceServer = this.resourceServers[0]) {
    let header = 'Bearer realm="OAuth"';
    if (resourceMetadataUrl) header += `, resource_metadata="${resourceMetadataUrl}"`;
    if (error) header += `, error="${error}"`;
    const challengeScopes = requiredScopes.length > 0 ? this.normalizeProtectedResourceScopes(requiredScopes) : this.getProtectedResourceScopes(resourceServer);
    if (challengeScopes.length > 0) header += `, scope="${challengeScopes.join(" ")}"`;
    if (errorDescription) header += `, error_description="${errorDescription}"`;
    return header;
  }
  /** Build the RFC 9728 well-known URL for the configured canonical resource. */
  getConfiguredResourceMetadataUrl(resource) {
    const authorityStart = resource.indexOf("://") + 3;
    const suffixOffset = resource.slice(authorityStart).search(/[/?]/);
    const suffixStart = suffixOffset === -1 ? resource.length : authorityStart + suffixOffset;
    let suffix = resource.slice(suffixStart);
    if (suffix === "/") suffix = "";
    if (suffix.startsWith("/?")) suffix = suffix.slice(1);
    return resource.slice(0, suffixStart) + PROTECTED_RESOURCE_WELL_KNOWN_PREFIX + suffix;
  }
  /**
  * RFC 9728 §3.3 requires metadata fetched from a challenge to identify the
  * original protected-resource URL. Descendant and alias routes can still use
  * a base audience, but must not advertise a document for a different URL.
  */
  getResourceMetadataUrlForRequest(requestUrl, resourceServer) {
    const configuredResource = resourceServer.resourceMetadata.resource;
    if (isExactResource(requestUrl.href, configuredResource)) return this.getConfiguredResourceMetadataUrl(configuredResource);
    const resourceUrl = new URL(configuredResource);
    if (requestUrl.origin === resourceUrl.origin && requestCarriesResourceQuery(requestUrl, resourceUrl) && isPathDescendant(requestUrl.pathname, resourceUrl.pathname)) return this.getConfiguredResourceMetadataUrl(configuredResource);
  }
  /**
  * Helper function to create OAuth error responses.
  *
  * `internal` (optional) carries a tagged, server-side-only reason. It is
  * forwarded to the deployer's `onError` hook but never placed on the wire,
  * so the public response stays RFC-compliant and free of information leak
  * while the deployer can still observe which check failed.
  */
  createErrorResponse(code, options, internal, request) {
    const { description } = options;
    const responseStatus = options.statusCode ?? 400;
    const responseHeaders = {
      ...NO_CACHE_HEADERS,
      ...options.headers ?? {}
    };
    const customErrorResponse = this.options.onError?.({
      code,
      description,
      status: responseStatus,
      headers: responseHeaders,
      internal,
      ...request ? { request } : {}
    });
    const body = JSON.stringify({
      error: code,
      error_description: description
    });
    const response = customErrorResponse ?? new Response(body, {
      status: responseStatus,
      headers: {
        "Content-Type": "application/json",
        ...responseHeaders
      }
    });
    this.errorResponses.add(response);
    return response;
  }
};
var ExternalTokenError = class extends Error {
  static {
    __name(this, "ExternalTokenError");
  }
  /**
  * Creates an intentional external-token validation error.
  * @param code - Standard OAuth error code to return
  * @param options - Public response details
  */
  constructor(code, options) {
    super(options.description);
    this.name = "ExternalTokenError";
    this.code = code;
    this.description = options.description;
    this.statusCode = options.statusCode;
    this.headers = options.headers;
    this.requiredScopes = options.requiredScopes;
  }
};
var CimdFetchError = class extends Error {
  static {
    __name(this, "CimdFetchError");
  }
  /**
  * Creates an error for a failed CIMD fetch or validation.
  * @param metadataUrl - The CIMD URL that could not be resolved
  * @param cause - The underlying fetch or validation failure
  */
  constructor(metadataUrl, cause) {
    const detail = cause instanceof Error ? cause.message : String(cause);
    super(`CIMD fetch failed for ${metadataUrl}: ${detail}`);
    this.reason = "metadata_resolution_failed";
    this.name = "CimdFetchError";
    this.metadataUrl = metadataUrl;
    this.detail = detail;
  }
};
var DEFAULT_ACCESS_TOKEN_TTL = 3600;
var DEFAULT_REFRESH_TOKEN_TTL = 720 * 60 * 60;
var DEFAULT_CLIENT_REGISTRATION_TTL = 2160 * 60 * 60;
var KV_MIN_EXPIRATION_TTL_SECONDS = 60;
function wouldRegisterPublicClient(clientMetadata, server) {
  if (!clientMetadata) return false;
  try {
    return resolveDynamicClientRegistrationMetadata(clientMetadata, server).tokenEndpointAuthMethod === "none";
  } catch {
    return false;
  }
}
__name(wouldRegisterPublicClient, "wouldRegisterPublicClient");
function withRequiredScopes(metadata, requiredScopes) {
  if (!metadata || typeof metadata !== "object") return metadata;
  const { scopes_supported: deprecated, ...rest } = metadata;
  const scopes = resolveRequiredScopes(requiredScopes, deprecated);
  return scopes === void 0 ? rest : {
    ...rest,
    scopes_supported: scopes
  };
}
__name(withRequiredScopes, "withRequiredScopes");
function isValidRefreshTokenTTL(ttl) {
  return ttl === 0 || isValidAccessTokenTTL(ttl);
}
__name(isValidRefreshTokenTTL, "isValidRefreshTokenTTL");
function parsePurgeCursor(cursor) {
  if (cursor === void 0) return { phase: "grants" };
  const separator = cursor.indexOf(":");
  const phase = cursor.slice(0, separator);
  if (separator < 0 || phase !== "grants" && phase !== "tokens") throw new TypeError("Invalid purgeExpiredData cursor");
  const kvCursor = cursor.slice(separator + 1);
  return kvCursor ? {
    phase,
    kvCursor
  } : { phase };
}
__name(parsePurgeCursor, "parsePurgeCursor");
function grantsNoneOfTheRequestedScopes(requested, granted) {
  return (typeof requested === "string" ? requested.split(" ").filter(Boolean) : requested ?? []).length > 0 && granted.length === 0;
}
__name(grantsNoneOfTheRequestedScopes, "grantsNoneOfTheRequestedScopes");
async function readTextWithLimit(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let total = 0;
  for (; ; ) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      reader.cancel().catch(() => void 0);
      return;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
__name(readTextWithLimit, "readTextWithLimit");
function isValidAccessTokenTTL(value) {
  return Number.isInteger(value) && value >= KV_MIN_EXPIRATION_TTL_SECONDS;
}
__name(isValidAccessTokenTTL, "isValidAccessTokenTTL");
var KV_EXPIRATION_CLAMP_MARGIN_SECONDS = 5;
var DEFAULT_PURGE_BATCH_SIZE = 50;
var MAX_KV_LIST_LIMIT = 1e3;
var DEFAULT_REVOKE_EXISTING_GRANTS_BATCH_SIZE = 50;
var MAX_KV_METADATA_BYTES = 1024;
function grantKeyMetadata(grant) {
  const metadata = { clientId: grant.clientId };
  if (grant.resource !== void 0) metadata.resource = grant.resource;
  if (grant.redirectUri !== void 0) metadata.redirectUri = grant.redirectUri;
  return new TextEncoder().encode(JSON.stringify(metadata)).byteLength <= MAX_KV_METADATA_BYTES ? metadata : void 0;
}
__name(grantKeyMetadata, "grantKeyMetadata");
function grantPutOptions(grant, expiry = {}) {
  const metadata = grantKeyMetadata(grant);
  return metadata ? {
    ...expiry,
    metadata
  } : expiry;
}
__name(grantPutOptions, "grantPutOptions");
function parseGrantKey(name) {
  const rest = name.slice(6);
  const separator = rest.lastIndexOf(":");
  if (!name.startsWith("grant:") || separator <= 0 || separator === rest.length - 1) return void 0;
  return {
    userId: rest.slice(0, separator),
    grantId: rest.slice(separator + 1)
  };
}
__name(parseGrantKey, "parseGrantKey");
function isGrantKeyMetadata(value) {
  if (typeof value !== "object" || value === null) return false;
  const { clientId, resource, redirectUri } = value;
  return typeof clientId === "string" && (resource === void 0 || typeof resource === "string" || Array.isArray(resource)) && (redirectUri === void 0 || typeof redirectUri === "string");
}
__name(isGrantKeyMetadata, "isGrantKeyMetadata");
var TOKEN_LENGTH = 32;
var ISSUED_GRANT_ID_PATTERN = /^[A-Za-z0-9_-]{16}$/;
var ISSUED_TOKEN_SECRET_PATTERN = /* @__PURE__ */ new RegExp(`^[A-Za-z0-9_-]{${TOKEN_LENGTH}}$`);
function audienceMatches(resourceServerUrl, audienceValue) {
  try {
    const resource = new URL(resourceServerUrl);
    const audience = new URL(audienceValue);
    if (resource.origin !== audience.origin) return false;
    if (!requestCarriesResourceQuery(resource, audience)) return false;
    if (audience.pathname === "/" || audience.pathname === "") return true;
    const descendantPrefix = audience.pathname.endsWith("/") ? audience.pathname : audience.pathname + "/";
    return resource.pathname === audience.pathname || resource.pathname.startsWith(descendantPrefix);
  } catch {
    return false;
  }
}
__name(audienceMatches, "audienceMatches");
function isExactResource(value, configuredResource) {
  if (Array.isArray(value)) return value.some((entry) => typeof entry === "string" && resourceMatches(entry, configuredResource));
  return typeof value === "string" && resourceMatches(value, configuredResource);
}
__name(isExactResource, "isExactResource");
function withoutBodyForHead(request, response) {
  if (request.method !== "HEAD") return response;
  return new Response(null, {
    status: response.status,
    headers: response.headers
  });
}
__name(withoutBodyForHead, "withoutBodyForHead");
function isPathDescendant(candidate, base) {
  if (base === "" || base === "/") return true;
  if (base.endsWith("/")) return candidate.startsWith(base);
  return candidate === base || candidate.startsWith(`${base}/`);
}
__name(isPathDescendant, "isPathDescendant");
async function hashSecret(secret) {
  return generateTokenId(secret);
}
__name(hashSecret, "hashSecret");
function parseBasicAuthorizationHeader(header) {
  if (!header) return { kind: "not-basic" };
  const schemeEnd = header.search(/[ \t]/);
  if ((schemeEnd === -1 ? header : header.slice(0, schemeEnd)).toLowerCase() !== "basic") return { kind: "not-basic" };
  if (schemeEnd === -1) return { kind: "malformed" };
  const encodedCredentials = header.slice(schemeEnd).trim();
  if (!encodedCredentials || /[ \t]/.test(encodedCredentials)) return { kind: "malformed" };
  try {
    const credentials = atob(encodedCredentials);
    const separatorIndex = credentials.indexOf(":");
    if (separatorIndex === -1) return { kind: "malformed" };
    return {
      kind: "credentials",
      clientId: decodeFormUrlEncodedComponent(credentials.slice(0, separatorIndex)),
      clientSecret: decodeFormUrlEncodedComponent(credentials.slice(separatorIndex + 1))
    };
  } catch {
    return { kind: "malformed" };
  }
}
__name(parseBasicAuthorizationHeader, "parseBasicAuthorizationHeader");
function decodeFormUrlEncodedComponent(value) {
  return decodeURIComponent(value.replace(/\+/g, " "));
}
__name(decodeFormUrlEncodedComponent, "decodeFormUrlEncodedComponent");
function isIssuedTokenFormat(token) {
  const parts = token.split(":");
  if (parts.length < 3) return false;
  const secret = parts[parts.length - 1];
  const grantId = parts[parts.length - 2];
  return parts.slice(0, -2).join(":").length > 0 && ISSUED_GRANT_ID_PATTERN.test(grantId) && ISSUED_TOKEN_SECRET_PATTERN.test(secret);
}
__name(isIssuedTokenFormat, "isIssuedTokenFormat");
function generateRandomString(length) {
  const characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let result = "";
  const values = new Uint8Array(length);
  crypto.getRandomValues(values);
  for (let i = 0; i < length; i++) result += characters.charAt(values[i] % 64);
  return result;
}
__name(generateRandomString, "generateRandomString");
async function generateTokenId(token) {
  const data = new TextEncoder().encode(token);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(generateTokenId, "generateTokenId");
function isLoopbackUri(uri) {
  try {
    return isLoopbackHostname(new URL(uri).hostname);
  } catch {
    return false;
  }
}
__name(isLoopbackUri, "isLoopbackUri");
function isValidRedirectUri(requestUri, registeredUris) {
  return registeredUris.some((registered) => {
    if (isLoopbackUri(requestUri) && isLoopbackUri(registered)) try {
      const reqUrl = new URL(requestUri);
      const regUrl = new URL(registered);
      return reqUrl.protocol === regUrl.protocol && reqUrl.hostname === regUrl.hostname && reqUrl.pathname === regUrl.pathname && reqUrl.search === regUrl.search;
    } catch {
      return false;
    }
    return requestUri === registered;
  });
}
__name(isValidRedirectUri, "isValidRedirectUri");
function base64UrlEncode(str) {
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
__name(base64UrlEncode, "base64UrlEncode");
function arrayBufferToBase64(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)));
}
__name(arrayBufferToBase64, "arrayBufferToBase64");
function base64ToArrayBuffer(base64) {
  const binaryString = atob(base64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) bytes[i] = binaryString.charCodeAt(i);
  return bytes.buffer;
}
__name(base64ToArrayBuffer, "base64ToArrayBuffer");
async function encryptProps(data) {
  const key = await crypto.subtle.generateKey({
    name: "AES-GCM",
    length: 256
  }, true, ["encrypt", "decrypt"]);
  const iv = new Uint8Array(12);
  const jsonData = JSON.stringify(data);
  const encodedData = new TextEncoder().encode(jsonData);
  return {
    encryptedData: arrayBufferToBase64(await crypto.subtle.encrypt({
      name: "AES-GCM",
      iv
    }, key, encodedData)),
    key
  };
}
__name(encryptProps, "encryptProps");
async function decryptProps(key, encryptedData) {
  const encryptedBuffer = base64ToArrayBuffer(encryptedData);
  const iv = new Uint8Array(12);
  const decryptedBuffer = await crypto.subtle.decrypt({
    name: "AES-GCM",
    iv
  }, key, encryptedBuffer);
  const jsonData = new TextDecoder().decode(decryptedBuffer);
  return JSON.parse(jsonData);
}
__name(decryptProps, "decryptProps");
var WRAPPING_KEY_HMAC_KEY = new Uint8Array([
  34,
  126,
  38,
  134,
  141,
  241,
  225,
  109,
  128,
  112,
  234,
  23,
  151,
  91,
  71,
  166,
  130,
  24,
  250,
  135,
  40,
  174,
  222,
  133,
  181,
  29,
  74,
  217,
  150,
  202,
  202,
  67
]);
async function deriveKeyFromToken(tokenStr) {
  const encoder2 = new TextEncoder();
  const hmacKey$1 = await crypto.subtle.importKey("raw", WRAPPING_KEY_HMAC_KEY, {
    name: "HMAC",
    hash: "SHA-256"
  }, false, ["sign"]);
  const hmacResult = await crypto.subtle.sign("HMAC", hmacKey$1, encoder2.encode(tokenStr));
  return await crypto.subtle.importKey("raw", hmacResult, { name: "AES-KW" }, false, ["wrapKey", "unwrapKey"]);
}
__name(deriveKeyFromToken, "deriveKeyFromToken");
async function wrapKeyWithToken(tokenStr, keyToWrap) {
  const wrappingKey = await deriveKeyFromToken(tokenStr);
  return arrayBufferToBase64(await crypto.subtle.wrapKey("raw", keyToWrap, wrappingKey, { name: "AES-KW" }));
}
__name(wrapKeyWithToken, "wrapKeyWithToken");
async function unwrapKeyWithToken(tokenStr, wrappedKeyBase64) {
  const wrappingKey = await deriveKeyFromToken(tokenStr);
  const wrappedKeyBuffer = base64ToArrayBuffer(wrappedKeyBase64);
  return await crypto.subtle.unwrapKey("raw", wrappedKeyBuffer, wrappingKey, { name: "AES-KW" }, { name: "AES-GCM" }, true, ["encrypt", "decrypt"]);
}
__name(unwrapKeyWithToken, "unwrapKeyWithToken");
var OAuthHelpersImpl = class {
  static {
    __name(this, "OAuthHelpersImpl");
  }
  /**
  * Creates a new OAuthHelpers instance
  * @param env - Cloudflare Worker environment variables
  * @param provider - Reference to the parent provider instance
  */
  constructor(env, provider) {
    this.env = env;
    this.provider = provider;
  }
  /**
  * Parses an OAuth authorization request from the HTTP request
  * @param request - The HTTP request containing OAuth parameters
  * @returns The parsed authorization request parameters
  * @throws AuthorizationError for expected authorization-request validation failures
  * @throws CimdFetchError when the client ID is a CIMD URL whose document cannot be resolved
  */
  async parseAuthRequest(request) {
    const url = new URL(request.url);
    if (this.provider.hasExplicitIssuer && !this.provider.isAuthorizationEndpointRequest(url)) throw new AuthorizationError("invalid_request", { description: "Authorization request was sent to an unconfigured endpoint" });
    const responseType = url.searchParams.get("response_type") || "";
    const clientId = url.searchParams.get("client_id") || "";
    const redirectUri = url.searchParams.get("redirect_uri") || "";
    const scope = (url.searchParams.get("scope") || "").split(" ").filter(Boolean);
    const state = url.searchParams.get("state") || "";
    const codeChallenge = url.searchParams.get("code_challenge") || void 0;
    const codeChallengeMethod = url.searchParams.get("code_challenge_method") || void 0;
    const issuer = this.provider.getAuthorizationServerIssuer(url);
    const resourceParams = url.searchParams.getAll("resource");
    const resourceParam = resourceParams.length > 0 ? resourceParams.length === 1 ? resourceParams[0] : resourceParams : void 0;
    if (!clientId) throw new AuthorizationError("invalid_request", { description: "client_id is required" });
    const clientInfo = await this.lookupClient(clientId);
    if (!clientInfo) throw new AuthorizationError("invalid_request", { description: "Invalid client_id" });
    try {
      validateRedirectUri(redirectUri, this.provider.serverCapabilities);
    } catch {
      throw new AuthorizationError("invalid_request", { description: "Invalid redirect URI" });
    }
    if (!redirectUri || !isValidRedirectUri(redirectUri, clientInfo.redirectUris)) throw new AuthorizationError("invalid_request", { description: "Invalid redirect URI" });
    const withRedirect = /* @__PURE__ */ __name((error) => {
      throw withAuthorizationRedirect(error, redirectUri, state || void 0, issuer);
    }, "withRedirect");
    let resource;
    try {
      resource = this.provider.resolveAuthorizationRequestResource(resourceParam);
    } catch (error) {
      if (error instanceof AuthorizationError) withRedirect(error);
      throw error;
    }
    try {
      validateAuthorizationResponseType(this.provider.serverCapabilities, responseType, clientInfo.responseTypes);
      validateAuthorizationPkce(this.provider.serverCapabilities, {
        responseType,
        codeChallenge,
        codeChallengeMethod
      }, clientInfo);
    } catch (error) {
      if (error instanceof AuthorizationError) withRedirect(error);
      throw error;
    }
    return {
      responseType,
      clientId,
      redirectUri,
      scope,
      state,
      codeChallenge,
      codeChallengeMethod,
      resource,
      issuer
    };
  }
  /**
  * Looks up a client by its client ID
  * @param clientId - The client ID to look up
  * @returns A Promise resolving to the client info, or null if the client does not
  * exist. Null means definitive absence; failures to determine the answer throw
  * instead (KV errors propagate, and a CIMD metadata fetch failure throws
  * `CimdFetchError`), so an upstream outage cannot masquerade as an unregistered
  * client.
  * @throws CimdFetchError when the client ID is a CIMD URL and fetching or
  * validating the metadata document fails.
  */
  async lookupClient(clientId) {
    const client = await this.provider.getClient(this.env, clientId);
    return client ? toPublicClientInfo(client) : null;
  }
  /**
  * Completes an authorization request by creating a grant and an authorization code.
  * @param options - Options specifying the grant details
  * @returns A Promise resolving to an object containing the redirect URL
  * @throws Error when the request's response type is not permitted
  * @throws CimdFetchError when the client ID is a CIMD URL whose document cannot be resolved
  */
  async completeAuthorization(options) {
    const { clientId, redirectUri } = options.request;
    if (!clientId || !redirectUri) throw new Error("Client ID and Redirect URI are required in the authorization request.");
    if (typeof options.userId !== "string" || options.userId.length === 0 || options.userId.includes(":")) throw new TypeError('userId must be a non-empty string without ":"');
    const clientInfo = await this.lookupClient(clientId);
    if (!clientInfo || !isValidRedirectUri(redirectUri, clientInfo.redirectUris)) throw new Error("Invalid redirect URI. The redirect URI provided does not match any registered URI for this client.");
    try {
      validateRedirectUri(redirectUri, this.provider.serverCapabilities);
    } catch {
      throw new AuthorizationError("invalid_request", { description: "Invalid redirect URI" });
    }
    validateAuthorizationResponseType(this.provider.serverCapabilities, options.request.responseType, clientInfo.responseTypes);
    const effectiveResource = this.provider.resolveAuthorizationRequestResource(options.request.resource);
    validateAuthorizationPkce(this.provider.serverCapabilities, options.request, clientInfo);
    let grantsToRevoke = [];
    if (options.revokeExistingGrants !== false) {
      const isCimdClient = isClientIdMetadataDocumentUrl(clientId);
      const readConcurrency = DEFAULT_REVOKE_EXISTING_GRANTS_BATCH_SIZE;
      grantsToRevoke = await this.findGrantIds(options.userId, (grant$1) => grant$1.clientId === clientId && (!isCimdClient || grant$1.redirectUri === options.request.redirectUri) && this.provider.shouldReplaceGrantForResource(grant$1.resource, effectiveResource), readConcurrency);
    }
    const grantId = generateRandomString(16);
    const { encryptedData, key: encryptionKey } = await encryptProps(options.props);
    const now = Math.floor(Date.now() / 1e3);
    const authCodeSecret = generateRandomString(32);
    const authCode = `${options.userId}:${grantId}:${authCodeSecret}`;
    const authCodeId = await hashSecret(authCode);
    const authCodeWrappedKey = await wrapKeyWithToken(authCode, encryptionKey);
    const grant = {
      id: grantId,
      clientId: options.request.clientId,
      userId: options.userId,
      scope: options.scope,
      metadata: options.metadata,
      encryptedProps: encryptedData,
      createdAt: now,
      authCodeId,
      authCodeWrappedKey,
      codeChallenge: options.request.codeChallenge,
      codeChallengeMethod: options.request.codeChallengeMethod,
      resource: effectiveResource,
      redirectUri: options.request.redirectUri
    };
    const grantKey = `grant:${options.userId}:${grantId}`;
    await this.env.OAUTH_KV.put(grantKey, JSON.stringify(grant), grantPutOptions(grant, { expirationTtl: 600 }));
    const redirectUrl = new URL(options.request.redirectUri);
    redirectUrl.searchParams.set("code", authCode);
    if (options.request.state) redirectUrl.searchParams.set("state", options.request.state);
    if (options.request.issuer) redirectUrl.searchParams.set("iss", options.request.issuer);
    try {
      await Promise.allSettled(grantsToRevoke.map((oldGrantId) => this.revokeGrant(oldGrantId, options.userId)));
    } catch {
    }
    return { redirectTo: redirectUrl.toString() };
  }
  /**
  * IDs of the user's grants that satisfy `matches`, judged from KV key metadata
  * wherever a grant carries it. Only grants written without metadata, by a version
  * before 1.0 or because theirs would not fit, are read, `readConcurrency` at a time.
  *
  * This runs on the interactive authorization path, where the pre-metadata cost of one
  * `get()` per grant broke re-authorization for a user with more grants than a Worker
  * has subrequests. The cost is now one `list()` per thousand grants plus one `get()`
  * per legacy grant, and every refresh rewrites its grant with metadata, so the legacy
  * share shrinks on its own.
  */
  async findGrantIds(userId, matches, readConcurrency) {
    const grantIds = [];
    for await (const grants of this.findGrants(userId, matches, readConcurrency)) grantIds.push(...grants.map((grant) => grant.grantId));
    return grantIds;
  }
  /**
  * Finds grants matching `matches`, for one user or, with `userId` undefined, for every user.
  * Metadata-carrying keys are matched without a read; legacy grants are read,
  * `readConcurrency` at a time. Matches are yielded as they are found (each page's metadata
  * matches, then each batch of reads), so a caller can act on them before the scan goes on.
  */
  async *findGrants(userId, matches, readConcurrency) {
    const prefix = userId === void 0 ? "grant:" : `grant:${userId}:`;
    let cursor;
    do {
      const page2 = await this.env.OAUTH_KV.list({
        prefix,
        limit: MAX_KV_LIST_LIMIT,
        cursor
      });
      const toRead = [];
      const found = [];
      for (const key of page2.keys) {
        const owner = parseGrantKey(key.name);
        if (!owner || userId !== void 0 && owner.userId !== userId) continue;
        if (isGrantKeyMetadata(key.metadata)) {
          if (matches(key.metadata)) found.push(owner);
        } else toRead.push({
          name: key.name,
          ...owner
        });
      }
      if (found.length > 0) yield found;
      for (let start = 0; start < toRead.length; start += readConcurrency) {
        const batch = toRead.slice(start, start + readConcurrency);
        const grants = await Promise.all(batch.map(({ name }) => this.env.OAUTH_KV.get(name, { type: "json" })));
        const read = batch.filter((_, index) => {
          const grant = grants[index];
          return grant !== null && matches(grant);
        });
        if (read.length > 0) yield read.map(({ userId: userId$1, grantId }) => ({
          userId: userId$1,
          grantId
        }));
      }
      cursor = page2.list_complete ? void 0 : page2.cursor;
    } while (cursor);
  }
  /**
  * Creates a new OAuth client
  * @param clientInfo - Partial client information to create the client with
  * @returns A Promise resolving to the created client info
  */
  async createClient(clientInfo) {
    const clientId = generateRandomString(16);
    const authMethodWasExplicit = clientInfo.tokenEndpointAuthMethod !== void 0;
    const tokenEndpointAuthMethod = clientInfo.tokenEndpointAuthMethod || "client_secret_basic";
    const isPublicClient = tokenEndpointAuthMethod === "none";
    const newClient = {
      clientId,
      redirectUris: clientInfo.redirectUris || [],
      clientName: clientInfo.clientName,
      logoUri: clientInfo.logoUri,
      clientUri: clientInfo.clientUri,
      policyUri: clientInfo.policyUri,
      tosUri: clientInfo.tosUri,
      jwksUri: clientInfo.jwksUri,
      i18n: clientInfo.i18n,
      contacts: clientInfo.contacts,
      grantTypes: clientInfo.grantTypes || [
        GrantType.AUTHORIZATION_CODE,
        GrantType.REFRESH_TOKEN,
        ...this.provider.options.allowTokenExchangeGrant ? [GrantType.TOKEN_EXCHANGE] : []
      ],
      responseTypes: clientInfo.responseTypes || ["code"],
      registrationDate: Math.floor(Date.now() / 1e3),
      tokenEndpointAuthMethod,
      ...authMethodWasExplicit ? { authMethodExplicit: true } : {}
    };
    validateRegisteredRedirectUris(newClient.redirectUris, this.provider.serverCapabilities);
    validateClientCapabilities(this.provider.serverCapabilities, {
      grantTypes: newClient.grantTypes,
      responseTypes: newClient.responseTypes,
      tokenEndpointAuthMethod
    });
    let clientSecret;
    if (!isPublicClient) {
      clientSecret = generateRandomString(32);
      newClient.clientSecret = await hashSecret(clientSecret);
    }
    await this.env.OAUTH_KV.put(`client:${clientId}`, JSON.stringify(newClient));
    const clientResponse = toPublicClientInfo(newClient);
    if (!isPublicClient && clientSecret) clientResponse.clientSecret = clientSecret;
    return clientResponse;
  }
  /**
  * Lists all registered OAuth clients with pagination support
  * @param options - Optional pagination parameters (limit and cursor)
  * @returns A Promise resolving to the list result with items and optional cursor
  */
  async listClients(options) {
    const listOptions = { prefix: "client:" };
    if (options?.limit !== void 0) listOptions.limit = options.limit;
    if (options?.cursor !== void 0) listOptions.cursor = options.cursor;
    const response = await this.env.OAUTH_KV.list(listOptions);
    const clients = [];
    const promises = response.keys.map(async (key) => {
      const clientId = key.name.substring(7);
      const client = await this.provider.getClient(this.env, clientId);
      if (client) clients.push(toPublicClientInfo(client));
    });
    await Promise.all(promises);
    return {
      items: clients,
      cursor: response.list_complete ? void 0 : response.cursor
    };
  }
  /**
  * Updates an existing OAuth client
  * @param clientId - The ID of the client to update
  * @param updates - Partial client information with fields to update
  * @returns A Promise resolving to the updated client info, or null if not found
  */
  async updateClient(clientId, updates) {
    if (this.provider.options.clientIdMetadataDocumentEnabled && isClientIdMetadataDocumentUrl(clientId)) throw new TypeError("Client ID Metadata Document clients are updated by changing their document");
    const client = await this.provider.getClient(this.env, clientId);
    if (!client) return null;
    if (updates.redirectUris !== void 0) {
      if (!Array.isArray(updates.redirectUris) || updates.redirectUris.length === 0) throw new Error("redirectUris must not be empty");
      validateRegisteredRedirectUris(updates.redirectUris, this.provider.serverCapabilities);
    }
    const authMethodWasExplicit = updates.tokenEndpointAuthMethod !== void 0;
    const authMethod = updates.tokenEndpointAuthMethod || client.tokenEndpointAuthMethod || "client_secret_basic";
    const isPublicClient = authMethod === "none";
    let secretToStore = client.clientSecret;
    let originalSecret = void 0;
    if (isPublicClient) secretToStore = void 0;
    else if (updates.clientSecret) {
      originalSecret = updates.clientSecret;
      secretToStore = await hashSecret(updates.clientSecret);
    }
    const updatedClient = {
      ...client,
      ...updates,
      clientId: client.clientId,
      tokenEndpointAuthMethod: authMethod,
      authMethodExplicit: authMethodWasExplicit ? true : client.authMethodExplicit
    };
    if (updates.grantTypes !== void 0 || updates.responseTypes !== void 0 || updates.tokenEndpointAuthMethod !== void 0) validateClientCapabilities(this.provider.serverCapabilities, {
      grantTypes: updatedClient.grantTypes ?? [GrantType.AUTHORIZATION_CODE, GrantType.REFRESH_TOKEN],
      responseTypes: updatedClient.responseTypes ?? ["code"],
      tokenEndpointAuthMethod: authMethod
    });
    if (!isPublicClient && secretToStore) updatedClient.clientSecret = secretToStore;
    else delete updatedClient.clientSecret;
    if (client.registrationExpiresAt === void 0) await this.env.OAUTH_KV.put(`client:${updatedClient.clientId}`, JSON.stringify(updatedClient));
    else await this.provider.putRegisteredClient(this.env, updatedClient, Math.floor(Date.now() / 1e3));
    const response = toPublicClientInfo(updatedClient);
    if (!isPublicClient && originalSecret) response.clientSecret = originalSecret;
    return response;
  }
  /**
  * Deletes an OAuth client and revokes all associated grants across all users.
  * @param clientId - The ID of the client to delete
  * @returns A Promise resolving when the deletion is confirmed.
  */
  async deleteClient(clientId) {
    await this.env.OAUTH_KV.delete(`client:${clientId}`);
    const grants = this.findGrants(void 0, (grant) => grant.clientId === clientId, DEFAULT_REVOKE_EXISTING_GRANTS_BATCH_SIZE);
    for await (const found of grants) for (const { userId, grantId } of found) await this.revokeGrant(grantId, userId);
  }
  /**
  * Lists all authorization grants for a specific user with pagination support
  * Returns a summary of each grant without sensitive information
  * @param userId - The ID of the user whose grants to list
  * @param options - Optional pagination parameters (limit and cursor)
  * @returns A Promise resolving to the list result with grant summaries and optional cursor
  */
  async listUserGrants(userId, options) {
    const listOptions = { prefix: `grant:${userId}:` };
    if (options?.limit !== void 0) listOptions.limit = options.limit;
    if (options?.cursor !== void 0) listOptions.cursor = options.cursor;
    const isOwn = /* @__PURE__ */ __name((key) => !key.name.slice(listOptions.prefix.length).includes(":"), "isOwn");
    let response = await this.env.OAUTH_KV.list(listOptions);
    let ownKeys = response.keys.filter(isOwn);
    while (ownKeys.length === 0 && !response.list_complete) {
      response = await this.env.OAUTH_KV.list({
        ...listOptions,
        cursor: response.cursor
      });
      ownKeys = response.keys.filter(isOwn);
    }
    const grantSummaries = [];
    const promises = ownKeys.map(async (key) => {
      const grantData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
      if (grantData) {
        const summary = {
          id: grantData.id,
          clientId: grantData.clientId,
          userId: grantData.userId,
          scope: grantData.scope,
          metadata: grantData.metadata,
          createdAt: grantData.createdAt,
          expiresAt: grantData.expiresAt,
          redirectUri: grantData.redirectUri,
          resource: grantData.resource
        };
        grantSummaries.push(summary);
      }
    });
    await Promise.all(promises);
    return {
      items: grantSummaries,
      cursor: response.list_complete ? void 0 : response.cursor
    };
  }
  /**
  * Revokes an authorization grant and all its associated access tokens
  * @param grantId - The ID of the grant to revoke
  * @param userId - The ID of the user who owns the grant
  * @returns A Promise resolving when the revocation is confirmed.
  */
  /** {@inheritDoc OAuthHelpers.describeConsent} */
  async describeConsent(authRequest) {
    const client = await this.lookupClient(authRequest.clientId);
    const isCimd = !!this.provider.options.clientIdMetadataDocumentEnabled && isClientIdMetadataDocumentUrl(authRequest.clientId);
    return describeConsent(client, authRequest, isCimd);
  }
  /** {@inheritDoc OAuthHelpers.isConsentRemembered} */
  isConsentRemembered(request, authRequest, remember) {
    return isConsentRemembered(this.provider.consentCookies, request, authRequest, remember);
  }
  /** {@inheritDoc OAuthHelpers.beginConsent} */
  beginConsent(authRequest) {
    return beginConsent(this.env.OAUTH_KV, this.provider.consentCookies, authRequest);
  }
  /** {@inheritDoc OAuthHelpers.approveConsent} */
  approveConsent(request, handle, options) {
    return approveConsent(this.env.OAUTH_KV, this.provider.consentCookies, this.provider.options.scopesSupported, request, handle, options);
  }
  /** {@inheritDoc OAuthHelpers.denyConsent} */
  denyConsent(request, handle, options) {
    return denyConsent(this.env.OAUTH_KV, this.provider.consentCookies, request, handle, options);
  }
  /** {@inheritDoc OAuthHelpers.beginUpstream} */
  beginUpstream(authRequest, options) {
    return beginUpstream(this.env.OAUTH_KV, this.provider.consentCookies, authRequest, options);
  }
  /** {@inheritDoc OAuthHelpers.finishUpstream} */
  finishUpstream(request) {
    return finishUpstream(this.env.OAUTH_KV, this.provider.consentCookies, request);
  }
  async revokeGrant(grantId, userId) {
    const grantKey = `grant:${userId}:${grantId}`;
    const tokenPrefix = `token:${userId}:${grantId}:`;
    let cursor;
    let allTokensDeleted = false;
    while (!allTokensDeleted) {
      const listOptions = { prefix: tokenPrefix };
      if (cursor) listOptions.cursor = cursor;
      const result = await this.env.OAUTH_KV.list(listOptions);
      if (result.keys.length > 0) await Promise.all(result.keys.map((key) => {
        return this.env.OAUTH_KV.delete(key.name);
      }));
      if (result.list_complete) allTokensDeleted = true;
      else cursor = result.cursor;
    }
    await this.env.OAUTH_KV.delete(grantKey);
  }
  /**
  * Decodes a token and returns token data with decrypted props
  * @param token - The token
  * @returns Promise resolving to token data with decrypted props, or null if token is invalid
  */
  async unwrapToken(token) {
    return await this.provider.unwrapToken(token, this.env);
  }
  /**
  * Exchanges an existing access token for a new one with modified characteristics
  * Implements OAuth 2.0 Token Exchange (RFC 8693)
  * @param options - Options for token exchange including subject token and optional modifications
  * @returns Promise resolving to token response with new access token
  * @throws CimdFetchError when the grant's client ID is a CIMD URL whose document cannot be resolved
  */
  async exchangeToken(options) {
    const tokenSummary = await this.unwrapToken(options.subjectToken);
    if (!tokenSummary) throw new Error("Invalid or expired subject token");
    const clientInfo = await this.lookupClient(tokenSummary.grant.clientId);
    if (!clientInfo) throw new Error("Client not found");
    return await this.provider.exchangeToken(options.subjectToken, options.scope, options.aud, options.expiresIn, clientInfo, this.env);
  }
  async purgeExpiredData(options) {
    const batchSize = options?.batchSize ?? DEFAULT_PURGE_BATCH_SIZE;
    const purgeOrphanedGrants = options?.purgeOrphanedGrants !== false;
    const purgeExpiredGrants = options?.purgeExpiredGrants !== false;
    const purgeOrphanedTokens = options?.purgeOrphanedTokens !== false;
    const start = parsePurgeCursor(options?.cursor);
    const now = Math.floor(Date.now() / 1e3);
    const result = {
      grantsChecked: 0,
      grantsPurged: 0,
      tokensChecked: 0,
      tokensPurged: 0,
      done: false
    };
    if (start.phase === "grants" && (purgeOrphanedGrants || purgeExpiredGrants)) {
      const knownGoodClients = /* @__PURE__ */ new Set();
      const knownMissingClients = /* @__PURE__ */ new Set();
      let grantCursor = start.kvCursor;
      let grantsDone = false;
      while (!grantsDone && result.grantsChecked < batchSize) {
        const listOptions = {
          prefix: "grant:",
          limit: Math.min(1e3, batchSize - result.grantsChecked)
        };
        if (grantCursor) listOptions.cursor = grantCursor;
        const page2 = await this.env.OAUTH_KV.list(listOptions);
        for (const key of page2.keys) {
          if (result.grantsChecked >= batchSize) break;
          result.grantsChecked++;
          const grantData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
          if (!grantData) continue;
          let shouldPurge = false;
          if (purgeExpiredGrants && grantData.expiresAt !== void 0 && now >= grantData.expiresAt) shouldPurge = true;
          if (!shouldPurge && purgeOrphanedGrants && !isClientIdMetadataDocumentUrl(grantData.clientId)) {
            if (knownMissingClients.has(grantData.clientId)) shouldPurge = true;
            else if (!knownGoodClients.has(grantData.clientId)) if (await this.env.OAUTH_KV.get(`client:${grantData.clientId}`, { type: "json" })) knownGoodClients.add(grantData.clientId);
            else {
              knownMissingClients.add(grantData.clientId);
              shouldPurge = true;
            }
          }
          if (shouldPurge) {
            await this.revokeGrant(grantData.id, grantData.userId);
            result.grantsPurged++;
          }
        }
        if (page2.list_complete) grantsDone = true;
        else grantCursor = page2.cursor;
      }
      if (!grantsDone) return {
        ...result,
        cursor: `grants:${grantCursor ?? ""}`
      };
    }
    if (purgeOrphanedTokens) {
      const knownGoodGrants = /* @__PURE__ */ new Set();
      const knownMissingGrants = /* @__PURE__ */ new Set();
      let tokenCursor = start.phase === "tokens" ? start.kvCursor : void 0;
      let tokensDone = false;
      while (!tokensDone && result.tokensChecked < batchSize) {
        const listOptions = {
          prefix: "token:",
          limit: Math.min(1e3, batchSize - result.tokensChecked)
        };
        if (tokenCursor) listOptions.cursor = tokenCursor;
        const page2 = await this.env.OAUTH_KV.list(listOptions);
        for (const key of page2.keys) {
          if (result.tokensChecked >= batchSize) break;
          result.tokensChecked++;
          const tokenData = await this.env.OAUTH_KV.get(key.name, { type: "json" });
          if (!tokenData) continue;
          const grantKey = `grant:${tokenData.userId}:${tokenData.grantId}`;
          if (knownMissingGrants.has(grantKey)) {
            await this.env.OAUTH_KV.delete(key.name);
            result.tokensPurged++;
          } else if (!knownGoodGrants.has(grantKey)) if (await this.env.OAUTH_KV.get(grantKey)) knownGoodGrants.add(grantKey);
          else {
            knownMissingGrants.add(grantKey);
            await this.env.OAUTH_KV.delete(key.name);
            result.tokensPurged++;
          }
        }
        if (page2.list_complete) tokensDone = true;
        else tokenCursor = page2.cursor;
      }
      if (!tokensDone) return {
        ...result,
        cursor: `tokens:${tokenCursor ?? ""}`
      };
    }
    result.done = true;
    return result;
  }
};

// src/auth.ts
var encoder = new TextEncoder();
var SESSION_COOKIE = "minirun_session";
var SESSION_DAYS = 30;
async function sha256(text) {
  return crypto.subtle.digest("SHA-256", encoder.encode(text));
}
__name(sha256, "sha256");
async function safeEqual(a, b) {
  const [ha, hb] = await Promise.all([sha256(a), sha256(b)]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}
__name(safeEqual, "safeEqual");
async function checkPassword(given, expected) {
  if (!expected || !given) return false;
  return safeEqual(given, expected);
}
__name(checkPassword, "checkPassword");
function bearer(request) {
  const header = request.headers.get("Authorization");
  if (header?.startsWith("Bearer ")) return header.slice(7).trim();
  return null;
}
__name(bearer, "bearer");
async function hmacKey2(secret) {
  return crypto.subtle.importKey("raw", encoder.encode("minirun-session:" + secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify"
  ]);
}
__name(hmacKey2, "hmacKey");
function toHex(buffer) {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
__name(toHex, "toHex");
function fromHex(hex) {
  if (!/^[0-9a-f]+$/.test(hex) || hex.length % 2) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}
__name(fromHex, "fromHex");
async function createSession(secret) {
  const expires = Math.floor(Date.now() / 1e3) + SESSION_DAYS * 86400;
  const signature = await crypto.subtle.sign("HMAC", await hmacKey2(secret), encoder.encode(`viewer:${expires}`));
  return `${expires}.${toHex(signature)}`;
}
__name(createSession, "createSession");
async function verifySession(value, secret) {
  if (!value || !secret) return false;
  const [expires, signature] = value.split(".");
  if (!expires || !signature || Number(expires) * 1e3 < Date.now()) return false;
  const bytes = fromHex(signature);
  if (!bytes) return false;
  return crypto.subtle.verify("HMAC", await hmacKey2(secret), bytes, encoder.encode(`viewer:${expires}`));
}
__name(verifySession, "verifySession");
function readCookie2(request, name = SESSION_COOKIE) {
  const header = request.headers.get("Cookie") ?? "";
  for (const part of header.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return decodeURIComponent(rest.join("="));
  }
  return null;
}
__name(readCookie2, "readCookie");
function sessionCookie(value, secure) {
  return `${SESSION_COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_DAYS * 86400}${secure ? "; Secure" : ""}`;
}
__name(sessionCookie, "sessionCookie");
function clearSessionCookie() {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`;
}
__name(clearSessionCookie, "clearSessionCookie");
async function isLoggedIn(request, secret) {
  return verifySession(readCookie2(request), secret);
}
__name(isLoggedIn, "isLoggedIn");

// src/env.ts
function relayStub(env) {
  return env.MAC_RELAY.get(env.MAC_RELAY.idFromName("default"));
}
__name(relayStub, "relayStub");

// src/relay.ts
import { DurableObject } from "cloudflare:workers";
var VIEWER_TOOLS = /* @__PURE__ */ new Set([
  "tap",
  "swipe",
  "long_press",
  "type_text",
  "press_key",
  "press_button",
  "open_url",
  // Mac apps (protocol 5): wheel scrolling and menu commands.
  "scroll",
  "press_menu_item"
]);
var TOUCH_PHASES = /* @__PURE__ */ new Set(["down", "move", "up"]);
var TOUCH_VERSION = 4;
var VIEWER_WINDOW = 3;
var VIDEO_WINDOW = 10;
var KEYFRAME_INTERVAL_MS = 500;
var CALL_TIMEOUT_MS = 11 * 60 * 1e3;
var RECONNECT_GRACE_MS = 60 * 1e3;
var DEFAULT_STREAM = { fps: 12, quality: 60, scale: 0.5, codec: "jpeg" };
var decoder = new TextDecoder();
function streamKey(value) {
  if (value === void 0 || value === null || value === "") return "";
  return typeof value === "string" && /^[A-Za-z0-9-]{1,64}$/.test(value) ? value : null;
}
__name(streamKey, "streamKey");
var MacRelay = class extends DurableObject {
  static {
    __name(this, "MacRelay");
  }
  pending = /* @__PURE__ */ new Map();
  /** Fails the pending calls if the Mac doesn't reconnect in time. */
  reconnectTimer = null;
  /**
   * Per-viewer flow control: last frame sent, last frame acknowledged, and whether the viewer
   * must wait for an H.264 keyframe (it just joined, or missed a frame).
   */
  viewerFrames = /* @__PURE__ */ new Map();
  /** When each stream last asked the Mac for a keyframe. */
  keyframeRequested = /* @__PURE__ */ new Map();
  /** Where each viewer's finger is down, so it can be lifted if the viewer goes away mid-touch. */
  touching = /* @__PURE__ */ new Map();
  /** The Cloudflare data center this object runs in (e.g. "ATL"), looked up once. */
  location = null;
  constructor(ctx, env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }
  async fetch(request) {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/agent":
        return this.acceptSocket(request, "agent");
      case "/viewer":
        return this.acceptSocket(request, "viewer");
      default:
        return new Response("Not found", { status: 404 });
    }
  }
  // MARK: RPC used by the Worker
  async status() {
    const hello = await this.ctx.storage.get("hello");
    const agent = this.agent();
    return {
      online: agent !== null,
      host: hello?.host ?? null,
      touch: (hello?.version ?? 0) >= TOUCH_VERSION,
      location: await this.dataCenter(),
      viewers: this.viewers().length,
      connectedAt: await this.ctx.storage.get("connectedAt") ?? null,
      toolCount: hello?.tools.length ?? 0,
      // Only as fresh as the last time someone watched; the Mac sends it while streaming.
      simulators: await this.ctx.storage.get("simulators") ?? null
    };
  }
  /** The data center this object runs in, from Cloudflare's trace page (fetched from here). */
  dataCenter() {
    this.location ??= fetch("https://www.cloudflare.com/cdn-cgi/trace").then((response) => response.text()).then((text) => {
      const colo = /^colo=(\w+)$/m.exec(text)?.[1] ?? null;
      if (!colo) console.log("relay location: unexpected trace", text.slice(0, 200));
      return colo;
    }).catch((error) => {
      console.log("relay location lookup failed", String(error));
      return null;
    });
    return this.location;
  }
  /** Tool definitions from the Mac's last hello (kept so tools/list works while it's offline). */
  async tools() {
    return (await this.ctx.storage.get("hello"))?.tools ?? [];
  }
  async call(tool, args) {
    const agent = this.agent();
    if (!agent) {
      return {
        isError: true,
        content: [{ type: "text", text: "The Mac is offline. Check that it's awake and that `minirun serve` is running (launchctl list | grep minirun)." }]
      };
    }
    const id = crypto.randomUUID();
    const result = new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve({ isError: true, content: [{ type: "text", text: `${tool} didn't answer within ${CALL_TIMEOUT_MS / 6e4} minutes.` }] });
      }, CALL_TIMEOUT_MS);
      this.pending.set(id, { tool, resolve, timer });
    });
    agent.send(JSON.stringify({ type: "call", id, tool, arguments: args ?? {} }));
    return result;
  }
  // MARK: WebSockets
  acceptSocket(request, role) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    if (role === "agent") {
      for (const old of this.ctx.getWebSockets("agent")) old.close(4e3, "Replaced by a new connection");
      this.ctx.acceptWebSocket(server, ["agent"]);
      this.ctx.waitUntil(this.ctx.storage.put("connectedAt", Date.now()));
    } else {
      const key = streamKey(new URL(request.url).searchParams.get("device")) ?? "";
      this.ctx.acceptWebSocket(server, ["viewer"]);
      server.serializeAttachment({ key, ...DEFAULT_STREAM });
      this.viewerFrames.set(server, newFlow());
      this.ctx.waitUntil(this.greetViewer(server));
    }
    return new Response(null, { status: 101, webSocket: client });
  }
  agent() {
    return this.ctx.getWebSockets("agent")[0] ?? null;
  }
  viewers() {
    return this.ctx.getWebSockets("viewer");
  }
  role(ws) {
    return this.ctx.getTags(ws).includes("agent") ? "agent" : "viewer";
  }
  viewerState(ws) {
    return { key: "", ...DEFAULT_STREAM, ...ws.deserializeAttachment() };
  }
  async greetViewer(ws) {
    const status = await this.status();
    safeSend(ws, JSON.stringify({ type: "status", online: status.online, host: status.host, touch: status.touch }));
    if (status.simulators) safeSend(ws, JSON.stringify({ type: "simulators", devices: status.simulators }));
    const screen = await this.ctx.storage.get(`screen:${this.viewerState(ws).key}`);
    if (screen) safeSend(ws, screen);
    this.syncStreams();
    this.requestKeyframe(this.viewerState(ws).key, true);
  }
  /** Asks the Mac for an H.264 keyframe on stream `key`, at most every KEYFRAME_INTERVAL_MS unless `now`. */
  requestKeyframe(key, now = false) {
    const last = this.keyframeRequested.get(key) ?? 0;
    if (!now && Date.now() - last < KEYFRAME_INTERVAL_MS) return;
    this.keyframeRequested.set(key, Date.now());
    this.agent()?.send(JSON.stringify({ type: "keyframe", key }));
  }
  /** Tells the Mac which simulators to stream: one stream per simulator someone is watching. */
  syncStreams(leaving) {
    const agent = this.agent();
    if (!agent) return;
    const streams = /* @__PURE__ */ new Map();
    for (const viewer of this.viewers()) {
      if (viewer === leaving) continue;
      const state = this.viewerState(viewer);
      const codec = streams.get(state.key)?.codec === "jpeg" ? "jpeg" : state.codec;
      streams.set(state.key, { ...state, codec });
    }
    if (streams.size === 0) {
      agent.send(JSON.stringify({ type: "stream", action: "stop" }));
      return;
    }
    const list = [...streams.values()].map(({ key, fps, quality, scale, codec }) => ({ udid: key || null, fps, quality, scale, codec }));
    agent.send(JSON.stringify({ type: "stream", action: "set", streams: list }));
  }
  broadcast(message, key) {
    for (const viewer of this.viewers()) {
      if (key === void 0 || this.viewerState(viewer).key === key) safeSend(viewer, message);
    }
  }
  /** The simulator a viewer's input should go to: the one it's watching. */
  async viewerDevice(ws) {
    const { key } = this.viewerState(ws);
    if (key) return key;
    const screen = await this.ctx.storage.get("screen:");
    if (!screen) return null;
    try {
      return JSON.parse(screen).udid ?? null;
    } catch {
      return null;
    }
  }
  async webSocketMessage(ws, message) {
    if (this.role(ws) === "agent") {
      if (typeof message === "string") await this.onAgentText(message);
      else this.onFrame(message);
    } else if (typeof message === "string") {
      await this.onViewerText(ws, message);
    }
  }
  async onAgentText(text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    switch (message.type) {
      case "hello": {
        const hello = message;
        const previous = await this.ctx.storage.get("hello");
        await this.ctx.storage.put("hello", hello);
        this.agent()?.send(JSON.stringify({ type: "welcome", bundle: this.env.MINIRUN_BUNDLE ?? null }));
        this.broadcast(JSON.stringify({ type: "status", online: true, host: hello.host, touch: hello.version >= TOUCH_VERSION }));
        this.syncStreams();
        this.recoverPending(hello.instance !== void 0 && hello.instance === previous?.instance);
        break;
      }
      case "result": {
        const id = String(message.id);
        const pending = this.pending.get(id);
        if (pending) {
          clearTimeout(pending.timer);
          this.pending.delete(id);
          pending.resolve(message.result);
        }
        break;
      }
      case "screen": {
        const key = streamKey(message.key) ?? "";
        await this.ctx.storage.put(`screen:${key}`, text);
        this.broadcast(text, key);
        break;
      }
      case "stream_status":
        this.broadcast(text, streamKey(message.key) ?? "");
        break;
      case "simulators":
        await this.ctx.storage.put("simulators", Array.isArray(message.devices) ? message.devices : []);
        this.broadcast(text);
        break;
    }
  }
  onFrame(frame) {
    if (frame.byteLength < 5) return;
    const bytes = new Uint8Array(frame);
    let key = "";
    const video = bytes[0] === 3;
    if (bytes[0] === 2 || video) {
      if (frame.byteLength < 6 + bytes[5] + (video ? 1 : 0)) return;
      key = decoder.decode(bytes.subarray(6, 6 + bytes[5]));
    } else if (bytes[0] !== 1) {
      return;
    }
    const keyframe = video && (bytes[6 + bytes[5]] & 1) === 1;
    const sequence = new DataView(frame).getUint32(1);
    for (const viewer of this.viewers()) {
      const viewerState = this.viewerState(viewer);
      if (viewerState.key !== key) continue;
      if (video && viewerState.codec !== "h264") continue;
      let state = this.viewerFrames.get(viewer);
      if (!state) {
        state = newFlow();
        this.viewerFrames.set(viewer, state);
      }
      if (video) {
        if (state.needsKeyframe && !keyframe) {
          this.requestKeyframe(key);
          continue;
        }
        if (state.sent - state.acked >= VIDEO_WINDOW) {
          state.needsKeyframe = true;
          this.requestKeyframe(key);
          continue;
        }
      } else if (state.sent - state.acked >= VIEWER_WINDOW) {
        continue;
      }
      if (safeSend(viewer, frame)) {
        state.sent = sequence;
        if (video) state.needsKeyframe = false;
      }
      if (state.acked === 0) state.acked = sequence - 1;
    }
  }
  async onViewerText(ws, text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    switch (message.type) {
      case "ack": {
        const seq = Number(message.seq) || 0;
        const state = this.viewerFrames.get(ws);
        if (state && seq > state.acked) state.acked = seq;
        this.agent()?.send(JSON.stringify({ type: "ack", seq, key: this.viewerState(ws).key }));
        break;
      }
      case "keyframe": {
        const state = this.viewerFrames.get(ws);
        if (state) state.needsKeyframe = true;
        this.requestKeyframe(this.viewerState(ws).key);
        break;
      }
      case "input": {
        const tool = String(message.tool);
        if (!VIEWER_TOOLS.has(tool)) return;
        const device = await this.viewerDevice(ws);
        if (!device) return;
        const args = typeof message.arguments === "object" && message.arguments !== null ? message.arguments : {};
        this.agent()?.send(JSON.stringify({ type: "call", tool, arguments: { ...args, device } }));
        break;
      }
      case "touch": {
        const { phase, x, y } = message;
        if (typeof phase !== "string" || !TOUCH_PHASES.has(phase)) return;
        if (typeof x !== "number" || typeof y !== "number" || !Number.isFinite(x) || !Number.isFinite(y)) return;
        const device = await this.viewerDevice(ws);
        if (!device) return;
        if (phase === "up") this.touching.delete(ws);
        else this.touching.set(ws, { device, x, y });
        this.agent()?.send(JSON.stringify({ type: "touch", device, phase, x, y }));
        break;
      }
      case "stream": {
        const previous = this.viewerState(ws);
        const key = "device" in message ? streamKey(message.device) ?? previous.key : previous.key;
        const state = {
          key,
          fps: clamp(Number(message.fps) || DEFAULT_STREAM.fps, 1, 30),
          quality: clamp(Number(message.quality) || DEFAULT_STREAM.quality, 10, 95),
          scale: clamp(Number(message.scale) || DEFAULT_STREAM.scale, 0.2, 1),
          codec: message.codec === "h264" ? "h264" : "jpeg"
        };
        ws.serializeAttachment(state);
        if (key !== previous.key) {
          this.viewerFrames.set(ws, newFlow());
          const screen = await this.ctx.storage.get(`screen:${key}`);
          if (screen) safeSend(ws, screen);
        }
        this.syncStreams();
        if (key !== previous.key || state.codec !== previous.codec) this.requestKeyframe(key, true);
        break;
      }
    }
  }
  async webSocketClose(ws, code) {
    await this.dropSocket(ws, code);
  }
  async webSocketError(ws) {
    await this.dropSocket(ws, 1011);
  }
  async dropSocket(ws, code) {
    const role = this.role(ws);
    try {
      ws.close(code === 1005 || code === 1006 ? 1e3 : code);
    } catch {
    }
    if (role === "agent") {
      if (this.ctx.getWebSockets("agent").every((other) => other === ws)) {
        if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
        this.reconnectTimer = setTimeout(() => {
          this.reconnectTimer = null;
          this.failPending((tool) => `The Mac lost its connection while running ${tool} and hasn't reconnected. It may have finished anyway: check (e.g. list_jobs, list_simulators) before trying again.`);
        }, RECONNECT_GRACE_MS);
        this.broadcast(JSON.stringify({ type: "status", online: false }));
      }
    } else {
      const held = this.touching.get(ws);
      if (held) {
        this.touching.delete(ws);
        this.agent()?.send(JSON.stringify({ type: "touch", phase: "up", ...held }));
      }
      this.viewerFrames.delete(ws);
      this.syncStreams(ws);
    }
  }
  /**
   * Picks up the calls that were in flight when the Mac reconnects. The same run of minirun still
   * has them (running, or with a result it couldn't send), so it's asked to answer them; a
   * restarted one lost them, as did a Mac too old to say which run it is.
   */
  recoverPending(sameInstance) {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    if (this.pending.size === 0) return;
    if (sameInstance) {
      this.agent()?.send(JSON.stringify({ type: "pending", ids: [...this.pending.keys()] }));
    } else {
      this.failPending((tool) => `minirun on the Mac restarted while running ${tool}, so it may not have finished. Check (e.g. list_jobs, list_simulators) before trying again.`);
    }
  }
  failPending(message) {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.resolve({ isError: true, content: [{ type: "text", text: message(pending.tool) }] });
      this.pending.delete(id);
    }
  }
};
function newFlow() {
  return { sent: 0, acked: 0, needsKeyframe: true };
}
__name(newFlow, "newFlow");
function safeSend(ws, data) {
  try {
    ws.send(data);
    return true;
  } catch {
    return false;
  }
}
__name(safeSend, "safeSend");
function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
__name(clamp, "clamp");

// src/version.ts
var VERSION = "0.3.0";
function compareVersions(a, b) {
  const pa = a.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}
__name(compareVersions, "compareVersions");

// src/mcp.ts
var SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
var SERVER_INFO = { name: "minirun", title: "minirun \u2014 iOS simulators and Mac apps on your Mac", version: VERSION };
var INSTRUCTIONS = `minirun drives iOS simulators, macOS apps and Xcode on the user's Mac.
Typical loop: push your branch to GitHub, call build_and_run with repo + ref, read any errors (they come back with file:line), fix, push, repeat.
Then exercise the app: describe_ui to find elements, tap by id/label (or x,y in points), type_text, swipe, screenshot to look.
Long builds return a job_id after at most 50 seconds; call get_job (repeatedly if need be) to wait for it. If a call ever times out, the work keeps running on the Mac: list_jobs finds it.

Other Claude sessions may be using the same Mac at the same time, on other apps or other branches of yours. To stay on your own simulator and checkout:
- Always pass the same repo + ref. Each repo + ref has its own checkout and build folder.
- build_and_run picks the simulator reserved for your repo + ref (or reserves one) and its result gives that simulator's UDID. You can also get one up front with boot_simulator {label: "owner/repo@branch"}.
- Pass that UDID as device on every simulator call (tap, screenshot, describe_ui, launch_app, \u2026). Without it, a call fails when several simulators are booted rather than guessing.
- Never shut down or reuse a simulator reserved for something else; list_simulators shows who each one is reserved for.

macOS apps work the same way: pass platform: "macos" to build_and_run (or build, run_tests). The app runs on the Mac itself and the result gives a Mac app id like mac-3f9a2c; pass it as device on later calls (screenshot, describe_ui, tap, type_text, press_key with modifiers, scroll, press_menu_item, app_logs, \u2026). list_mac_apps shows the Mac apps minirun launched and who each is for; only quit your own.
The user can watch and control your simulator or Mac app live in their browser: share the live view link from build_and_run or boot_simulator, or call mac_status with your device.`;
var MAC_STATUS_TOOL = {
  name: "mac_status",
  description: "Check whether the Mac is online and which minirun version it and this relay run, and get the link where the user can watch and control a simulator or Mac app live in a browser. Pass your simulator's UDID or your Mac app id as device so the link opens on it. For Xcode, simulator and setup problems on the Mac, call host_info.",
  inputSchema: {
    type: "object",
    properties: { device: { type: "string", description: "UDID of your simulator, or your Mac app id (mac-\u2026). The link opens straight to it." } },
    additionalProperties: false
  }
};
async function handleMcp(request, env) {
  if (request.method === "GET" || request.method === "DELETE") {
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  let body;
  try {
    body = await request.json();
  } catch {
    return json(rpcError(null, -32700, "Parse error"), 400);
  }
  const origin = new URL(request.url).origin;
  const batch = Array.isArray(body);
  const messages = batch ? body : [body];
  const responses = [];
  for (const message of messages) {
    const response = await handleMessage(message, env, origin);
    if (response) responses.push(response);
  }
  if (responses.length === 0) return new Response(null, { status: 202 });
  return json(batch ? responses : responses[0]);
}
__name(handleMcp, "handleMcp");
async function handleMessage(message, env, origin) {
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    return rpcError(message?.id ?? null, -32600, "Invalid request");
  }
  const isNotification = message.id === void 0 || message.id === null;
  if (isNotification) return null;
  const id = message.id;
  try {
    switch (message.method) {
      case "initialize": {
        const requested = String(message.params?.protocolVersion ?? "");
        return rpcResult(id, {
          protocolVersion: SUPPORTED_VERSIONS.includes(requested) ? requested : SUPPORTED_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS
        });
      }
      case "ping":
        return rpcResult(id, {});
      case "tools/list": {
        const tools = await relayStub(env).tools();
        return rpcResult(id, { tools: [MAC_STATUS_TOOL, ...tools] });
      }
      case "tools/call": {
        const name = String(message.params?.name ?? "");
        const args = message.params?.arguments ?? {};
        if (!name) return rpcError(id, -32602, "Missing tool name");
        if (name === MAC_STATUS_TOOL.name) return rpcResult(id, await macStatus(env, origin, args.device));
        const result = await relayStub(env).call(name, args);
        return rpcResult(id, result);
      }
      case "resources/list":
        return rpcResult(id, { resources: [] });
      case "prompts/list":
        return rpcResult(id, { prompts: [] });
      default:
        return rpcError(id, -32601, `Method not found: ${message.method}`);
    }
  } catch (error) {
    return rpcError(id, -32603, error instanceof Error ? error.message : String(error));
  }
}
__name(handleMessage, "handleMessage");
async function macStatus(env, origin, device) {
  const status = await relayStub(env).status();
  const key = streamKey(device);
  if (key === null) return { content: [{ type: "text", text: "device must be a simulator UDID (from build_and_run, boot_simulator or list_simulators) or a Mac app id (from build_and_run or list_mac_apps)." }], isError: true };
  const link = key ? `${origin}/?device=${encodeURIComponent(key)}` : `${origin}/`;
  const what = key.startsWith("mac-") ? `Mac app ${key}` : `simulator ${key}`;
  const lines = [
    status.online ? `The Mac is online${status.host?.name ? ` (${status.host.name})` : ""}.` : "The Mac is offline.",
    versionLine(status.host?.minirun),
    key ? `Live view of ${what}: ${link} \u2014 the user can watch and control it there (they'll be asked for the minirun password).` : `Live view: ${link} \u2014 the user can watch and control a simulator there and switch between booted ones and Mac apps (they'll be asked for the minirun password). Pass device to get a link that opens on yours.`,
    `Viewers connected: ${status.viewers}. Tools available: ${status.toolCount}.` + (status.location ? ` The relay runs in Cloudflare's ${status.location} data center.` : "")
  ];
  if (!status.online) {
    lines.push("Ask the user to check that the Mac is awake and that `minirun serve` is running.");
  }
  return { content: [{ type: "text", text: lines.join("\n") }], isError: false };
}
__name(macStatus, "macStatus");
function versionLine(mac) {
  if (!mac) return `Relay: minirun ${VERSION}. The Mac hasn't said which minirun it runs.`;
  const order = compareVersions(mac, VERSION);
  if (order === 0) return `minirun ${VERSION} on the Mac and the relay.`;
  const fix = order > 0 ? "Ask the user to update the Worker: Update Worker in minirun's Settings \u2192 Cloudflare, or `minirun worker deploy`." : "Ask the user to update minirun on the Mac (Check for Updates in minirun's Settings).";
  return `minirun ${mac} on the Mac, but the relay is from minirun ${VERSION}. ${fix}`;
}
__name(versionLine, "versionLine");
function rpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}
__name(rpcResult, "rpcResult");
function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}
__name(rpcError, "rpcError");
function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
__name(json, "json");

// src/pages.ts
function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer"
    }
  });
}
__name(html, "html");
function escapeHTML(value) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
__name(escapeHTML, "escapeHTML");
var baseStyles = `
  :root { color-scheme: dark; --bg: #0b0c0f; --panel: #15171c; --line: #262a33; --text: #eef0f4; --muted: #8b92a1; --accent: #7cc4ff; --danger: #ff7a7a; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  .card { max-width: 380px; margin: 12vh auto 0; padding: 28px; background: var(--panel); border: 1px solid var(--line); border-radius: 18px; }
  h1 { font-size: 20px; margin: 0 0 6px; letter-spacing: -0.01em; }
  p { margin: 0 0 18px; color: var(--muted); }
  label { display: block; font-size: 13px; color: var(--muted); margin-bottom: 6px; }
  input[type=password] { width: 100%; padding: 12px 14px; border-radius: 10px; border: 1px solid var(--line); background: #0f1115; color: var(--text); font-size: 16px; }
  input[type=password]:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  .row { display: flex; gap: 10px; margin-top: 16px; }
  button { flex: 1; padding: 12px 14px; border-radius: 10px; border: 1px solid var(--line); background: #1d2027; color: var(--text); font-size: 15px; font-weight: 600; cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #06121d; }
  .error { color: var(--danger); font-size: 14px; margin: 10px 0 0; }
  .mark { display: inline-flex; align-items: center; gap: 8px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 18px; }
  .mark i { width: 10px; height: 10px; border-radius: 3px; background: var(--accent); display: inline-block; }
  code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: #0f1115; border: 1px solid var(--line); border-radius: 6px; padding: 1px 5px; word-break: break-all; }
`;
function page(title, body) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(title)} \xB7 minirun</title><style>${baseStyles}</style></head><body>${body}</body></html>`;
}
__name(page, "page");
function loginPage(options) {
  return page("Log in", `<form class="card" method="post" action="/login">
  <div class="mark"><i></i>minirun</div>
  <h1>Log in</h1>
  <p>Enter your minirun password to watch and control your Mac's simulators.</p>
  <label for="password">Password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" autofocus required>
  <input type="hidden" name="next" value="${escapeHTML(options.next ?? "/")}">
  ${options.error ? `<div class="error">${escapeHTML(options.error)}</div>` : ""}
  <div class="row"><button class="primary" type="submit">Log in</button></div>
</form>`);
}
__name(loginPage, "loginPage");
function authorizePage(options) {
  let host = options.redirectUri;
  try {
    host = new URL(options.redirectUri).host;
  } catch {
  }
  return page("Connect", `<form class="card" method="post" action="/authorize">
  <div class="mark"><i></i>minirun</div>
  <h1>Connect ${escapeHTML(options.clientName)}?</h1>
  <p>It will be able to build apps and control the simulators on your Mac. You'll be sent back to <code>${escapeHTML(host)}</code>.</p>
  <label for="password">Your minirun password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" autofocus>
  <input type="hidden" name="state" value="${escapeHTML(options.state)}">
  ${options.error ? `<div class="error">${escapeHTML(options.error)}</div>` : ""}
  <div class="row">
    <button type="submit" name="action" value="deny" formnovalidate>Cancel</button>
    <button class="primary" type="submit" name="action" value="approve">Connect</button>
  </div>
</form>`);
}
__name(authorizePage, "authorizePage");
function messagePage(title, message) {
  return page(title, `<div class="card"><div class="mark"><i></i>minirun</div><h1>${escapeHTML(title)}</h1><p>${escapeHTML(message)}</p></div>`);
}
__name(messagePage, "messagePage");

// src/viewer.ts
function viewerPage() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
<meta name="theme-color" content="#0b0c0f">
<title>minirun</title>
<style>
${baseStyles}
body { display: flex; flex-direction: column; height: 100dvh; overflow: hidden; }
header { display: flex; align-items: center; gap: 10px; padding: calc(env(safe-area-inset-top) + 10px) 14px 10px; border-bottom: 1px solid var(--line); }
header .mark { margin: 0; }
.pill { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); padding: 4px 10px; border: 1px solid var(--line); border-radius: 999px; }
.pill i { width: 7px; height: 7px; border-radius: 50%; background: #5b6170; }
.pill.live i { background: #4ade80; box-shadow: 0 0 0 3px rgba(74,222,128,.15); }
.pill.offline i { background: var(--danger); }
.device { margin-left: auto; font-size: 13px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 45vw; }
.sim { margin-left: auto; max-width: 55vw; padding: 6px 8px; font-size: 13px; text-overflow: ellipsis; }
.sim[hidden], .device[hidden] { display: none; }
main { flex: 1; min-height: 0; display: grid; place-items: center; padding: 14px; position: relative; }
.screen { position: relative; max-width: 100%; max-height: 100%; aspect-ratio: var(--ratio, 0.46); height: 100%; border-radius: 28px; overflow: hidden;
  background: #000; box-shadow: 0 0 0 1px var(--line), 0 20px 60px rgba(0,0,0,.5); touch-action: none; user-select: none; -webkit-user-select: none; }
.screen img, .screen canvas { width: 100%; height: 100%; display: block; object-fit: contain; pointer-events: none; -webkit-user-drag: none; }
.screen img[hidden], .screen canvas[hidden] { display: none; }
.screen:focus { outline: none; }
/* A Mac app's window: any shape (it can be resized while streaming), so it's fitted in both directions. */
body.mac main { container-type: size; }
body.mac .screen { height: auto; width: min(100cqw, 100cqh * var(--ratio, 1.6)); aspect-ratio: var(--ratio, 1.6); border-radius: 10px; }
body.mac .screen:focus-visible, body.mac .screen.focused { box-shadow: 0 0 0 1px var(--accent), 0 20px 60px rgba(0,0,0,.5); }
footer button[hidden] { display: none; }
.overlay { position: absolute; inset: 0; display: grid; place-items: center; text-align: center; padding: 24px; color: var(--muted); font-size: 14px; background: rgba(0,0,0,.55); }
.overlay[hidden] { display: none; }
.touch { position: absolute; width: 36px; height: 36px; margin: -18px 0 0 -18px; border-radius: 50%; background: rgba(124,196,255,.35); border: 2px solid rgba(124,196,255,.9);
  pointer-events: none; animation: touch .45s ease-out forwards; }
@keyframes touch { to { transform: scale(1.8); opacity: 0; } }
footer { display: flex; gap: 8px; align-items: center; padding: 10px 14px calc(env(safe-area-inset-bottom) + 10px); border-top: 1px solid var(--line); }
footer button { flex: 0 0 auto; padding: 10px 12px; font-size: 14px; }
footer form { flex: 1; display: flex; gap: 8px; min-width: 0; }
footer input { flex: 1; min-width: 0; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line); background: #0f1115; color: var(--text); font-size: 16px; }
select { padding: 10px 8px; border-radius: 10px; border: 1px solid var(--line); background: #1d2027; color: var(--text); font-size: 14px; }
</style>
</head>
<body>
<header>
  <div class="mark"><i></i>minirun</div>
  <span id="status" class="pill"><i></i><span>Connecting\u2026</span></span>
  <span id="device" class="device"></span>
  <select id="sim" class="sim" title="Simulator or Mac app" hidden></select>
</header>
<main>
  <div id="screen" class="screen" tabindex="0">
    <img id="frame" alt="Live screen">
    <canvas id="video" hidden></canvas>
    <div id="overlay" class="overlay">Connecting\u2026</div>
  </div>
</main>
<footer>
  <button id="home" type="button" title="Home">Home</button>
  <form id="typing" autocomplete="off">
    <input id="text" placeholder="Type into the app\u2026" enterkeyhint="send" autocapitalize="off" autocorrect="off" spellcheck="false">
    <button type="button" id="backspace" title="Delete">\u232B</button>
    <button type="button" id="enter" title="Return">\u23CE</button>
  </form>
  <select id="quality" title="Stream quality">
    <option value="saver">Saver</option>
    <option value="smooth">Smooth</option>
    <option value="sharp">Sharp</option>
  </select>
</footer>
<script>
(() => {
  const presets = {
    jpeg: { saver: { fps: 6, quality: 45, scale: 0.33 }, smooth: { fps: 15, quality: 55, scale: 0.5 }, sharp: { fps: 10, quality: 80, scale: 0.8 } },
    // H.264 only sends frames when the screen changes, so it can afford a higher frame rate.
    h264: { saver: { fps: 10, quality: 45, scale: 0.33 }, smooth: { fps: 30, quality: 55, scale: 0.5 }, sharp: { fps: 30, quality: 80, scale: 0.8 } },
  };
  const $ = (id) => document.getElementById(id);
  const screenEl = $("screen"), img = $("frame"), canvas = $("video"), overlay = $("overlay"), statusEl = $("status"), deviceEl = $("device"), simEl = $("sim");
  let ws = null, retry = 1000, online = false, live = false;
  // Whether the Mac takes live touches; older ones get whole gestures on finger-up instead.
  let touchLive = false;
  let screen = null; // { udid, pointWidth, pointHeight, name, kind? }, the latest for this stream
  // Booted simulators and running Mac apps ({ udid, name, kind: "mac", reserved_for } for those).
  let simulators = [];
  // The simulator or Mac app this page shows: ?device=UDID or ?device=mac-\u2026, or "" for whichever simulator is booted.
  let wanted = new URLSearchParams(location.search).get("device") || "";
  let currentURL = null, decoding = false, pendingFrame = null;
  // "h264" once we know this browser can decode it (?codec=jpeg forces JPEG).
  let codec = "jpeg";
  const video = { decoder: null, codec: "", needKeyframe: true, errors: 0 };

  const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
  $("quality").value = store.get("minirun.quality") || "smooth";

  function setStatus(kind, text) {
    statusEl.className = "pill " + kind;
    statusEl.lastElementChild.textContent = text;
  }
  function showOverlay(text) { overlay.textContent = text; overlay.hidden = !text; }

  function connect() {
    const url = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/viewer/ws" + (wanted ? "?device=" + encodeURIComponent(wanted) : "");
    ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    setStatus("", "Connecting\u2026");
    ws.onopen = () => { retry = 1000; video.needKeyframe = true; sendStream(); };
    ws.onmessage = (event) => typeof event.data === "string" ? onText(event.data) : onFrame(event.data);
    ws.onclose = (event) => {
      live = false;
      if (event.code === 1008 || event.code === 4401) { location.href = "/login"; return; }
      if (document.hidden) { setStatus("", "Paused"); return; }
      setStatus("offline", "Reconnecting\u2026");
      setTimeout(() => { if (!document.hidden) connect(); }, retry);
      retry = Math.min(retry * 2, 15000);
    };
  }

  function send(message) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(message)); }
  function sendStream() { send({ type: "stream", device: wanted, codec, ...presets[codec][$("quality").value] }); }

  // Mac app ids look like "mac-3f9a2c"; the Mac also says so with kind: "mac".
  function isMacId(udid) {
    const listed = simulators.find((d) => d.udid === udid);
    if (listed && listed.kind) return listed.kind === "mac";
    if (screen && screen.udid === udid && screen.kind) return screen.kind === "mac";
    return typeof udid === "string" && udid.startsWith("mac-");
  }
  // Whether this page shows a Mac app's window rather than a simulator.
  let mac = false;
  function noun() { return mac ? "app window" : "simulator"; }

  function applyMode() {
    mac = isMacId(screen && screen.udid ? screen.udid : wanted);
    document.body.classList.toggle("mac", mac);
    $("home").hidden = mac;
    $("text").placeholder = mac ? "Type into the app (or click its window and type)\u2026" : "Type into the app\u2026";
  }

  function renderSimulators() {
    const current = screen ? screen.udid : wanted;
    const list = simulators.slice();
    if (current && !list.some((d) => d.udid === current)) {
      list.push({ udid: current, name: screen ? screen.name : (isMacId(current) ? "Mac app" : "Simulator"), kind: isMacId(current) ? "mac" : undefined });
    }
    simEl.hidden = list.length < 2;
    deviceEl.hidden = !simEl.hidden;
    const sims = list.filter((d) => d.kind !== "mac"), apps = list.filter((d) => d.kind === "mac");
    const option = (d) => {
      const element = document.createElement("option");
      element.value = d.udid;
      element.textContent = d.name + (d.kind === "mac" && !sims.length ? " (Mac app)" : "") + (d.reserved_for ? " \u2014 " + d.reserved_for : "");
      return element;
    };
    const group = (label, devices) => {
      const element = document.createElement("optgroup");
      element.label = label;
      element.append(...devices.map(option));
      return element;
    };
    // Simulators first, then Mac apps, in groups when there are both.
    if (sims.length && apps.length) simEl.replaceChildren(group("Simulators", sims), group("Mac apps", apps));
    else simEl.replaceChildren(...list.map(option));
    if (current) simEl.value = current;
  }

  function watch(udid) {
    if (udid === wanted) return;
    wanted = udid;
    const url = new URL(location.href);
    if (udid) url.searchParams.set("device", udid); else url.searchParams.delete("device");
    history.replaceState(null, "", url);
    screen = null; live = false; pendingFrame = null; video.needKeyframe = true;
    applyMode();
    setStatus("", "Switching\u2026"); showOverlay(mac ? "Opening the app window\u2026" : "Switching simulator\u2026");
    sendStream();
  }

  function onText(text) {
    let m; try { m = JSON.parse(text); } catch { return; }
    if (m.type === "status") {
      online = m.online;
      touchLive = m.touch === true;
      if (!online) { live = false; setStatus("offline", "Mac offline"); showOverlay("Your Mac is offline. Make sure it's awake and minirun is running."); }
      else { setStatus("", "Starting stream\u2026"); if (!live) showOverlay("Waiting for the " + noun() + "\u2026"); }
      if (m.host && m.host.name && !screen) deviceEl.textContent = m.host.name;
    } else if (m.type === "simulators") {
      simulators = Array.isArray(m.devices) ? m.devices : [];
      applyMode();
      renderSimulators();
      // Only Mac apps and no simulator booted: open the first app rather than wait for a simulator.
      if (!wanted && simulators.length && simulators.every((d) => d.kind === "mac")) watch(simulators[0].udid);
    } else if (m.type === "screen") {
      if ((m.key || "") !== wanted) return;
      // A Mac app's window can be resized mid-stream: the Mac re-sends this with the new size,
      // and taps are mapped with the latest one.
      screen = m;
      applyMode();
      deviceEl.textContent = m.name;
      screenEl.style.setProperty("--ratio", String(m.pointWidth / m.pointHeight));
      renderSimulators();
    } else if (m.type === "stream_status") {
      if ((m.key || "") !== wanted) return;
      if (m.status === "live") { live = true; setStatus("live", "Live"); showOverlay(""); }
      else if (m.status === "error") { setStatus("offline", "Stream error"); showOverlay(m.message || "The " + noun() + " stream failed."); }
    }
  }

  function onFrame(buffer) {
    const bytes = new Uint8Array(buffer);
    if (bytes.length < 6) return;
    // Kind 1: [1][seq][jpeg]. Kind 2: [2][seq][keyLength][key][jpeg], key = UDID or "".
    // Kind 3: [3][seq][keyLength][key][flags][H.264 Annex B], flags bit 0 = keyframe.
    let key = "", start = 5;
    if (bytes[0] === 2 || bytes[0] === 3) {
      start = 6 + bytes[5];
      key = new TextDecoder().decode(bytes.subarray(6, start));
    } else if (bytes[0] !== 1) return;
    if (key !== wanted) return; // a frame from before we switched simulators
    const seq = new DataView(buffer).getUint32(1);
    if (bytes[0] === 3) { onVideo(seq, (bytes[start] & 1) === 1, bytes.subarray(start + 1)); return; }
    pendingFrame = { seq, blob: new Blob([bytes.subarray(start)], { type: "image/jpeg" }) };
    if (!decoding) showNext();
  }

  function showSurface(element) {
    img.hidden = element !== img;
    canvas.hidden = element !== canvas;
  }

  // The WebCodecs codec string ("avc1.PPCCLL") from the SPS NAL unit in an Annex B keyframe.
  function avcCodec(bytes) {
    for (let i = 0; i + 6 < bytes.length; i++) {
      if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1 && (bytes[i + 3] & 0x1f) === 7) {
        return "avc1." + [bytes[i + 4], bytes[i + 5], bytes[i + 6]].map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
      }
    }
    return null;
  }

  function onVideo(seq, keyframe, data) {
    if (codec !== "h264") { send({ type: "ack", seq }); return; } // until the Mac switches this stream to JPEG
    if (keyframe) {
      const avc = avcCodec(data) || "avc1.4D401F";
      if (!video.decoder || video.decoder.state === "closed" || avc !== video.codec) startDecoder(avc);
      video.needKeyframe = false;
    }
    // Until a keyframe arrives there's nothing to decode against.
    if (video.needKeyframe || !video.decoder || video.decoder.state !== "configured") { send({ type: "ack", seq }); return; }
    try {
      // Without a codec description, WebCodecs reads H.264 as Annex B. The timestamp carries seq to the output.
      video.decoder.decode(new EncodedVideoChunk({ type: keyframe ? "key" : "delta", timestamp: seq, data }));
    } catch {
      videoFailed();
      send({ type: "ack", seq });
    }
  }

  function startDecoder(avc) {
    if (video.decoder && video.decoder.state !== "closed") video.decoder.close();
    video.codec = avc;
    video.decoder = new VideoDecoder({ output: drawFrame, error: videoFailed });
    video.decoder.configure({ codec: avc, optimizeForLatency: true });
  }

  function videoFailed() {
    video.needKeyframe = true;
    if (video.decoder && video.decoder.state !== "closed") video.decoder.close();
    video.decoder = null;
    if (++video.errors >= 3) { codec = "jpeg"; sendStream(); return; } // this browser can't keep up; use JPEG
    send({ type: "keyframe" });
  }

  function drawFrame(frame) {
    const seq = frame.timestamp;
    if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
      canvas.width = frame.displayWidth;
      canvas.height = frame.displayHeight;
    }
    canvas.getContext("2d").drawImage(frame, 0, 0, canvas.width, canvas.height);
    frame.close();
    video.errors = 0;
    showSurface(canvas);
    if (!live) { live = true; setStatus("live", "Live"); showOverlay(""); }
    if (!screen) screenEl.style.setProperty("--ratio", String(canvas.width / canvas.height));
    send({ type: "ack", seq });
  }

  async function detectH264() {
    if (new URLSearchParams(location.search).get("codec") === "jpeg") return false;
    if (typeof VideoDecoder !== "function" || typeof EncodedVideoChunk !== "function") return false;
    try {
      return (await VideoDecoder.isConfigSupported({ codec: "avc1.4D401F", optimizeForLatency: true })).supported === true;
    } catch {
      return false;
    }
  }

  function showNext() {
    if (!pendingFrame) { decoding = false; return; }
    decoding = true;
    const { seq, blob } = pendingFrame;
    pendingFrame = null;
    const url = URL.createObjectURL(blob);
    img.onload = () => {
      if (currentURL) URL.revokeObjectURL(currentURL);
      currentURL = url;
      showSurface(img);
      if (!live) { live = true; setStatus("live", "Live"); showOverlay(""); }
      if (!screen) screenEl.style.setProperty("--ratio", String(img.naturalWidth / img.naturalHeight));
      send({ type: "ack", seq });
      showNext();
    };
    img.onerror = () => { URL.revokeObjectURL(url); send({ type: "ack", seq }); showNext(); };
    img.src = url;
  }

  // Touch \u2192 tap / long press / swipe, in simulator (or Mac window) points, from the latest screen message.
  function geometry() {
    const surface = canvas.hidden ? img : canvas;
    const rect = surface.getBoundingClientRect();
    const naturalWidth = canvas.hidden ? img.naturalWidth : canvas.width, naturalHeight = canvas.hidden ? img.naturalHeight : canvas.height;
    const w = screen ? screen.pointWidth : naturalWidth / (mac ? 1 : 3), h = screen ? screen.pointHeight : naturalHeight / (mac ? 1 : 3);
    // object-fit: contain \u2014 account for letterboxing.
    const scale = Math.min(rect.width / w, rect.height / h);
    return { rect, w, h, scale, offsetX: (rect.width - w * scale) / 2, offsetY: (rect.height - h * scale) / 2 };
  }
  function toPoints(clientX, clientY) {
    const { rect, w, h, scale, offsetX, offsetY } = geometry();
    const x = (clientX - rect.left - offsetX) / scale, y = (clientY - rect.top - offsetY) / scale;
    return { x: Math.round(Math.max(0, Math.min(w, x)) * 10) / 10, y: Math.round(Math.max(0, Math.min(h, y)) * 10) / 10 };
  }
  function ripple(clientX, clientY) {
    const rect = screenEl.getBoundingClientRect();
    const dot = document.createElement("div");
    dot.className = "touch";
    dot.style.left = clientX - rect.left + "px";
    dot.style.top = clientY - rect.top + "px";
    screenEl.appendChild(dot);
    setTimeout(() => dot.remove(), 500);
  }
  // Characters typed on a Mac app's window, sent together as one type_text. Anything else sent
  // goes after them, so keys and clicks keep their order.
  let typed = "", typedTimer = null;
  function flushText() {
    clearTimeout(typedTimer);
    typedTimer = null;
    const text = typed;
    typed = "";
    if (text) input("type_text", { text });
  }
  function input(tool, args) {
    if (typed) flushText();
    if (online) send({ type: "input", tool, arguments: args });
  }

  // Live touches: down, moves (at most one per animation frame) and up are sent as they happen,
  // so drags and long presses track the finger. Without them, the gesture is sent on finger-up.
  // On a Mac app they're the mouse: the Mac turns them into mouse down, drag and up.
  let start = null, moved = null, moveQueued = false;
  // The last plain mouse click on a Mac app, so a second one soon after becomes a double click.
  let lastClick = null, lastPointerType = "";
  function touch(phase, point) {
    if (typed) flushText();
    if (online) send({ type: "touch", phase, x: point.x, y: point.y });
  }
  function flushMove() {
    moveQueued = false;
    if (start && start.live && moved) { touch("move", moved); moved = null; }
  }
  screenEl.addEventListener("pointerdown", (e) => {
    lastPointerType = e.pointerType;
    if (!live) return;
    const mouse = mac && e.pointerType === "mouse";
    // Right clicks (and control-clicks on a Mac browser) arrive as contextmenu.
    if (mouse && (e.button !== 0 || (e.ctrlKey && /Mac/.test(navigator.platform)))) return;
    if (mac) { screenEl.focus({ preventScroll: true }); screenEl.classList.add("focused"); }
    screenEl.setPointerCapture(e.pointerId);
    const now = performance.now();
    // The second click of a double click isn't sent live: it goes as tap {count: 2} on mouse up.
    const double = mouse && lastClick !== null && now - lastClick.t < 400 && Math.hypot(e.clientX - lastClick.x, e.clientY - lastClick.y) < 6;
    start = { x: e.clientX, y: e.clientY, t: now, id: e.pointerId, live: touchLive && !double, mouse, double };
    lastClick = null;
    moved = null;
    e.preventDefault();
    if (start.live) {
      ripple(e.clientX, e.clientY);
      touch("down", toPoints(e.clientX, e.clientY));
    }
  });
  screenEl.addEventListener("pointermove", (e) => {
    if (!start || !start.live || e.pointerId !== start.id) return;
    moved = toPoints(e.clientX, e.clientY);
    if (!moveQueued) { moveQueued = true; requestAnimationFrame(flushMove); }
  });
  screenEl.addEventListener("pointerup", (e) => {
    if (!start || e.pointerId !== start.id) return;
    const dt = performance.now() - start.t, distance = Math.hypot(e.clientX - start.x, e.clientY - start.y);
    if (start.live) {
      moved = null;
      touch("up", toPoints(e.clientX, e.clientY));
      if (start.mouse && distance < 6 && dt < 500) lastClick = { t: performance.now(), x: e.clientX, y: e.clientY };
      start = null;
      return;
    }
    const from = toPoints(start.x, start.y);
    ripple(start.x, start.y);
    if (distance < 10) {
      if (start.double) input("tap", { ...from, count: 2 });
      else if (dt > 500) input("long_press", { ...from, duration: Math.min(dt / 1000, 5) });
      else input("tap", from);
    } else {
      const to = toPoints(e.clientX, e.clientY);
      input("swipe", { from_x: from.x, from_y: from.y, to_x: to.x, to_y: to.y, duration: Math.max(0.1, Math.min(dt / 1000, 1.5)) });
    }
    start = null;
  });
  screenEl.addEventListener("pointercancel", (e) => {
    if (start && start.live && e.pointerId === start.id) touch("up", toPoints(e.clientX, e.clientY));
    start = null; moved = null;
  });

  // Mac apps: right click, wheel and trackpad scrolling, and keys.
  screenEl.addEventListener("contextmenu", (e) => {
    if (!mac) return;
    e.preventDefault();
    // A long press on a touch screen also fires contextmenu; that one is already a touch.
    if (!live || lastPointerType === "touch" || lastPointerType === "pen") return;
    ripple(e.clientX, e.clientY);
    input("tap", { ...toPoints(e.clientX, e.clientY), button: "right" });
  });

  // Wheel deltas add up and go as one scroll at most every 33 ms, in window points (positive dy
  // scrolls down, as in the browser), at the pointer.
  let wheel = null, wheelTimer = null, wheelSent = 0;
  function flushWheel() {
    wheelTimer = null;
    if (!wheel) return;
    const { x, y } = wheel, dx = Math.round(wheel.dx * 10) / 10, dy = Math.round(wheel.dy * 10) / 10;
    wheel = null;
    wheelSent = performance.now();
    if (dx || dy) input("scroll", { x, y, dx, dy });
  }
  screenEl.addEventListener("wheel", (e) => {
    if (!mac) return;
    e.preventDefault();
    // Control + wheel is a trackpad pinch, not a scroll.
    if (!live || e.ctrlKey) return;
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? screenEl.clientHeight : 1;
    const perPoint = geometry().scale || 1;
    const at = toPoints(e.clientX, e.clientY);
    wheel = { x: at.x, y: at.y, dx: (wheel ? wheel.dx : 0) + e.deltaX * unit / perPoint, dy: (wheel ? wheel.dy : 0) + e.deltaY * unit / perPoint };
    if (!wheelTimer) wheelTimer = setTimeout(flushWheel, Math.max(0, 33 - (performance.now() - wheelSent)));
  }, { passive: false });

  // Keys typed while the page (not a text field) has focus go to a Mac app: printable characters
  // as type_text, everything else, and anything with command, control or option, as press_key.
  const keyNames = {
    Enter: "return", Backspace: "delete", Delete: "forwarddelete", Tab: "tab", Escape: "escape", " ": "space",
    ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
  };
  const codeNames = { Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Backslash: "\\\\", Semicolon: ";", Quote: "'", Comma: ",", Period: ".", Slash: "/", Backquote: "\`" };
  function keyName(e) {
    if (keyNames[e.key]) return keyNames[e.key];
    if (/^F([1-9]|1[0-2])$/.test(e.key)) return e.key.toLowerCase();
    // With option or shift held, e.key is the character it makes ("\xE5", "A"); the key itself is what's pressed (US layout).
    if (e.code.startsWith("Key") && e.code.length === 4) return e.code.slice(3).toLowerCase();
    if (e.code.startsWith("Digit") && e.code.length === 6) return e.code.slice(5);
    if (codeNames[e.code]) return codeNames[e.code];
    return e.key.length === 1 ? e.key.toLowerCase() : null;
  }
  document.addEventListener("keydown", (e) => {
    if (!mac || !live || e.isComposing) return;
    if (e.target instanceof Element && e.target.closest("input, textarea, select")) return;
    const altGraph = e.getModifierState && e.getModifierState("AltGraph");
    if (e.key.length === 1 && (altGraph || (!e.metaKey && !e.ctrlKey && !e.altKey))) {
      typed += e.key;
      if (!typedTimer) typedTimer = setTimeout(flushText, 60);
    } else {
      const key = keyName(e);
      if (!key) return; // a modifier on its own, or a key the Mac doesn't know
      const modifiers = [];
      if (e.metaKey) modifiers.push("command");
      if (e.ctrlKey) modifiers.push("control");
      if (e.altKey) modifiers.push("option");
      if (e.shiftKey) modifiers.push("shift");
      input("press_key", modifiers.length ? { key, modifiers } : { key });
    }
    e.preventDefault();
  });
  screenEl.addEventListener("blur", () => screenEl.classList.remove("focused"));

  $("home").onclick = () => input("press_button", { button: "home" });
  $("enter").onclick = () => input("press_key", { key: "return" });
  $("backspace").onclick = () => input("press_key", { key: "delete" });
  $("typing").onsubmit = (e) => {
    e.preventDefault();
    const field = $("text");
    if (field.value) input("type_text", { text: field.value });
    field.value = "";
  };
  $("quality").onchange = () => { store.set("minirun.quality", $("quality").value); sendStream(); };
  simEl.onchange = () => watch(simEl.value);
  document.addEventListener("visibilitychange", () => {
    // Stop streaming in background tabs to save the Mac and your data plan.
    if (document.hidden && ws) ws.close(1000);
    else if (!document.hidden && (!ws || ws.readyState > 1)) connect();
  });

  detectH264().then((supported) => { codec = supported ? "h264" : "jpeg"; connect(); });
})();
<\/script>
</body>
</html>`;
}
__name(viewerPage, "viewerPage");

// src/index.ts
async function handleDefault(request, env) {
  const url = new URL(request.url);
  const secure = url.protocol === "https:";
  switch (url.pathname) {
    case "/agent": {
      const token = bearer(request);
      if (!env.AGENT_TOKEN || !token || !await safeEqual(token, env.AGENT_TOKEN)) {
        return new Response("Invalid agent token", { status: 401 });
      }
      return relayStub(env).fetch(new Request("https://relay/agent", request));
    }
    case "/viewer/ws": {
      if (!await isLoggedIn(request, env.OWNER_PASSWORD)) return new Response("Log in first", { status: 401 });
      return relayStub(env).fetch(new Request("https://relay/viewer" + url.search, request));
    }
    case "/status": {
      if (!await isLoggedIn(request, env.OWNER_PASSWORD)) return new Response("Log in first", { status: 401 });
      return Response.json(await relayStub(env).status());
    }
    case "/": {
      if (!await isLoggedIn(request, env.OWNER_PASSWORD)) return redirect(url.search ? `/login?next=${encodeURIComponent("/" + url.search)}` : "/login");
      return html(viewerPage());
    }
    case "/login": {
      if (!env.OWNER_PASSWORD) return html(messagePage("Not set up yet", "Set the OWNER_PASSWORD secret on the Worker first (see the README)."), 500);
      if (request.method === "POST") {
        const form = await request.formData();
        if (await checkPassword(form.get("password")?.toString(), env.OWNER_PASSWORD)) {
          return redirect(safeNext(form.get("next")?.toString()), { "Set-Cookie": sessionCookie(await createSession(env.OWNER_PASSWORD), secure) });
        }
        return html(loginPage({ error: "That password isn't right.", next: form.get("next")?.toString() }), 401);
      }
      return html(loginPage({ next: url.searchParams.get("next") ?? void 0 }));
    }
    case "/logout":
      return redirect("/login", { "Set-Cookie": clearSessionCookie() });
    case "/authorize":
      return authorize(request, env, secure);
    case "/favicon.ico":
      return new Response(null, { status: 204 });
    default:
      return new Response("Not found", { status: 404 });
  }
}
__name(handleDefault, "handleDefault");
async function authorize(request, env, secure) {
  if (request.method === "GET") {
    let oauthRequest2;
    try {
      oauthRequest2 = await env.OAUTH_PROVIDER.parseAuthRequest(request);
    } catch (error) {
      return html(messagePage("Invalid request", error instanceof Error ? error.message : "The authorization request is invalid."), 400);
    }
    const client2 = await env.OAUTH_PROVIDER.lookupClient(oauthRequest2.clientId);
    if (!client2) return html(messagePage("Unknown app", "This app isn't registered with minirun."), 400);
    return html(authorizePage({
      clientName: client2.clientName ?? client2.clientId,
      redirectUri: oauthRequest2.redirectUri,
      // The parsed request is round-tripped through the form; it's validated again on submit.
      state: encodeState(oauthRequest2)
    }));
  }
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const form = await request.formData();
  let oauthRequest;
  try {
    oauthRequest = decodeState(form.get("state")?.toString() ?? "");
  } catch {
    return html(messagePage("Invalid request", "The authorization form was malformed. Start the connection again from Claude."), 400);
  }
  const client = await env.OAUTH_PROVIDER.lookupClient(oauthRequest.clientId);
  if (!client || !client.redirectUris.includes(oauthRequest.redirectUri)) {
    return html(messagePage("Invalid request", "This app or redirect address isn't registered."), 400);
  }
  if (form.get("action") === "deny") {
    const deny = new URL(oauthRequest.redirectUri);
    deny.searchParams.set("error", "access_denied");
    if (oauthRequest.state) deny.searchParams.set("state", oauthRequest.state);
    return redirect(deny.toString());
  }
  if (!await checkPassword(form.get("password")?.toString(), env.OWNER_PASSWORD)) {
    return html(authorizePage({
      clientName: client.clientName ?? client.clientId,
      redirectUri: oauthRequest.redirectUri,
      state: form.get("state")?.toString() ?? "",
      error: "That password isn't right."
    }), 401);
  }
  const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
    request: oauthRequest,
    userId: "owner",
    metadata: { client: client.clientName ?? client.clientId, approvedAt: Date.now() },
    scope: oauthRequest.scope ?? [],
    props: { user: "owner" }
  });
  return redirect(redirectTo, { "Set-Cookie": sessionCookie(await createSession(env.OWNER_PASSWORD), secure) });
}
__name(authorize, "authorize");
function encodeState(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
__name(encodeState, "encodeState");
function decodeState(state) {
  const binary = atob(state);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  const parsed = JSON.parse(new TextDecoder().decode(bytes));
  if (!parsed || typeof parsed.clientId !== "string" || typeof parsed.redirectUri !== "string") throw new Error("bad state");
  return parsed;
}
__name(decodeState, "decodeState");
function redirect(location, headers = {}) {
  return new Response(null, { status: 302, headers: { Location: location, ...headers } });
}
__name(redirect, "redirect");
function safeNext(next) {
  return next && next.startsWith("/") && !next.startsWith("//") ? next : "/";
}
__name(safeNext, "safeNext");
var providers = /* @__PURE__ */ new Map();
function providerFor(origin) {
  let provider = providers.get(origin);
  if (!provider) {
    provider = new OAuthProvider({
      apiRoute: "/mcp",
      apiHandler: { fetch: /* @__PURE__ */ __name((request, env) => handleMcp(request, env), "fetch") },
      defaultHandler: { fetch: /* @__PURE__ */ __name((request, env) => handleDefault(request, env), "fetch") },
      authorizeEndpoint: "/authorize",
      tokenEndpoint: "/token",
      clientRegistrationEndpoint: "/register",
      clientIdMetadataDocumentEnabled: true,
      accessTokenTTL: 24 * 3600,
      resourceMetadata: { resource: `${origin}/mcp`, authorization_servers: [origin], resource_name: "minirun" }
    });
    providers.set(origin, provider);
  }
  return provider;
}
__name(providerFor, "providerFor");
var index_default = {
  fetch(request, env, ctx) {
    return providerFor(new URL(request.url).origin).fetch(request, env, ctx);
  }
};
export {
  MacRelay,
  index_default as default
};
//# sourceMappingURL=index.js.map
