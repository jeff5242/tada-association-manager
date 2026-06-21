const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const url = new URL(req.url);
  const taxId = url.searchParams.get('id') ?? '';

  if (!/^\d{8}$/.test(taxId)) {
    return new Response(JSON.stringify({ error: '請輸入 8 碼統一編號' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const res = await fetch(`https://company.g0v.ronny.tw/id/${taxId}`);
  const data = await res.json();

  return new Response(JSON.stringify(data), {
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
