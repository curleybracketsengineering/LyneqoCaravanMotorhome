# Lyneqo Zyfy Vehicle Proxy

Cloudflare Worker accepting GET `/v1/vehicle?registration=AB12CDE` and forwarding to `https://zyfy.uk/v1/vehicle/AB12CDE` with `X-Api-Key` from a Cloudflare Secret.

## Deploy from a Mac terminal
1. Ensure Node.js is installed.
2. In this directory run `npx wrangler login`.
3. Run `npx wrangler deploy`.
4. Run `npx wrangler secret put ZYFY_API_KEY` and enter your Zyfy key at the prompt. Do not paste the key into the code.
5. Test `https://lyneqo-zyfy-proxy.<account>.workers.dev/health`.
6. Test `https://lyneqo-zyfy-proxy.<account>.workers.dev/v1/vehicle?registration=AB12CDE` with a real registration.
7. For a custom hostname, uncomment the `[[routes]]` section and redeploy, or add a Custom Domain under the Worker's Settings > Domains & Routes.

## Important
The Zyfy key stays private, but the URL itself is a public service. The included rate limit (10 requests/minute per IP per Cloudflare location) is approximate and not a billing cap. Before wider public release, implement stronger abuse controls and an alert or strict quota. Avoid logging registration numbers and confirm provider usage terms.

Zyfy may return `enrichmentPending: true` and a `Retry-After` header. Have the iOS app handle this by allowing the user to retry rather than polling aggressively.
