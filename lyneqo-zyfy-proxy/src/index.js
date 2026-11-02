// Lyneqo vehicle lookup proxy for Zyfy (Cloudflare Workers)
// Set ZYFY_API_KEY as a Cloudflare Secret. Never put it in your iOS app.
const json = (data, status = 200, extra = {}) => new Response(JSON.stringify(data), {
  status,
  headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...extra },
});

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405, { Allow: 'GET' });
    if (url.pathname === '/health') return json({ status: 'ok' });
    if (url.pathname !== '/v1/vehicle') return json({ error: 'Not found' }, 404);

    // Accept a single registration, never arbitrary upstream URLs or endpoints.
    const raw = url.searchParams.get('registration') || '';
    const registration = raw.toUpperCase().replace(/\s/g, '');
    if (!/^[A-Z0-9]{2,8}$/.test(registration)) {
      return json({ error: 'Invalid UK vehicle registration' }, 400);
    }

    if (!env.ZYFY_API_KEY) return json({ error: 'Service not configured' }, 503);

    // Approximate per-client throttling. Cloudflare rate limits are not exact global quotas.
    if (env.LOOKUP_LIMITER) {
      const identity = request.headers.get('CF-Connecting-IP') || 'unknown';
      const { success } = await env.LOOKUP_LIMITER.limit({ key: identity });
      if (!success) return json({ error: 'Too many requests. Try again later.' }, 429, { 'Retry-After': '60' });
    }

    try {
      const upstream = await fetch(`https://zyfy.uk/v1/vehicle/${encodeURIComponent(registration)}`, {
        method: 'GET',
        headers: { 'X-Api-Key': env.ZYFY_API_KEY, Accept: 'application/json' },
        // Workers only allow "follow" or "manual". Refuse redirects instead of following them.
        redirect: 'manual',
        signal: AbortSignal.timeout(10000),
      });
      if (upstream.status >= 300 && upstream.status < 400) {
        return json({ error: 'Unexpected provider response' }, 502);
      }

      // Do not expose provider response headers or possible private operational details.
      const contentType = upstream.headers.get('content-type') || '';
      if (!contentType.toLowerCase().includes('application/json')) {
        return json({ error: 'Unexpected provider response' }, 502);
      }
      const body = await upstream.text();
      if (body.length > 200000) return json({ error: 'Provider response too large' }, 502);
      let data;
      try { data = JSON.parse(body); } catch { return json({ error: 'Invalid provider response' }, 502); }
      const retryAfter = upstream.headers.get('Retry-After');
      const headers = {};
      if (retryAfter && /^\d{1,5}$/.test(retryAfter)) headers['Retry-After'] = retryAfter;
      return json(data, upstream.status, headers);
    } catch {
      return json({ error: 'Vehicle lookup temporarily unavailable' }, 502);
    }
  }
};
