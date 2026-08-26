/* Lucky Draw — shared config. COPY THIS TO config.js AND FILL IT IN.
   ---------------------------------------------------------------------------
   FILL THESE IN with YOUR OWN Supabase project before deploying. The values
   below are placeholders. The anon key is designed to be public and safe to
   commit, but ONLY because every table is protected by Row Level Security —
   see FORK_NOTES.md before you create any new table.
   --------------------------------------------------------------------------- */
window.XF = {
  SUPABASE_URL:  'PUT YOUR SUPABASE URL HERE',
  SUPABASE_KEY:  'PUT YOUR ANON KEY HERE',

  /* Countdown target only. The pool lock time lives in Supabase
     app_config.pool_locks_at — that is the single source of truth, and
     xf_pool_locked() is what actually stops entries. Set both. */
  DRAW_AT: '2026-12-31T20:00:00+08:00',

  /* FALLBACK ONLY. The live values come from the server (xf_points) and are
     edited in Admin -> Data -> TICKET VALUES. These are used for the split
     second before that call returns, or if it fails. No need to keep them
     in sync — they are never authoritative. */
  PTS: { checkin: 3, max_days: 7, social: 3, repost: 6, renewal: 1 },

  /* POSTER links are no longer here. They are typed into
     Admin -> Data -> 9.01 POSTER LINKS and stored in app_config,
     so publishing the post needs no code push. */

  LINKS: {
    instagram: 'https://www.instagram.com/YOUR_HANDLE',
    facebook:  'https://www.facebook.com/YOUR_PAGE',
    tiktok:    'https://www.tiktok.com/@YOUR_HANDLE',
    xhs:       'https://YOUR-REDNOTE-LINK',
    /* Google Review is no longer a ticket task — reviews must not be
       rewarded. Kept here only as the URL for a front-desk standee QR. */
    google:    'https://YOUR-GOOGLE-REVIEW-LINK'
  }
};

/* Minimal Supabase RPC helper — no SDK needed, keeps the page tiny and fast. */
window.rpc = async function (fn, args) {
  const res = await fetch(window.XF.SUPABASE_URL + '/rest/v1/rpc/' + fn, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'apikey': window.XF.SUPABASE_KEY,
      'Authorization': 'Bearer ' + window.XF.SUPABASE_KEY
    },
    body: JSON.stringify(args || {})
  });
  if (!res.ok) {
    let detail = '';
    try { detail = (await res.json()).message || ''; } catch (e) {}
    throw new Error('rpc_' + res.status + (detail ? ': ' + detail : ''));
  }
  return res.json();
};
